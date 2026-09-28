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
        usr/share/rns/bin/  the gateway itself
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

Output: `buildroot-2024.02.3/output/images/rns-router.iso`. On boot, a
branded RNS VESAMENU stays visible for 10 seconds. Its navy, aqua and gold
styling matches the portal and staff panel. It offers live, install,
compatibility, serial-console, local-disk and restart actions. The squashfs
root is loaded as an initrd, which is why `kernel.config` enables
`BLK_DEV_INITRD`, `BLK_DEV_RAM` and a 64 MB `BLK_DEV_RAM_SIZE`. The defconfig
includes `ldlinux.c32`, `vesamenu.c32`, its libraries and the action modules;
Syslinux 6 needs those files beside `isolinux.bin`. The image is mastered as a
BIOS isohybrid, so the installer can copy the same bootable image to a hard
disk and add a persistent `RNS-DATA` partition.

## VirtualBox: Live Boot and installation

1. Create an **Other Linux (64-bit)** VM with at least 512 MB RAM and a virtual
   hard disk of at least 1 GB. Leave **Enable EFI** off; this image currently
   uses legacy BIOS/ISOLINUX.
2. Attach `rns-router.iso` to the VM's optical drive and start the VM.
3. The **RNS Gateway — Boot Options** menu appears. Use the arrow keys and
   Enter. Available actions are:
   - **Start RNS OS — Live Mode** runs the gateway directly from the ISO.
   - **Install RNS OS to Disk** starts the text installer.
   - **Compatibility Mode** uses conservative settings for older hardware.
   - **Serial Console Mode** starts headless on COM1 at 115200 baud.
   - **Boot from Local Disk** leaves the ISO and starts the first disk.
   - **Restart Computer** restarts without booting RNS OS.
4. The installer lists the VM's disks and asks for an exact `ERASE /dev/...`
   confirmation. **The selected disk is completely erased.** It installs the
   bootable read-only system and uses the remaining space for persistent
   settings, vouchers, logs and backups.
5. When installation completes, let it eject the ISO and reboot. If VirtualBox
   does not allow guest ejection, power off, remove the ISO in
   **Settings → Storage**, and start the VM from its virtual hard disk.

The Live option starts automatically after 10 seconds. If the menu does not
appear at all, confirm that the ISO is attached, Optical is before Hard Disk in
**System → Boot Order**, and EFI is disabled.

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
under `/data/rns`: the installer creates and labels an ext4 `RNS-DATA`
partition from the disk's remaining space, and the boot scripts discover it
by label on any supported disk controller. A Live boot without that partition
uses tmpfs instead. Persistent content includes `config.env`,
`database/*.tsv`, `logs/`, `sessions/`, and the generated `dnsmasq.conf` and
`hostapd.conf`.

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
