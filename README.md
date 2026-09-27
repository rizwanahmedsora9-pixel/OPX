# OPX

Operating system for a router.

`rns-router/` holds the first target: an x86_64 Buildroot image that runs a
voucher-based captive-portal gateway — DHCP/DNS on a bridge, an optional
Wi-Fi AP, a paywall enforced with iptables, and a staff admin panel. It is
POSIX shell plus two HTML files; no database and no language runtime.

```sh
cd rns-router
./build-in-termux.sh    # build rns-router.iso (needs network on first run)
./run-qemu.sh           # boot it; portal on http://127.0.0.1:8080
sh tests/run-tests.sh   # regression suite; no root, no network
```

See [rns-router/README.md](rns-router/README.md) for the layout, how a
request flows through the gateway, and the security notes.
