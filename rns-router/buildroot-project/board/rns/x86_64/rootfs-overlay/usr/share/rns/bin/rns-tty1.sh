#!/bin/sh
# tty1 wrapper (inittab starts this instead of a bare getty).
#
# When the system was booted from the "Install to disk" menu entry, the
# kernel command line carries the word 'install'; in that case run the
# installer first. Always fall through to the normal getty/login afterwards,
# so a failed (or manually aborted) install still leaves a usable console.
_d=$(dirname "$0")
_cmdline=${RNS_TTY1_CMDLINE:-/proc/cmdline}
_getty=${RNS_TTY1_GETTY:-/sbin/getty}
_tty=${RNS_TTY1_TTY:-tty1}
if grep -qw install "$_cmdline" 2>/dev/null; then
	"$_d/rns-install.sh" || true
fi
exec "$_getty" -L "$_tty" 0 vt100
