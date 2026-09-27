#!/bin/sh
set -e
TARGET_DIR="$1"
chmod 755 "$TARGET_DIR"/etc/init.d/S* 2>/dev/null || true
chmod 755 "$TARGET_DIR"/usr/share/rns/bin/*.sh 2>/dev/null || true
mkdir -p "$TARGET_DIR/etc/dropbear"
chmod 700 "$TARGET_DIR/etc/dropbear"

# /etc is a read-only squashfs at runtime. Anything a boot script needs to
# write must live under /data/rns, so make sure the tree exists in the image
# too and the first boot does not depend on S10mounts winning a race.
mkdir -p "$TARGET_DIR/data/rns"
