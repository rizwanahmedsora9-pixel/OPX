#!/bin/sh
set -e
# Buildroot calls post-image scripts with the *images* directory ($BINARIES_DIR,
# normally output/images) as the first argument — not the build directory. The
# previous version appended /images to it and so looked in output/images/images/,
# which does not exist; the cp failed and set -e aborted the build at the last
# step. $BINARIES_DIR is also in the environment, so fall back to it.
BINARIES_DIR="${1:-${BINARIES_DIR:-}}"
if [ -z "$BINARIES_DIR" ]; then
  echo "post-image: no images directory given (expected \$1 or \$BINARIES_DIR)." >&2
  exit 1
fi
ISOLINUX_DIR="${BINARIES_DIR}/isolinux"
ISO="${BINARIES_DIR}/rns-router.iso"

for f in bzImage rootfs.squashfs; do
  if [ ! -f "${BINARIES_DIR}/${f}" ]; then
    echo "post-image: ${BINARIES_DIR}/${f} is missing — did the kernel and" >&2
    echo "post-image: squashfs rootfs build?" >&2
    exit 1
  fi
done

mkdir -p "$ISOLINUX_DIR"
cp "$BINARIES_DIR/bzImage" "$ISOLINUX_DIR/bzImage"
cp "$BINARIES_DIR/rootfs.squashfs" "$ISOLINUX_DIR/rootfs.squashfs"

# Buildroot installs isolinux.bin and any C32 modules into
# $(BINARIES_DIR)/syslinux/, not into the isolinux/ layout the ISO needs.
# syslinux 6 will not boot at all without ldlinux.c32 beside isolinux.bin,
# and BR2_TARGET_SYSLINUX_C32 defaults to empty.
SYSLINUX_SRC="${BINARIES_DIR}/syslinux"
if [ ! -f "${SYSLINUX_SRC}/isolinux.bin" ]; then
  echo "post-image: ${SYSLINUX_SRC}/isolinux.bin is missing." >&2
  echo "post-image: enable BR2_TARGET_SYSLINUX_ISOLINUX=y." >&2
  exit 1
fi
cp "${SYSLINUX_SRC}/isolinux.bin" "$ISOLINUX_DIR/isolinux.bin"
for m in "$SYSLINUX_SRC"/*.c32; do
  [ -e "$m" ] || continue
  cp "$m" "$ISOLINUX_DIR/"
done
if [ ! -f "$ISOLINUX_DIR/ldlinux.c32" ]; then
  echo "post-image: ldlinux.c32 is missing — syslinux 6 will not boot this ISO." >&2
  echo "post-image: set BR2_TARGET_SYSLINUX_C32=\"ldlinux.c32\" in the defconfig." >&2
  exit 1
fi

# Boot menu. 'rns' (live, the default) runs the whole system from RAM and
# writes nothing; 'install' boots the same live system with the 'install'
# kernel argument, which makes rns-tty1.sh run the on-disk installer
# (usr/share/rns/bin/rns-install.sh) before dropping to the login prompt.
cat > "$ISOLINUX_DIR/isolinux.cfg" <<CFG
MENU TITLE OPX Router OS
PROMPT 1
TIMEOUT 200
ONTIMEOUT rns
LABEL rns
  MENU LABEL ^Live system (runs from RAM; nothing is written)
  KERNEL /bzImage
  APPEND root=/dev/ram0 rootfstype=squashfs ro console=tty0 console=ttyS0,115200 quiet
  INITRD /rootfs.squashfs
LABEL install
  MENU LABEL ^Install to disk (destroys the chosen hard drive)
  KERNEL /bzImage
  APPEND root=/dev/ram0 rootfstype=squashfs ro console=tty0 console=ttyS0,115200 quiet install
  INITRD /rootfs.squashfs
CFG

# The installer dd's mbr.bin onto the target disk's master boot record at
# install time (rns-install.sh reads it back from the ISO under /install/).
if [ ! -f "${SYSLINUX_SRC}/mbr.bin" ]; then
  echo "post-image: ${SYSLINUX_SRC}/mbr.bin is missing — enable BR2_TARGET_SYSLINUX_MBR=y." >&2
  exit 1
fi
mkdir -p "${BINARIES_DIR}/install"
cp "${SYSLINUX_SRC}/mbr.bin" "${BINARIES_DIR}/install/mbr.bin"

# Buildroot puts host-xorriso in $(HOST_DIR)/bin, which is on PATH while the
# post-image script runs. Fall back to a host mkisofs/genisoimage so the build
# still works without it. RNS_MKISO pins the choice (used by the test suite,
# and handy if a build host has more than one installed).
MKISO="${RNS_MKISO:-}"
if [ -n "$MKISO" ]; then
  if ! command -v "$MKISO" >/dev/null 2>&1; then
    echo "post-image: RNS_MKISO=$MKISO is not on PATH." >&2
    exit 1
  fi
else
  for _c in xorriso genisoimage mkisofs; do
    if command -v "$_c" >/dev/null 2>&1; then MKISO="$_c"; break; fi
  done
fi
if [ -z "$MKISO" ]; then
  echo "post-image: no xorriso/genisoimage/mkisofs found." >&2
  echo "post-image: add BR2_PACKAGE_HOST_XORRISO=y to the defconfig." >&2
  exit 1
fi

if [ "$MKISO" = "xorriso" ]; then
  xorriso -as mkisofs -o "$ISO" \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -J -R -V "RNS_ROUTER" "$BINARIES_DIR"
else
  "$MKISO" -o "$ISO" -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -J -R -V "RNS_ROUTER" "$BINARIES_DIR"
fi

# Informational, not fatal: a 6.6 kernel plus iptables, dnsmasq, hostapd,
# dropbear and socat will not fit in 10 MB, and failing the build here only
# throws away a working image.
ISO_BYTES=$(wc -c < "$ISO")
echo "ISO: $ISO (${ISO_BYTES} bytes)"
if [ "$ISO_BYTES" -ge 10000000 ]; then
  echo "post-image: note — ISO is ${ISO_BYTES} bytes, over the 10 MB target." >&2
fi
ls -lh "$ISO"
