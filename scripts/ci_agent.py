#!/usr/bin/env python3
"""
ci_agent.py — a small agent that watches the OPX "build-iso" GitHub Actions
workflow, works out why the latest failure happened, and can trigger a new
run.

Usage:
    python3 ci_agent.py check                 # report status of latest run
    python3 ci_agent.py diagnose [--n N]       # diagnose the last N failed runs (default 1)
    python3 ci_agent.py deploy [--ref REF]     # trigger a new run via workflow_dispatch
    python3 ci_agent.py watch [--ref REF]      # trigger a run, then poll until it finishes

Required environment variables:
    GITHUB_TOKEN   a token with `actions:read` (and `actions:write` for deploy/watch)
    GITHUB_REPO    "owner/name", e.g. "yourname/OPX"

Optional:
    WORKFLOW_FILE       workflow filename to target (default: build-iso.yml)
    ANTHROPIC_API_KEY   if set, failure logs are summarized by Claude instead
                         of the built-in regex heuristics
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
import zipfile
import io

API = "https://api.github.com"


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def env(name, required=True, default=None):
    val = os.environ.get(name, default)
    if required and not val:
        die(f"missing required environment variable {name}")
    return val


def gh_request(path, method="GET", token=None, data=None):
    url = path if path.startswith("http") else f"{API}{path}"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "opx-ci-agent",
    }
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        die(f"GitHub API {method} {url} -> {e.code}: {detail}")


def get_runs(repo, token, workflow_file, per_page=15):
    data = gh_request(
        f"/repos/{repo}/actions/workflows/{workflow_file}/runs?per_page={per_page}",
        token=token,
    )
    return data.get("workflow_runs", [])


def get_jobs(repo, token, run_id):
    data = gh_request(f"/repos/{repo}/actions/runs/{run_id}/jobs", token=token)
    return data.get("jobs", [])


def download_job_log(repo, token, job_id):
    """GitHub redirects log downloads; urllib follows redirects by default,
    but the auth header must not be dropped, so fetch manually."""
    url = f"{API}/repos/{repo}/actions/jobs/{job_id}/logs"
    headers = {
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "opx-ci-agent",
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return f"(could not fetch log: {e.code})"


# --- failure diagnosis -------------------------------------------------

# Heuristics tuned to the failure modes this project actually hits:
# Buildroot package builds, kernel config, syslinux/isolinux packaging,
# and the shell-based test suite.
PATTERNS = [
    (re.compile(r"gelf\.h: No such file or directory|libelf.*not (found|detected)", re.I), "The kernel's objtool needs host libelf (gelf.h) for the ORC unwinder — the workflow must apt-get install libelf-dev before building (fixed in build-iso.yml)."),
    (re.compile(r"openssl/.*\.h: No such file|extract-cert.*Error", re.I), "scripts/extract-cert needs OpenSSL headers (CONFIG_SYSTEM_TRUSTED_KEYRING defaults on) — apt-get install libssl-dev."),
    (re.compile(r"No space left on device"), "Runner ran out of disk space — Buildroot needs ~10GB; the workflow should free runner images (dotnet/android/ghc) before building."),
    (re.compile(r"E: Unable to locate package|apt-get.*fail", re.I), "A host package (apt dependency for the Buildroot toolchain) failed to install — likely an upstream apt mirror hiccup, or the runner image changed."),
    (re.compile(r"Config\.in.*syntax error|Kconfig.*error", re.I), "A Buildroot Config.in/Kconfig syntax error — check package/rns/Config.in or the defconfig for a malformed option."),
    (re.compile(r"ldlinux\.c32|isolinux\.bin.*not found|syslinux.*error", re.I), "Syslinux/isolinux packaging failed — BR2_TARGET_SYSLINUX_C32 must stay \"ldlinux.c32\" for syslinux 6; check post-image.sh."),
    (re.compile(r"undefined reference to|error: .*conflicting types|collect2: error", re.I), "A C compile/link error in a Buildroot package or the kernel — likely a toolchain/package version mismatch."),
    (re.compile(r"BLK_DEV_INITRD|BLK_DEV_RAM.*not set", re.I), "Kernel config is missing initrd/ramdisk support — kernel.config must enable BLK_DEV_INITRD and BLK_DEV_RAM (64MB) since the squashfs root loads as an initrd."),
    (re.compile(r"tests/run-tests\.sh.*FAIL|not ok \d", re.I), "The regression suite (tests/run-tests.sh) failed — a shell script under rootfs-overlay/usr/share/rns/bin regressed; re-run locally with `sh tests/run-tests.sh` for the failing case name."),
    (re.compile(r"curl.*(Could not resolve|timed out|Connection refused)", re.I), "A download step failed to reach a mirror (Buildroot source tarball or the buildroot release tarball itself) — likely a transient network issue; retry."),
    (re.compile(r"No such file or directory.*buildroot-\d"), "The Buildroot tarball for BR_VER wasn't found after download — check BR_VER in build.sh matches an existing Buildroot release."),
    (re.compile(r"Permission denied"), "A permissions issue — check post-build.sh chmod steps and that the runner isn't running as an unexpected user."),
]


def heuristic_diagnose(log_text):
    hits = []
    for pattern, explanation in PATTERNS:
        m = pattern.search(log_text)
        if m:
            # grab a couple of lines of context around the match
            idx = log_text.rfind("\n", 0, m.start())
            end = log_text.find("\n", m.end())
            snippet = log_text[max(0, idx):end if end != -1 else None].strip()
            hits.append((explanation, snippet[:300]))
    if not hits:
        # fall back: last non-empty lines are usually the real error in CI logs
        lines = [l for l in log_text.splitlines() if l.strip()]
        tail = "\n".join(lines[-15:])
        hits.append(("No known pattern matched — showing the last lines of the log for manual triage.", tail[:800]))
    return hits


def ai_diagnose(log_text):
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return None
    try:
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=json.dumps({
                "model": "claude-sonnet-4-6",
                "max_tokens": 500,
                "messages": [{
                    "role": "user",
                    "content": (
                        "This is a GitHub Actions log tail from a failed Buildroot-based "
                        "OS image build (project OPX / rns-router). In 3-5 sentences, say "
                        "what failed and the most likely fix. Log:\n\n" + log_text[-8000:]
                    ),
                }],
            }).encode(),
            headers={
                "Content-Type": "application/json",
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
            },
        )
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
            return "".join(b.get("text", "") for b in data.get("content", []))
    except Exception as e:
        return f"(AI summary unavailable: {e})"


# --- commands ------------------------------------------------------------

def cmd_check(repo, token, workflow_file):
    runs = get_runs(repo, token, workflow_file, per_page=1)
    if not runs:
        print("No runs found yet.")
        return
    r = runs[0]
    print(f"Latest run: #{r['run_number']} ({r['head_branch']}) — status={r['status']} conclusion={r['conclusion']}")
    print(f"URL: {r['html_url']}")


def cmd_diagnose(repo, token, workflow_file, n):
    runs = get_runs(repo, token, workflow_file, per_page=30)
    failed = [r for r in runs if r["conclusion"] == "failure"][:n]
    if not failed:
        print("No failed runs found in recent history.")
        return
    for r in failed:
        print(f"\n=== Run #{r['run_number']} — {r['html_url']} ===")
        jobs = get_jobs(repo, token, r["id"])
        for job in jobs:
            if job["conclusion"] != "failure":
                continue
            print(f"-- job: {job['name']} --")
            log = download_job_log(repo, token, job["id"])
            ai_summary = ai_diagnose(log)
            if ai_summary:
                print("AI diagnosis:", ai_summary.strip())
            else:
                for explanation, snippet in heuristic_diagnose(log):
                    print(f"* {explanation}\n    {snippet}")


def cmd_deploy(repo, token, workflow_file, ref):
    gh_request(
        f"/repos/{repo}/actions/workflows/{workflow_file}/dispatches",
        method="POST",
        token=token,
        data={"ref": ref},
    )
    print(f"Dispatched {workflow_file} on {ref}.")


def cmd_watch(repo, token, workflow_file, ref, timeout=3600, interval=30):
    before = {r["id"] for r in get_runs(repo, token, workflow_file, per_page=5)}
    cmd_deploy(repo, token, workflow_file, ref)
    print("Waiting for the new run to appear...")
    start = time.time()
    run = None
    while time.time() - start < timeout:
        runs = get_runs(repo, token, workflow_file, per_page=5)
        new = [r for r in runs if r["id"] not in before]
        if new:
            run = new[0]
            break
        time.sleep(5)
    if not run:
        die("timed out waiting for the new run to appear")

    print(f"Tracking run #{run['run_number']}: {run['html_url']}")
    while time.time() - start < timeout:
        r = gh_request(f"/repos/{repo}/actions/runs/{run['id']}", token=token)
        if r["status"] == "completed":
            print(f"Finished: conclusion={r['conclusion']}")
            if r["conclusion"] != "success":
                cmd_diagnose(repo, token, workflow_file, 1)
                sys.exit(1)
            return
        print(f"  status={r['status']} ... waiting")
        time.sleep(interval)
    die("timed out waiting for the run to complete")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    d = sub.add_parser("diagnose")
    d.add_argument("--n", type=int, default=1)
    dep = sub.add_parser("deploy")
    dep.add_argument("--ref", default="main")
    w = sub.add_parser("watch")
    w.add_argument("--ref", default="main")
    args = p.parse_args()

    token = env("GITHUB_TOKEN")
    repo = env("GITHUB_REPO")
    workflow_file = env("WORKFLOW_FILE", required=False, default="build-iso.yml")

    if args.cmd == "check":
        cmd_check(repo, token, workflow_file)
    elif args.cmd == "diagnose":
        cmd_diagnose(repo, token, workflow_file, args.n)
    elif args.cmd == "deploy":
        cmd_deploy(repo, token, workflow_file, args.ref)
    elif args.cmd == "watch":
        cmd_watch(repo, token, workflow_file, args.ref)


if __name__ == "__main__":
    main()
