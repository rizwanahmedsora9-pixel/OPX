# RNS Gateway Router OS

A minimal x86_64 captive-portal router built with Buildroot: DHCP + DNS on a
bridge, an optional Wi-Fi AP, a voucher-based paywall enforced with iptables,
and a staff admin panel. Everything except the kernel and the packages
Buildroot fetches is POSIX shell plus two HTML files — no database, no web
framework, no language runtime.

```
rns-router/
  build.sh                download buildroot and build the ISO
  build-in-termux.sh      alias for build.sh
  run-qemu.sh             boot the ISO under qemu, portal on :8080
  tests/run-tests.sh      regression suite, runs without root
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
        usr/share/rns/bin/  the gateway itself + the disk installer
        usr/share/rns/www/  portal.html, admin.html
```

## Building

```sh
cd rns-router
./build.sh                # needs network on the first run
./run-qemu.sh             # portal at http://127.0.0.1:8080
```

`build.sh` is the single builder — CI runs the same script, so what the
workflow produces is reproducible locally. `BR_VER`, `JOBS` and `BR2_DL_DIR`
override the buildroot version, the parallelism and the download cache
location. `build-in-termux.sh` is kept as an alias.

Output: `buildroot-2024.02.3/output/images/rns-router.iso`. The ISO is
isolinux-booted: the squashfs root is loaded as an initrd, which is why
`kernel.config` enables `BLK_DEV_INITRD`, `BLK_DEV_RAM` and a 64 MB
`BLK_DEV_RAM_SIZE`, and why the defconfig pins `BR2_TARGET_SYSLINUX_C32="ldlinux.c32"`
— syslinux 6 will not boot without that module beside `isolinux.bin`.

## Boot menu and install to disk

Burn the ISO **raw** to a USB stick — `dd if=rns-router.iso of=/dev/sdX
bs=4M status=progress`, balenaEtcher, or Rufus in *DD image* mode (ISO mode
makes isolinux misbehave on many machines). Booting the stick shows a
two-entry menu:

| entry | what it does |
|---|---|
| **Live** (default after the 20 s timeout) | boots entirely into RAM; hard disks are not touched |
| **Install** | drops to a console installer on tty1, then reboots into the installed system |

The installer is BIOS/legacy boot only — the image has no UEFI support.
It lists the whole disks (names, sizes), asks for one, shows a warning that
everything on it is destroyed, and requires you to type `yes`. Then it:

1. writes an MBR layout with `fdisk` — `p1` ext4, active: root filesystem
   with `/boot` and `bzImage`; `p2` ext4 labelled `RNS-DATA`: vouchers,
   config, logs;
2. copies the live root filesystem to `p1` (volatile paths — `/proc`,
   `/sys`, `/dev`, `/data`, `/tmp`, … — are excluded) and carries the live
   `/data/rns` state across to `RNS-DATA`, so existing vouchers and
   configuration survive the install;
3. installs the bootloader — `extlinux` into `/boot` on `p1` (the
   `extlinux-target` package builds syslinux 6.03 for the target so the
   binary runs in the live rootfs) and syslinux `mbr.bin`, staged in the
   ISO under `/install/`, into the disk's master boot record;
4. unmounts everything and offers a reboot.

After the reboot the machine runs OPX straight from the hard drive, the USB
stick can come out, and `/data` (mounted from the `RNS-DATA` label by
`S10mounts`) persists across reboots. The installer refuses the disk it
booted from, refuses disks with mounted filesystems, and refuses anything
under 512 MB. No LVM, no RAID, no UEFI — deliberately plain.

## Continuous integration

`.github/workflows/build-iso.yml` has three jobs:

| job | runs on | what it does |
|---|---|---|
| `test` | every push and PR | installs busybox + socat, runs `tests/run-tests.sh` |
| `build` | pushes to any branch, tags, manual dispatch | builds the ISO and uploads it as an artifact |
| `release` | `v*` tags only | attaches the ISO and its sha256 to a GitHub release |

Pull requests deliberately skip `build` — a full Buildroot run (musl
toolchain, kernel 6.6, every package) takes the better part of an hour.
Use **Actions → build-iso → Run workflow** to build an ISO from a branch
without pushing it. Artifacts are named `rns-router-<run>-<sha>` and kept for
30 days; the `dl/` download cache is keyed on the buildroot version and the
contents of `buildroot-project/`.

The `build` job needs roughly 10 GB of disk and an hour or more on a
2-core runner; it starts by deleting the runner's dotnet/Android/GHC images
to make room.

## Testing


```sh
sh tests/run-tests.sh
```

Runs the real overlay scripts under busybox — no root, no network, no
firewall. It covers shell syntax, address parsing, the whole voucher
lifecycle, a live socat listener serving `/health`, the portal, the admin
page and the authenticated API, the boot-time generation of the dnsmasq and
hostapd configs, the build/firewall configuration, and the disk installer —
run against fake sysfs/dev trees and stubbed fdisk/mke2fs/extlinux,
including its refusals (boot medium, mounted disks, small disks) and the
tty1 install-mode console. socat is the only optional dependency; without
it the live listener case is skipped.

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
generated `dnsmasq.conf` and `hostapd.conf`. On a live boot that is tmpfs —
rebooting loses it. After an install, `S10mounts` finds the `RNS-DATA`
partition (the `p2` the installer created) by its label, so `/data/rns`
persists across reboots.

## Security notes

- **Testing mode:** the admin panel listens on all guest interfaces and port 8080 is allowed by the firewall. The QEMU launcher forwards host port 8080 on all host interfaces, so use `http://<your-PC-IP>:8080/admin` from another device on your test network. Do not expose this setup to an untrusted network; restrict the forward/firewall before deployment.
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
