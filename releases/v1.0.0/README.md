# OPX Router OS — v1.0.0 release reference

This directory is the durable reference for the first known-good release. Keep
this release record unchanged; use a new version directory for later releases.

## Known-good build

- Product: RNS Gateway Router OS (x86_64)
- Source commit reported by the operator: `2fe745e`
- Source branch reported by the operator: `arena/01a0e27a-opx`
- Build: GitHub Actions workflow **build-iso**, successful
- Build duration reported: 36m 37s
- Artifact: `rns-router-<run-number>-<sha>` containing `rns-router.iso`
- Artifact retention: 30 days (per workflow configuration)

The commit and run details above were supplied from the successful Actions run;
they have not been independently verified from this checkout. Record the full
40-character commit SHA, Actions run URL/number, and ISO SHA-256 below when
available. Do not treat an artifact name or abbreviated hash as a substitute
for the actual image checksum.

## Image provenance (complete from the Actions run)

- Full source SHA: `TODO`
- Actions run URL: `TODO`
- ISO SHA-256: `TODO`
- Downloaded image filename/location: `TODO`
- Tested hardware / VM configuration: `TODO`
- Test date and notes: `TODO`

## Access notes

- Captive portal: `http://<router-lan-ip>:8080/`
- Staff administration: `http://<router-lan-ip>:8080/admin`
- The admin password is the password set on that installed router. Do not
  record it in this file or commit it to the repository.

## Reproduce and verify

Build from the recorded source revision using `rns-router/build.sh` and the
Buildroot version pinned in `.github/workflows/build-iso.yml`. The build
workflow uploads its ISO as a temporary Actions artifact; download and preserve
the ISO and its SHA-256 checksum in an appropriate release asset store. Avoid
committing large binary images to Git.

For future work, make changes on the development branch, run
`sh rns-router/tests/run-tests.sh`, build and test a candidate image, then add
a new immutable release record such as `releases/v1.0.1/`. Do not edit this
v1.0.0 record to describe later builds.
