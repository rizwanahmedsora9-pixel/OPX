# OPX

Operating system for a router.

`rns-router/` holds the first target: an x86_64 Buildroot image that runs a
voucher-based captive-portal gateway — DHCP/DNS on a bridge, an optional
Wi-Fi AP, a paywall enforced with iptables, and a staff admin panel. It is
POSIX shell plus two HTML files; no database and no language runtime.

```sh
cd rns-router
./build.sh              # build rns-router.iso (needs network on first run)
./run-qemu.sh           # boot it; portal on http://127.0.0.1:8080
sh tests/run-tests.sh   # regression suite; no root, no network
```

Burn the ISO raw to a USB stick (dd / balenaEtcher / Rufus DD mode) and it
boots to a menu: **Live** (everything in RAM, disks untouched) or
**Install** (a console installer that writes OPX to a chosen disk with a
persistent data partition — BIOS boot only).

`.github/workflows/build-iso.yml` runs that suite on every push and pull
request, builds the ISO on branch pushes and tags, uploads it as an
artifact, and attaches it to a GitHub release for `v*` tags.

See [rns-router/README.md](rns-router/README.md) for the layout, how a
request flows through the gateway, the CI setup and the security notes.
