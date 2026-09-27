#!/usr/bin/env bash
# Build rns-router.iso with Buildroot.
#
#   ./build.sh                     # buildroot 2024.02.3, all cores
#   BR_VER=2024.05 ./build.sh      # another buildroot release
#   JOBS=4 ./build.sh              # limit parallelism
#   BR2_DL_DIR=/cache/dl ./build.sh
#
# The same script runs locally and in .github/workflows/build-iso.yml, so CI
# never builds something a human cannot reproduce.
#
# The first run downloads buildroot plus every source tarball (kernel, musl,
# iptables, hostapd, socat, syslinux, ...), so it needs a working network and
# several GB of disk. Later runs reuse buildroot-<ver>/ and the dl/ cache.
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR_VER="${BR_VER:-2024.02.3}"
BR_DIR="$PROJ/buildroot-$BR_VER"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
export BR2_DL_DIR="${BR2_DL_DIR:-$PROJ/dl}"

missing=""
for t in curl tar make; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
  missing="$missing gcc-or-clang"
fi
if [ -n "$missing" ]; then
  echo "build: missing required tools:$missing" >&2
  echo "  Debian/Ubuntu: apt install build-essential git wget cpio unzip rsync bc libncurses-dev xz-utils bison flex file" >&2
  echo "  Termux:        pkg install curl tar make clang bison flex rsync" >&2
  exit 1
fi

case "$PROJ" in
  *" "*) echo "build: the path '$PROJ' contains a space; buildroot will not like it." >&2; exit 1 ;;
esac

# Buildroot will not run as root.
if [ "$(id -u)" = "0" ]; then
  echo "build: refusing to run as root — buildroot requires a normal user." >&2
  exit 1
fi

if [ ! -d "$BR_DIR" ]; then
  if [ ! -f "$PROJ/buildroot-$BR_VER.tar.xz" ]; then
    echo "==> downloading buildroot $BR_VER"
    curl -fL --retry 3 -o "$PROJ/buildroot-$BR_VER.tar.xz" \
      "https://buildroot.org/downloads/buildroot-$BR_VER.tar.xz"
  fi
  echo "==> unpacking"
  tar xf "$PROJ/buildroot-$BR_VER.tar.xz" -C "$PROJ"
fi

mkdir -p "$BR2_DL_DIR"
cd "$BR_DIR"

echo "==> configuring (BR2_EXTERNAL=$PROJ/buildroot-project, BR2_DL_DIR=$BR2_DL_DIR)"
make BR2_EXTERNAL="$PROJ/buildroot-project" rns_x86_64_defconfig

echo "==> building with $JOBS jobs"
make BR2_EXTERNAL="$PROJ/buildroot-project" -j"$JOBS"

ISO="$BR_DIR/output/images/rns-router.iso"
if [ ! -s "$ISO" ]; then
  echo "build: the build finished but $ISO was not produced." >&2
  echo "build: look for a post-image.sh failure above." >&2
  exit 1
fi

echo
echo "==> built"
ls -lh "$ISO"
sha256sum "$ISO" 2>/dev/null || shasum -a 256 "$ISO"
echo
echo "Boot it with: qemu-system-x86_64 -m 512 -cdrom '$ISO' -boot d -nographic"
