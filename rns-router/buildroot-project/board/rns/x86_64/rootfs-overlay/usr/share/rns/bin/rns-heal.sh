#!/bin/sh
_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_DATA=${RNS_DATA:-/data/rns}
if [ -z "${BB:-}" ]; then BB=/bin/busybox; [ -x "$BB" ] || BB=busybox; fi
export BB
. "$RNS_HOME/bin/net.sh"
store_init
_mac=$(printf '%s' "${1:-}" | "$BB" tr -cd '0-9a-f:')
_ip=$(printf '%s' "${2:-}" | "$BB" tr -cd '0-9.')
[ -n "$_mac" ] || exit 1
client_touch "$_mac" "$_ip" "" || true
with_lock voucher_set_ip "$_mac" "$_ip" >/dev/null 2>&1 || true
gate_heal
