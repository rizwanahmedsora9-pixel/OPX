#!/bin/sh
# rns-install.sh — install OPX to a local disk (BIOS/legacy boot, syslinux).
#
# What it does, after a big warning and an explicit 'yes':
#   1. DESTROYS everything on the chosen disk and creates an MBR layout:
#        p1  ext4, active   — installed root filesystem (with /boot + kernel)
#        p2  ext4, label    — RNS-DATA: vouchers, config, logs (survives boots)
#   2. Copies the live root filesystem onto p1, the kernel next to /boot,
#      and carries the live /data/rns state (vouchers, config) over to p2.
#   3. Installs the bootloader: extlinux on p1 (boot sector + /boot files)
#      and mbr.bin in the disk's master boot record.
#
# Afterwards the machine boots OPX straight from the hard drive, without
# the USB stick, and /data is persistent. Note: this only covers BIOS/
# legacy boot (the same limitation the live image has — no UEFI support).
#
# Everything the installer touches is overridable for the test suite:
#   RNS_INSTALL_SYS      (default /sys)
#   RNS_INSTALL_DEV      (default /dev)
#   RNS_INSTALL_PROC     (default /proc)
#   RNS_INSTALL_ROOT     (default /)      — the live root to copy from
#   RNS_INSTALL_MNT      (default /mnt)   — target root mountpoint
#   RNS_INSTALL_MNTDATA  (default /mntdata) — target data mountpoint
#   RNS_INSTALL_CDROM    (default /cdrom) — boot-medium (ISO) mountpoint
#   RNS_INSTALL_ANSWERS  file, one answer per prompt, for non-tty runs
#
set -u

SYS=${RNS_INSTALL_SYS:-/sys}
DEV=${RNS_INSTALL_DEV:-/dev}
PROC=${RNS_INSTALL_PROC:-/proc}
ROOTFS=${RNS_INSTALL_ROOT:-/}
MNT=${RNS_INSTALL_MNT:-/mnt}
MNTDATA=${RNS_INSTALL_MNTDATA:-/mntdata}
CDROM=${RNS_INSTALL_CDROM:-/cdrom}
ANSWERS=${RNS_INSTALL_ANSWERS:-}

say() { printf '%s\n' "$*"; }
die() { say; say "install: ERROR: $*"; say; exit 1; }

line() { say "----------------------------------------------------------------"; }

# ask <question> [default] — prompt the user, or read the next line of the
# answers file when running without a tty. Result in $LAST.
_AI=0
LAST=""
ask() {
	_q="$1"; _d="${2-}"
	if [ -n "$ANSWERS" ]; then
		_AI=$((_AI + 1))
		_a=$(sed -n "${_AI}p" "$ANSWERS" 2>/dev/null)
		[ -n "$_a" ] || _a="$_d"
	else
		printf '%s' "$_q"
		IFS= read -r _a || _a=""
		[ -n "$_a" ] || _a="$_d"
	fi
	say "  -> $_a"
	LAST="$_a"
}

# ---------------------------------------------------------------- disk info
# whole disks only: /sys/block/<disk> is a directory, partitions are files
list_disks() {
	for _d in "$SYS"/block/*; do
		[ -d "$_d" ] || continue
		_n=${_d##*/}
		case $_n in loop*|ram*|fd*|sr*|dm-*|md*|zram*) continue ;; esac
		_s=$(cat "$_d/size" 2>/dev/null)
		case $_s in ''|*[!0-9]*) continue ;; esac
		_m=$(cat "$_d/device/model" 2>/dev/null)
		printf '%s\t%s\t%s\n' "$_n" "$(( _s * 512 / 1048576 ))" "$_m"
	done
}

dev_id() { cat "$SYS/class/block/$1/dev" 2>/dev/null; }

# whole-disk name that contains the given block device (partitions map to
# their parent disk; disks map to themselves)
parent_disk() {
	case $1 in
	nvme*) printf '%s\n' "${1%p*}" ;;
	*)     printf '%s\n' "${1%[0-9]*}" ;;
	esac
}

# devices (and their parent disks) currently providing the boot ISO
boot_medium_ids() {
	awk '$3 == "iso9660" { print $1 }' "$PROC/mounts" 2>/dev/null | while read -r _m; do
		_n=${_m##*/}
		for _c in "$_n" "$(parent_disk "$_n")"; do
			[ -n "$_c" ] || continue
			_id=$(dev_id "$_c")
			[ -n "$_id" ] && printf '%s\n' "$_id"
		done
	done | sort -u
}

is_boot_medium() {
	_id=$(dev_id "$1")
	[ -n "$_id" ] || return 0	# unknown — treat as dangerous
	_bm=$(boot_medium_ids)
	printf '%s\n' "$_bm" | grep -qxF "$_id"
}

# is any part of this disk currently mounted?
disk_in_use() {
	awk '{ print $1 }' "$PROC/mounts" 2>/dev/null | grep -q "^$DEV/$1"
}

# ------------------------------------------------------------------ layout
TOTAL_SECT=0
ROOT_MB=0
F1=0; L1=0; F2=0; L2=0

calc_layout() {
	# $1 = total sectors
	TOTAL_SECT=$1
	[ "$TOTAL_SECT" -gt 0 ] || return 1
	_total_mb=$(( TOTAL_SECT / 2048 ))
	if [ "$_total_mb" -lt 512 ]; then
		return 1
	fi
	if [ "$_total_mb" -ge 6144 ]; then
		ROOT_MB=2048
	else
		ROOT_MB=$((_total_mb / 2))
	fi
	[ "$ROOT_MB" -lt 256 ] && ROOT_MB=256
	[ "$ROOT_MB" -gt $((_total_mb - 256)) ] && ROOT_MB=$((_total_mb - 256))
	[ "$ROOT_MB" -le 0 ] && return 1
	F1=2048
	L1=$(( F1 + ROOT_MB * 2048 - 1 ))
	F2=$(( L1 + 1 ))
	L2=$(( TOTAL_SECT - 1 ))
	[ "$L2" -gt "$F2" ] || return 1
	return 0
}

wait_partitions() {
	# make the kernel re-read the partition table, then wait for the
	# partition entries (and, on a real system, the device nodes)
	_i=0
	while [ "$_i" -lt 20 ]; do
		[ -e "$SYS/block/${disk}1" ] && [ -e "$SYS/block/${disk}2" ] && break
		command -v blockdev >/dev/null 2>&1 && blockdev --rereptbl "$DEV/$disk" 2>/dev/null
		[ -f "$SYS/block/$disk/device/rescan" ] && echo 1 > "$SYS/block/$disk/device/rescan" 2>/dev/null
		_i=$((_i + 1))
		sleep 1
	done
	[ -e "$SYS/block/${disk}1" ] && [ -e "$SYS/block/${disk}2" ] ||
		die "the kernel did not expose the new partitions on $DEV/$disk"
	if [ "$SYS" = /sys ] && [ "$DEV" = /dev ]; then
		# devtmpfs creates the device nodes slightly after sysfs
		_i=0
		while [ "$_i" -lt 10 ]; do
			[ -b "$DEV/${disk}1" ] && [ -b "$DEV/${disk}2" ] && break
			_i=$((_i + 1))
			sleep 1
		done
	fi
}

mount_iso() {
	# find and mount the boot medium (the ISO we booted from), so the
	# installer can read bzImage and install/mbr.bin from it
	mkdir -p "$CDROM"
	grep -q " $CDROM " "$PROC/mounts" 2>/dev/null && return 0
	_src=$(awk '$3 == "iso9660" { print $1; exit }' "$PROC/mounts" 2>/dev/null)
	if [ -z "$_src" ]; then
		for _d in "$SYS"/class/block/*; do
			_n=${_d##*/}
			[ -e "$DEV/$_n" ] || continue
			case $_n in sr*|loop*|ram*|md*|dm-*|zram*) continue ;; esac
			if blkid "$DEV/$_n" 2>/dev/null | grep -q 'iso9660'; then
				_src="$DEV/$_n"
				break
			fi
		done
	fi
	[ -n "$_src" ] || return 1
	mount -t iso9660 -o ro "$_src" "$CDROM" 2>/dev/null || return 1
	return 0
}

# ------------------------------------------------------------------- main
say "OPX Router OS - install to disk"
line
say "This DESTROYS everything on the disk you choose and installs OPX as"
say "the only operating system on that disk (BIOS/legacy boot)."
say
if [ -t 0 ] && [ -z "$ANSWERS" ]; then
	: # interactive tty: fine
else
	[ -n "$ANSWERS" ] || die "no tty and no answer file — refusing to run"
fi

say "Disks:"
list_disks | while IFS='	' read -r _n _mb _m; do
	[ -n "$_n" ] || continue
	[ "$_mb" -lt 512 ] && _m="too small ($_mb MB)"
	[ -n "$_m" ] && say "  $_n   $_mb MB   ($_m)" || say "  $_n   $_mb MB"
done
say

ask "Disk to install to (name, e.g. sda) " ""
disk=$LAST
disk=${disk#/dev/}
case $disk in
''|*[!a-z0-9]) die "no disk chosen" ;;
esac
# whole disks are directories in /sys/block, partitions are (symlink) files
[ -d "$SYS/block/$disk" ] || die "$disk is not a whole disk"
if is_boot_medium "$disk"; then
	die "$disk is the disk this system booted from — it cannot be wiped"
fi
if disk_in_use "$disk"; then
	die "$disk has a mounted filesystem — unmount it first"
fi

_total_sect=$(cat "$SYS/block/$disk/size")
if ! calc_layout "$_total_sect"; then
	die "$disk is too small to install OPX (need at least 512 MB)"
fi
say
say "Planned layout for /dev/$disk ($((_total_sect / 2048)) MB total):"
say "  p1  ext4  $ROOT_MB MB  root filesystem, active, syslinux"
say "  p2  ext4  $(( (_total_sect - L1 - 1) / 2048 )) MB  RNS-DATA (persistent data)"
say
ask "Type 'yes' to wipe /dev/$disk and install: " ""
[ "$LAST" = yes ] || die "aborted by user"

say
say "[1/6] wiping and partitioning /dev/$disk"
_fd=$(printf 'o\nn\np\n1\n%s\n%s\nn\np\n2\n%s\n%s\na\n1\nw\n' \
	"$F1" "$L1" "$F2" "$L2" | fdisk "$DEV/$disk" 2>&1) ||
	die "fdisk failed: $_fd"
wait_partitions
say "[2/6] formatting"
mke2fs -F -q "$DEV/${disk}1" || die "mke2fs on $DEV/${disk}1 failed"
mke2fs -F -q -L RNS-DATA "$DEV/${disk}2" || die "mke2fs on $DEV/${disk}2 failed"
say "[3/6] mounting and copying the system"
mkdir -p "$MNT" "$MNTDATA"
mount -t ext4 -o noatime "$DEV/${disk}1" "$MNT" || die "cannot mount $DEV/${disk}1"
mount -t ext4 -o noatime "$DEV/${disk}2" "$MNTDATA" || die "cannot mount $DEV/${disk}2"
# stage the copy through a temporary archive: a piped tar would hide a
# failure of the reader if the writer failed midway
_tarc=/tmp/.rns-install-rootfs.tar
tar -C "$ROOTFS" -cf "$_tarc" \
	--exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
	--exclude=./mnt --exclude=./mntdata --exclude=./cdrom \
	--exclude=./tmp --exclude=./data \
	. || die "copying the root filesystem failed"
tar -C "$MNT" -xf "$_tarc" || die "copying the root filesystem failed"
rm -f "$_tarc"
if [ -d "$ROOTFS/data/rns" ] && [ -n "$(ls -A "$ROOTFS/data/rns" 2>/dev/null)" ]; then
	mkdir -p "$MNTDATA/rns"
	cp -a "$ROOTFS/data/rns/." "$MNTDATA/rns/" || die "carrying over /data/rns failed"
	say "      carried the live /data/rns state over to RNS-DATA"
fi
say "[4/6] kernel and boot configuration"
mount_iso || die "cannot find the boot medium (the ISO we booted from)"
cp "$CDROM/bzImage" "$MNT/bzImage" || die "bzImage not found on the boot medium"
mkdir -p "$MNT/boot"
cat > "$MNT/boot/extlinux.conf" <<CFG
DEFAULT rns
PROMPT 0
TIMEOUT 50
LABEL rns
  KERNEL /bzImage
  APPEND root=/dev/${disk}1 rootfstype=ext4 console=tty0 console=ttyS0,115200 quiet
CFG
say "[5/6] installing the bootloader (extlinux + MBR)"
extlinux -i "$MNT/boot" || die "extlinux failed"
[ -f "$CDROM/install/mbr.bin" ] || die "install/mbr.bin missing from the boot medium"
dd if="$CDROM/install/mbr.bin" of="$DEV/$disk" bs=512 || die "writing the MBR failed"
say "[6/6] finishing"
sync
umount "$MNTDATA" 2>/dev/null
umount "$MNT" 2>/dev/null

say
line
say "Installation complete."
say "  * OPX now boots from /dev/$disk. Remove the USB stick (or change the"
say "    BIOS boot order) and reboot."
say "  * Vouchers, config and logs live on the RNS-DATA partition and"
say "    survive reboots."
line
if [ "$SYS" = /sys ] && [ "$DEV" = /dev ]; then
	ask "Reboot now? " "n"
	case $LAST in
	y|Y|yes|YES) exec /sbin/reboot ;;
	esac
fi
exit 0
