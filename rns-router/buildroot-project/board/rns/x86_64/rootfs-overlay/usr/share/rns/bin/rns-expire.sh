#!/bin/sh
_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_DATA=${RNS_DATA:-/data/rns}
export RNS_LAB=${RNS_LAB:-0}
if [ -z "${BB:-}" ]; then BB=/bin/busybox; [ -x "$BB" ] || BB=busybox; fi
export BB
. "$RNS_HOME/bin/net.sh"
store_init
_gone=$(expire_enforce)
[ -n "$_gone" ] && printf '%s\n' "$_gone"
exit 0
