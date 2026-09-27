#!/bin/sh
set -e
TARGET_DIR="$1"
chmod 755 "$TARGET_DIR"/etc/init.d/S* 2>/dev/null || true
chmod 755 "$TARGET_DIR"/usr/share/rns/bin/*.sh 2>/dev/null || true

# Buildroot's dropbear package installs /etc/dropbear as a *symlink* to
# /var/run/dropbear (ln -snf in dropbear.mk) because the host keys are
# generated per boot on the tmpfs. `mkdir -p` through a symlink fails with
# "File exists", which used to kill target-finalize on the very last build
# step. Leave the symlink alone; only manage a real directory.
if [ ! -L "$TARGET_DIR/etc/dropbear" ]; then
  mkdir -p "$TARGET_DIR/etc/dropbear"
  chmod 700 "$TARGET_DIR/etc/dropbear"
fi

# /etc is a read-only squashfs at runtime. Anything a boot script needs to
# write must live under /data/rns, so make sure the tree exists in the image
# too and the first boot does not depend on S10mounts winning a race.
mkdir -p "$TARGET_DIR/data/rns"
