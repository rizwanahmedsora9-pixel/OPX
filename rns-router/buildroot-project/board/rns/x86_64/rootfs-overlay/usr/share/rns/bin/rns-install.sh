#!/bin/sh
# Interactive whole-disk installer for the RNS OS live image.
#
# The ISO is built as a BIOS isohybrid image. Installation copies that image
# to the selected disk, then uses the unoccupied space for an ext4 partition
# labelled RNS-DATA. The normal boot path keeps the squashfs system read-only
# and mounts that second partition at /data.

partition_path() {
  _disk=$1
  _number=$2
  case "${_disk##*/}" in
    *[0-9]) printf '%sp%s\n' "$_disk" "$_number" ;;
    *)      printf '%s%s\n'  "$_disk" "$_number" ;;
  esac
}

# A small, side-effect-free entry point used by the regression suite and handy
# when checking support for a new disk naming scheme.
if [ "${1:-}" = "--partition-path" ]; then
  [ "$#" -eq 3 ] || exit 2
  partition_path "$2" "$3"
  exit 0
fi

say() { printf '%s\n' "$*"; }

block_sectors() {
  blockdev --getsz "$1" 2>/dev/null && return 0
  _name=${1##*/}
  cat "/sys/class/block/$_name/size" 2>/dev/null
}

human_size() {
  awk -v sectors="$1" 'BEGIN {
    bytes = sectors * 512
    if (bytes >= 1099511627776) printf "%.1f TiB", bytes / 1099511627776
    else if (bytes >= 1073741824) printf "%.1f GiB", bytes / 1073741824
    else printf "%.0f MiB", bytes / 1048576
  }'
}

is_target_disk() {
  _dev=$1
  case "$_dev" in /dev/*) ;; *) return 1 ;; esac
  _name=${_dev#/dev/}
  # Only whole, directly addressable disks are offered. Device-mapper, RAID,
  # optical, RAM and loop devices need installation-specific handling and are
  # deliberately excluded from this destructive whole-disk installer.
  case "$_name" in
    */*|sr*|scd*|cdrom*|loop*|ram*|zram*|fd*|dm-*|md*) return 1 ;;
  esac
  [ -b "$_dev" ] || return 1
  [ -e "/sys/class/block/$_name" ] || return 1
  [ ! -e "/sys/class/block/$_name/partition" ] || return 1
  _sectors=$(block_sectors "$_dev")
  [ -n "$_sectors" ] && [ "$_sectors" -gt 0 ] 2>/dev/null
}

find_source() {
  if [ -n "${RNS_INSTALL_SOURCE:-}" ]; then
    printf '%s\n' "$RNS_INSTALL_SOURCE"
    return 0
  fi

  for _source in /dev/sr* /dev/scd* /dev/cdrom; do
    [ -b "$_source" ] || continue
    _label=$(blkid -s LABEL -o value "$_source" 2>/dev/null | head -n 1)
    if [ "$_label" = "RNS_ROUTER" ]; then
      printf '%s\n' "$_source"
      return 0
    fi
  done
  return 1
}

show_targets() {
  TARGET_COUNT=0
  ONLY_TARGET=""
  for _sysdev in /sys/class/block/*; do
    [ -e "$_sysdev" ] || continue
    _name=${_sysdev##*/}
    _dev="/dev/$_name"
    is_target_disk "$_dev" || continue
    [ "$_dev" = "$SOURCE" ] && continue
    _sectors=$(block_sectors "$_dev")
    _model=$(cat "$_sysdev/device/model" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')
    [ -n "$_model" ] || _model="disk"
    printf '  %-14s %9s  %s\n' "$_dev" "$(human_size "$_sectors")" "$_model"
    TARGET_COUNT=$((TARGET_COUNT + 1))
    ONLY_TARGET=$_dev
  done
}

install_failed() {
  say ""
  say "INSTALLATION STOPPED: $*"
  say "The router was not marked as successfully installed."
  say "Press Enter to continue into Live mode, or power off the machine."
  read -r _unused
  return 1
}

open_console() {
  _console=/dev/tty1
  case " $(cat /proc/cmdline 2>/dev/null) " in
    *" rns.console=serial "*) _console=/dev/ttyS0 ;;
  esac
  if [ -c "$_console" ]; then
    exec <"$_console" >"$_console" 2>&1
  fi
}

main() {
  open_console
  printf '\033[2J\033[H'
  say "============================================================"
  say "                 RNS OS Installer"
  say "============================================================"
  say ""
  say "This installer uses an ENTIRE disk. Every existing partition and"
  say "all data on the disk you choose will be permanently erased."
  say ""

  SOURCE=$(find_source) || {
    install_failed "the RNS OS installation CD could not be found."
    return $?
  }
  SOURCE_SECTORS=$(block_sectors "$SOURCE")
  if [ -z "$SOURCE_SECTORS" ] || [ "$SOURCE_SECTORS" -le 0 ] 2>/dev/null; then
    install_failed "the size of $SOURCE could not be read."
    return $?
  fi

  say "Installation media: $SOURCE ($(human_size "$SOURCE_SECTORS"))"
  say ""
  say "Available destination disks:"
  show_targets
  if [ "$TARGET_COUNT" -eq 0 ]; then
    install_failed "no writable hard disk was detected. Add a virtual disk and try again."
    return $?
  fi

  say ""
  if [ "$TARGET_COUNT" -eq 1 ]; then
    printf 'Destination disk [%s]: ' "$ONLY_TARGET"
    read -r TARGET
    [ -n "$TARGET" ] || TARGET=$ONLY_TARGET
  else
    printf 'Enter the destination device (for example /dev/sda): '
    read -r TARGET
  fi
  case "$TARGET" in /dev/*) ;; *) TARGET="/dev/$TARGET" ;; esac

  if ! is_target_disk "$TARGET" || [ "$TARGET" = "$SOURCE" ]; then
    install_failed "$TARGET is not one of the available destination disks."
    return $?
  fi

  TARGET_SECTORS=$(block_sectors "$TARGET")
  # Put partition 2 on a 1 MiB boundary after the copied ISO. Leave at least
  # 128 MiB for persistent settings, vouchers, logs and backups.
  DATA_START=$(( (SOURCE_SECTORS + 2047) / 2048 * 2048 ))
  MIN_DATA_SECTORS=262144
  if [ "$TARGET_SECTORS" -le $((DATA_START + MIN_DATA_SECTORS)) ]; then
    install_failed "$TARGET is too small; at least 128 MiB beyond the live image is required."
    return $?
  fi

  say ""
  say "WARNING: $TARGET ($(human_size "$TARGET_SECTORS")) WILL BE ERASED."
  printf 'To confirm, type exactly: ERASE %s\n> ' "$TARGET"
  read -r CONFIRM
  if [ "$CONFIRM" != "ERASE $TARGET" ]; then
    say ""
    say "Installation cancelled. Continuing in Live mode."
    return 0
  fi

  say ""
  say "[1/4] Clearing old disk signatures..."
  if ! wipefs -a "$TARGET" >/dev/null 2>&1; then
    install_failed "could not clear old signatures on $TARGET."
    return $?
  fi

  say "[2/4] Copying the bootable RNS OS image..."
  say "      This can take a few minutes."
  if ! dd if="$SOURCE" of="$TARGET" bs=1M; then
    install_failed "copying the system image to $TARGET failed."
    return $?
  fi
  sync

  say "[3/4] Creating the persistent data partition..."
  if ! printf '%s,,83\n' "$DATA_START" | sfdisk --append --force "$TARGET" >/dev/null 2>&1; then
    install_failed "the persistent partition could not be added to $TARGET."
    return $?
  fi
  blockdev --rereadpt "$TARGET" >/dev/null 2>&1 || true
  mdev -s >/dev/null 2>&1 || true

  DATA_PART=$(partition_path "$TARGET" 2)
  _wait=0
  while [ ! -b "$DATA_PART" ] && [ "$_wait" -lt 10 ]; do
    sleep 1
    _wait=$((_wait + 1))
    mdev -s >/dev/null 2>&1 || true
  done
  if [ ! -b "$DATA_PART" ]; then
    install_failed "$DATA_PART did not appear after partitioning."
    return $?
  fi

  say "[4/4] Formatting $DATA_PART for persistent router data..."
  if command -v mkfs.ext4 >/dev/null 2>&1; then
    mkfs.ext4 -F -L RNS-DATA "$DATA_PART" >/dev/null 2>&1 || {
      install_failed "formatting $DATA_PART as ext4 failed."
      return $?
    }
  elif command -v mke2fs >/dev/null 2>&1; then
    mke2fs -F -t ext4 -L RNS-DATA "$DATA_PART" >/dev/null 2>&1 || {
      install_failed "formatting $DATA_PART as ext4 failed."
      return $?
    }
  else
    install_failed "mkfs.ext4 is missing from the installer image."
    return $?
  fi
  sync

  say ""
  say "============================================================"
  say " Installation complete. RNS OS is installed on $TARGET."
  say " Router settings and vouchers will persist on $DATA_PART."
  say "============================================================"
  say ""

  if command -v eject >/dev/null 2>&1 && eject "$SOURCE" >/dev/null 2>&1; then
    say "The installation CD was ejected. Press Enter to reboot from the disk."
    read -r _unused
    reboot -f
  else
    say "Power off, remove the ISO from the virtual optical drive, then start"
    say "the machine again. Press Enter to power off now."
    read -r _unused
    poweroff -f
  fi

  # reboot/poweroff should not return. Do not accidentally continue rcS and
  # start router services after a completed destructive installation.
  while :; do sleep 3600; done
}

main "$@"
