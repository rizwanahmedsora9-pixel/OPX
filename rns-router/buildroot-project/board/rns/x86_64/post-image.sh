#!/bin/sh
set -e
BUILD_DIR="$1"
BINARIES_DIR="${BUILD_DIR}/images"
ISOLINUX_DIR="${BINARIES_DIR}/isolinux"
ISO="${BINARIES_DIR}/rns-router.iso"
mkdir -p "$ISOLINUX_DIR"
cp "$BINARIES_DIR/bzImage" "$ISOLINUX_DIR/bzImage"
cp "$BINARIES_DIR/rootfs.squashfs" "$ISOLINUX_DIR/rootfs.squashfs"
cat > "$ISOLINUX_DIR/isolinux.cfg" <<CFG
DEFAULT rns
PROMPT 0
TIMEOUT 20
LABEL rns
  KERNEL /bzImage
  APPEND root=/dev/sr0 rootfstype=squashfs ro console=tty0 console=ttyS0,115200 quiet
  INITRD /rootfs.squashfs
CFG
genisoimage -o "$ISO" -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -J -R -V "RNS_ROUTER" "$BINARIES_DIR"
ISO_BYTES=$(wc -c < "$ISO")
if [ "$ISO_BYTES" -ge 10000000 ]; then
  echo "ISO is ${ISO_BYTES} bytes; target is under 10,000,000 bytes." >&2
  exit 1
fi
ls -lh "$ISO"
