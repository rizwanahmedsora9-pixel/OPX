#!/bin/sh
_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_DATA=${RNS_DATA:-/data/rns}
if [ -z "$BB" ]; then BB=/bin/busybox; [ -x "$BB" ] || BB=busybox; fi
export BB
. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"
store_init
cmd=${1:-status}; shift 2>/dev/null || true

case "$cmd" in
  status)
    echo "shop $(cfg_get SHOP "RNS Internet")"
    echo "ssid $(cfg_get SSID RNS) channel $(cfg_get CHANNEL 6)"
    echo "counts $(overview_json)"
    [ -f "$RNS_DATA/PAUSE" ] && echo "gate PAUSED" || echo "gate armed"
    ;;
  packages)
    if [ ! -s "$PFILE" ]; then echo "no packages yet"
    else "$BB" awk -F'|' '$7 != "disabled" {printf "%-14s %-18s %ss %s/%s\n",$1,$2,$3,$4,$5}' "$PFILE"; fi
    ;;
  mint) with_lock voucher_mint "$1" "${2:-1}" ""; echo ;;
  expire) expire_enforce ;;
  kick) with_lock client_set_state "$(sanitize_mac "$1")" kicked && client_disconnect "$(sanitize_mac "$1")"; echo "kicked" ;;
  ban) with_lock client_set_state "$(sanitize_mac "$1")" banned && client_disconnect "$(sanitize_mac "$1")"; echo "banned" ;;
  unban|unkick|allow) with_lock client_set_state "$(sanitize_mac "$1")" active && fw_rebuild; echo "allowed" ;;
  pause) printf '1\n' > "$RNS_DATA/PAUSE"; fw_clear; echo paused ;;
  resume) rm -f "$RNS_DATA/PAUSE"; fw_rebuild; echo armed ;;
  setpass) _set_pass admin "$1"; echo "password updated" ;;
  clients) clients_json ;;
  *) echo "usage: rns-ctl status|packages|mint <id> [n]|expire|kick <mac>|ban <mac>|unban <mac>|pause|resume|setpass <pw>|clients"; exit 1 ;;
esac
