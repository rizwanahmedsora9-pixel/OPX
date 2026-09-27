#!/usr/bin/env bash
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
BR_DIR="$(ls -d "$PROJ"/buildroot-* 2>/dev/null | head -n1)"
ISO="$BR_DIR/output/images/rns-router.iso"
[ -f "$ISO" ] || { echo "Run build-in-termux.sh first."; exit 1; }
exec qemu-system-x86_64 -m 512 -cdrom "$ISO" -boot d \
  -netdev user,id=wan -device e1000,netdev=wan \
  -netdev user,id=lan,hostfwd=tcp::8080-:8080 -device e1000,netdev=lan \
  -nographic -no-reboot
