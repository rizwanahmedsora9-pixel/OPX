#!/bin/sh
set -e
TARGET_DIR="$1"
chmod 755 "$TARGET_DIR"/etc/init.d/S* 2>/dev/null || true
chmod 755 "$TARGET_DIR"/usr/share/rns/bin/*.sh 2>/dev/null || true
mkdir -p "$TARGET_DIR/etc/dropbear"
chmod 700 "$TARGET_DIR/etc/dropbear"
