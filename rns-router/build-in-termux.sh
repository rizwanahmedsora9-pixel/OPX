#!/usr/bin/env bash
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
BR_VER="2024.02.3"
BR_DIR="$PROJ/buildroot-$BR_VER"
if [ ! -d "$BR_DIR" ]; then
  cd "$PROJ"
  [ -f "buildroot-$BR_VER.tar.xz" ] || curl -fLO "https://buildroot.org/downloads/buildroot-$BR_VER.tar.xz"
  tar xf "buildroot-$BR_VER.tar.xz"
fi
cd "$BR_DIR"
make BR2_EXTERNAL="$PROJ/buildroot-project" rns_x86_64_defconfig
make -j"$(nproc)"
echo "ISO: $BR_DIR/output/images/rns-router.iso"
