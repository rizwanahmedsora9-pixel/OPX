#!/bin/sh
_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_DATA=${RNS_DATA:-/data/rns}
if [ -z "${BB:-}" ]; then BB=/bin/busybox; [ -x "$BB" ] || BB=busybox; fi
export BB
. "$RNS_HOME/bin/store.sh"
store_init
_ip=$(printf '%s' "${1:-}" | "$BB" tr -cd '0-9a-fA-F.:')
[ -n "$_ip" ] || { printf 'free\n'; exit 0; }
_mac=$(mac_for_ip "$_ip" 2>/dev/null) || _mac=""
[ -n "$_mac" ] || { printf 'free\n'; exit 0; }
_row=$(voucher_for_mac "$_mac" 2>/dev/null) || _row=""
if [ -n "$_row" ]; then printf 'bound|%s\n' "$_mac"; else printf 'free\n'; fi
exit 0
