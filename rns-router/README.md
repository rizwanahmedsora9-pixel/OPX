# RNS Gateway Router OS

A minimal x86_64 captive-portal router built with Buildroot: DHCP + DNS on a
bridge, an optional Wi-Fi AP, a voucher-based paywall enforced with iptables,
and a staff admin panel. Everything except the kernel and the packages
Buildroot fetches is POSIX shell plus two HTML files — no database, no web
framework, no language runtime.

```
rns-router/
  build-in-termux.sh        download buildroot and build the ISO
  run-qemu.sh               boot the ISO under qemu, portal on :8080
  tests/run-tests.sh        regression suite, runs without root
  buildroot-project/
    external.desc/.mk, Config.in
    configs/rns_x86_64_defconfig
    package/rns/            installs the overlay scripts
    board/rns/x86_64/
      kernel.config         hand-written 6.6 config
      post-build.sh         permissions, /data skeleton
      post-image.sh         builds rns-router.iso
      rootfs-overlay/
        etc/                inittab, dnsmasq.conf, hostapd.conf, fstab
        etc/init.d/         S10mounts S20network S30dnsmasq S40hostapd
                            S50gate S60rnsd S70portal
        usr/share/rns/bin/  the gateway itself
        usr/share/rns/www/  portal.html, admin.html
```

## Building

```sh
cd rns-router
./build-in-termux.sh          # needs network on the first run
./run-qemu.sh                 # portal at http://127.0.0.1:8080
```

Output: `buildroot-2024.02.3/output/images/rns-router.iso`. The ISO is
isolinux-booted: the squashfs root is loaded as an initrd, which is why
`kernel.config` enables `BLK_DEV_INITRD`, `BLK_DEV_RAM` and a 64 MB
`BLK_DEV_RAM_SIZE`.

## Testing

```sh
sh tests/run-tests.sh
```

Runs the real overlay scripts under busybox — no root, no network, no
firewall. It covers shell syntax, address parsing, the whole voucher
lifecycle, a live socat listener serving `/health`, the portal, the admin
page and the authenticated API, the boot-time generation of the dnsmasq and
hostapd configs, and the build/firewall configuration. socat is the only
optional dependency; without it the live listener case is skipped.

## How a request flows

1. `socat TCP-LISTEN:8080,reuseaddr,fork` forks a child per connection and
   exports the peer as `SOCAT_PEERADDR`.
2. `rns-front.sh` serves the static pages and delegates `/api/*` to
   `rns-http.sh`, passing the peer address on.
3. `common.sh resolve_client_ip` turns that into a validated IPv4, and
   `store.sh mac_for_ip` looks the device up in the ARP table.
4. `voucher_redeem` binds the code to that MAC; `net.sh fw_rebuild` adds a
   per-MAC ACCEPT in front of the captive DROP.

`rnsd.sh` re-runs pages, housekeeping and the firewall every 15 s so an
expired voucher is revoked even if nothing else is watching.

## Layout on the device

`/etc` is a read-only squashfs. Anything a boot script needs to write goes
under `/data/rns` (a partition labelled `RNS-DATA` if present, tmpfs
otherwise): `config.env`, `database/*.tsv`, `logs/`, `sessions/`, and the
generated `dnsmasq.conf` and `hostapd.conf`.

## Security notes

- The admin panel is reachable from the LAN only; `S50gate` drops 8080 and
  22 from the WAN side. Set the admin password on first visit.
- `FORWARD` defaults to `DROP`. Nothing reaches the internet until a voucher
  says so.
- The image ships with an **empty root password** and SSH closed on every
  interface. `rns-ctl ssh on` opens 22 on the LAN — set a real root password
  first, or drop `BR2_PACKAGE_DROPBEAR` from the defconfig.
- Unauthenticated clients get DNS and DHCP, a redirect from port 80, and a
  TCP reset on 443. Everything else is dropped.

## Operator CLI

```sh
rns-ctl status | packages | mint <plan> [n] | expire
rns-ctl kick <mac> | ban <mac> | unban <mac>
rns-ctl pause | resume | setpass <pw> | clients
rns-ctl ssh on|off|status
```
