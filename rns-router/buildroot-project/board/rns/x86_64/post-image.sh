#!/bin/sh
set -e
# Buildroot calls post-image scripts with the *images* directory ($BINARIES_DIR,
# normally output/images) as the first argument — not the build directory.
BINARIES_DIR="${1:-${BINARIES_DIR:-}}"
if [ -z "$BINARIES_DIR" ]; then
  echo "post-image: no images directory given (expected \$1 or \$BINARIES_DIR)." >&2
  exit 1
fi
ISOLINUX_DIR="${BINARIES_DIR}/isolinux"
ISO="${BINARIES_DIR}/rns-router.iso"
BOARD_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
BACKGROUND_SOURCE="$BOARD_DIR/boot-background.png"

for f in bzImage rootfs.squashfs; do
  if [ ! -f "${BINARIES_DIR}/${f}" ]; then
    echo "post-image: ${BINARIES_DIR}/${f} is missing — did the kernel and" >&2
    echo "post-image: squashfs rootfs build?" >&2
    exit 1
  fi
done

# This directory is derived output. Recreate it so a removed C32 module cannot
# be hidden by a stale copy from an earlier incremental build.
rm -rf "$ISOLINUX_DIR"
mkdir -p "$ISOLINUX_DIR"
cp "$BINARIES_DIR/bzImage" "$ISOLINUX_DIR/bzImage"
cp "$BINARIES_DIR/rootfs.squashfs" "$ISOLINUX_DIR/rootfs.squashfs"

# Buildroot installs isolinux.bin and requested C32 modules into
# $(BINARIES_DIR)/syslinux/. Syslinux 6 needs ldlinux.c32 to boot; VESAMENU and
# its libraries render the branded RNS startup screen.
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
for f in ldlinux.c32 vesamenu.c32 libcom32.c32 libutil.c32 chain.c32 reboot.c32; do
  if [ ! -f "$ISOLINUX_DIR/$f" ]; then
    echo "post-image: $f is missing — the boot menu cannot start." >&2
    echo "post-image: include it in BR2_TARGET_SYSLINUX_C32." >&2
    exit 1
  fi
done
if [ ! -f "$BACKGROUND_SOURCE" ]; then
  echo "post-image: branded boot background is missing: $BACKGROUND_SOURCE" >&2
  exit 1
fi
cp "$BACKGROUND_SOURCE" "$ISOLINUX_DIR/boot-background.png"

cat > "$ISOLINUX_DIR/isolinux.cfg" <<'CFG'
SERIAL 0 115200
UI vesamenu.c32
DEFAULT live
ONTIMEOUT live
PROMPT 0
TIMEOUT 100

MENU TITLE RNS Gateway - Boot Options
MENU RESOLUTION 640 480
MENU BACKGROUND boot-background.png
MENU AUTOBOOT Starting RNS OS in # second{,s}...
MENU TABMSG Arrow keys: select   Enter: start   Tab: edit options
MENU WIDTH 62
MENU MARGIN 3
MENU ROWS 6
MENU VSHIFT 8
MENU TABMSGROW 23
MENU CMDLINEROW 23
MENU HELPMSGROW 20
MENU HELPMSGENDROW 21
MENU TIMEOUTROW 24

# RNS portal palette: navy surfaces, aqua selection, gold countdown.
MENU COLOR screen      0  #00000000 #00000000 none
MENU COLOR border      0  #00000000 #00000000 none
MENU COLOR title       0  #ff6fe3da #00000000 none
MENU COLOR sel         0  #ff062229 #ff6fe3da none
MENU COLOR hotsel      0  #ff062229 #fff2c777 none
MENU COLOR unsel       0  #fff2f8fa #00000000 none
MENU COLOR hotkey      0  #ff6fe3da #00000000 none
MENU COLOR disabled    0  #ff607783 #00000000 none
MENU COLOR help        0  #ff9fb4bf #00000000 none
MENU COLOR tabmsg      0  #ff78919e #00000000 none
MENU COLOR cmdmark     0  #ff6fe3da #00000000 none
MENU COLOR cmdline     0  #fff2f8fa #ff071420 none
MENU COLOR scrollbar  0  #ff6fe3da #4010263a none
MENU COLOR timeout_msg 0  #ff9fb4bf #00000000 none
MENU COLOR timeout     0  #fff2c777 #00000000 none

LABEL live
  MENU LABEL ^Start RNS OS  -  Live Mode
  MENU DEFAULT
  KERNEL bzImage
  APPEND root=/dev/ram0 rootfstype=squashfs ro console=tty0 console=ttyS0,115200 quiet
  INITRD rootfs.squashfs
  TEXT HELP
    Start the full RNS gateway directly from this media.
  ENDTEXT

LABEL install
  MENU LABEL ^Install RNS OS to Disk
  KERNEL bzImage
  APPEND root=/dev/ram0 rootfstype=squashfs ro console=tty0 console=ttyS0,115200 rns.mode=install
  INITRD rootfs.squashfs
  TEXT HELP
    Install RNS OS and persistent router data to a selected disk.
  ENDTEXT

LABEL compatibility
  MENU LABEL RNS OS  -  ^Compatibility Mode
  KERNEL bzImage
  APPEND root=/dev/ram0 rootfstype=squashfs ro console=tty0 console=ttyS0,115200 nomodeset noapic nolapic
  INITRD rootfs.squashfs
  TEXT HELP
    Use conservative video and interrupt settings for older hardware.
  ENDTEXT

LABEL serial
  MENU LABEL RNS OS  -  ^Serial Console Mode
  KERNEL bzImage
  APPEND root=/dev/ram0 rootfstype=squashfs ro console=ttyS0,115200 rns.console=serial quiet
  INITRD rootfs.squashfs
  TEXT HELP
    Headless startup on COM1 at 115200 baud for appliances and servers.
  ENDTEXT

LABEL local
  MENU LABEL ^Boot from Local Disk
  COM32 chain.c32
  APPEND hd0
  TEXT HELP
    Leave the installer media and start the first virtual or physical disk.
  ENDTEXT

LABEL reboot
  MENU LABEL ^Restart Computer
  COM32 reboot.c32
  TEXT HELP
    Restart this computer without starting RNS OS.
  ENDTEXT
CFG

# Buildroot puts host-xorriso in $(HOST_DIR)/bin, which is on PATH while this
# script runs. RNS_MKISO pins the choice in tests or on unusual build hosts.
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

# A copied ISO must also boot as a hard disk for the installer to work. Xorriso
# embeds Syslinux's matching isohybrid MBR while mastering the ISO. Buildroot's
# syslinux package installs this template under HOST_DIR/share/syslinux.
ISOHYBRID_MBR="${RNS_ISOHYBRID_MBR:-}"
if [ -z "$ISOHYBRID_MBR" ] && [ -n "${HOST_DIR:-}" ]; then
  ISOHYBRID_MBR="$HOST_DIR/share/syslinux/isohdpfx.bin"
fi
if [ -z "$ISOHYBRID_MBR" ] || [ ! -f "$ISOHYBRID_MBR" ]; then
  for _m in /usr/share/syslinux/isohdpfx.bin \
            /usr/lib/ISOLINUX/isohdpfx.bin \
            /usr/lib/syslinux/isohdpfx.bin; do
    if [ -f "$_m" ]; then ISOHYBRID_MBR="$_m"; break; fi
  done
fi

rm -f "$ISO"
case "${MKISO##*/}" in
  xorriso)
    if [ -z "$ISOHYBRID_MBR" ] || [ ! -f "$ISOHYBRID_MBR" ]; then
      echo "post-image: Syslinux isohdpfx.bin is missing; cannot make an installable ISO." >&2
      exit 1
    fi
    "$MKISO" -as mkisofs -o "$ISO" \
      -b isolinux/isolinux.bin -c isolinux/boot.cat \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      -isohybrid-mbr "$ISOHYBRID_MBR" -partition_offset 16 \
      -J -R -V "RNS_ROUTER" "$BINARIES_DIR"
    ;;
  *)
    "$MKISO" -o "$ISO" -b isolinux/isolinux.bin -c isolinux/boot.cat \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      -J -R -V "RNS_ROUTER" "$BINARIES_DIR"

    # genisoimage/mkisofs cannot embed the MBR themselves. Patch the completed
    # image with the Syslinux isohybrid utility from the same build.
    ISOHYBRID="${RNS_ISOHYBRID:-}"
    if [ -z "$ISOHYBRID" ] && [ -x "${HOST_DIR:-}/bin/isohybrid" ]; then
      ISOHYBRID="$HOST_DIR/bin/isohybrid"
    fi
    if [ -z "$ISOHYBRID" ]; then ISOHYBRID=$(command -v isohybrid 2>/dev/null || true); fi
    if [ -z "$ISOHYBRID" ] || [ ! -x "$ISOHYBRID" ]; then
      echo "post-image: isohybrid is required when using ${MKISO##*/}." >&2
      rm -f "$ISO"
      exit 1
    fi
    "$ISOHYBRID" "$ISO"
    ;;
esac

# Informational, not fatal: the complete router and installer are expected to
# exceed the original 10 MB experiment target.
ISO_BYTES=$(wc -c < "$ISO")
echo "ISO: $ISO (${ISO_BYTES} bytes)"
if [ "$ISO_BYTES" -ge 10000000 ]; then
  echo "post-image: note — ISO is ${ISO_BYTES} bytes, over the 10 MB target." >&2
fi
ls -lh "$ISO"
