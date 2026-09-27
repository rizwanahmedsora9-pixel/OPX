#!/usr/bin/env bash
# Build the RNS router ISO with Buildroot.
#
#   ./build-in-termux.sh                     # buildroot 2024.02.3
#   BR_VER=2024.05 ./build-in-termux.sh      # another buildroot release
#   JOBS=4 ./build-in-termux.sh
#
# The first run downloads buildroot plus every source tarball (kernel, musl,
# iptables, hostapd, socat, ...), so it needs a working network and a few GB
# of disk. Later runs reuse buildroot-<ver>/ and its dl/ cache.
#
# On Termux the host compiler is clang; buildroot needs BR2_HOST_CXX and a
# few host packages (bison, flex, rsync) and x86_64 cross builds on Android
# are fragile. A normal Linux box or container is the reliable path.
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
BR_VER="${BR_VER:-2024.02.3}"
BR_DIR="$PROJ/buildroot-$BR_VER"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

missing=""
for t in curl tar make; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
  missing="$missing gcc-or-clang"
fi
if [ -n "$missing" ]; then
  echo "build-in-termux: missing required tools:$missing" >&2
  echo "  Termux:  pkg install curl tar make clang bison flex rsync" >&2
  echo "  Debian:  apt install curl tar make gcc bison flex rsync cpio file" >&2
  exit 1
fi

case "$PROJ" in
  *" "*) echo "build-in-termux: the path '$PROJ' contains a space; buildroot will not like it." >&2; exit 1 ;;
esac

if [ ! -d "$BR_DIR" ]; then
  cd "$PROJ"
  if [ ! -f "buildroot-$BR_VER.tar.xz" ]; then
    echo "==> downloading buildroot $BR_VER"
    curl -fLO "https://buildroot.org/downloads/buildroot-$BR_VER.tar.xz"
  fi
  echo "==> unpacking"
  tar xf "buildroot-$BR_VER.tar.xz"
fi

cd "$BR_DIR"
echo "==> configuring (BR2_EXTERNAL=$PROJ/buildroot-project)"
make BR2_EXTERNAL="$PROJ/buildroot-project" rns_x86_64_defconfig
echo "==> building with $JOBS jobs"
make -j"$JOBS"

echo
echo "ISO: $BR_DIR/output/images/rns-router.iso"
echo "Run ./run-qemu.sh to boot it, then open http://127.0.0.1:8080/admin"
