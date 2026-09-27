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
    if online_pay_on; then
      echo "online pay ON (auto-verify $(pay_autoverify_on && echo on || echo off))"
      echo "  jazzcash  $(cfg_get JAZZCASH_NUMBER '') $(cfg_get JAZZCASH_NAME '')"
      echo "  easypaisa $(cfg_get EASYPAISA_NUMBER '') $(cfg_get EASYPAISA_NAME '')"
    else
      echo "online pay OFF (no wallet number configured)"
    fi
    ;;
  packages)
    if [ ! -s "$PFILE" ]; then echo "no packages yet"
    else "$BB" awk -F'|' '$7 != "disabled" {printf "%-14s %-18s %ss %s/%s\n",$1,$2,$3,$4,$5}' "$PFILE"; fi
    ;;
  online-packages)
    if [ ! -s "$OPKGFILE" ]; then echo "no online packages yet"
    else "$BB" awk -F'|' '$7 != "disabled" {printf "%-14s %-18s %ss %s/%s Rs %s\n",$1,$2,$3,$4,$5,$6}' "$OPKGFILE"; fi
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
  payments) payments_json ;;
  sales)
    _from=${1:-}; _to=${2:-}
    [ -n "$_from" ] || _from=$(ymd_shift "$(today_ymd)" -6)
    [ -n "$_to" ] || _to=$(today_ymd)
    _fs=$(ymd_to_epoch "$_from") || _fs=$(ymd_to_epoch "$(today_ymd)")
    _ts=$(ymd_to_epoch "$_to" end) || _ts=$((_fs + 7 * 86400))
    sales_json "$_fs" "$_ts"; echo
    ;;
  salescsv)
    _from=${1:-}; _to=${2:-}
    [ -n "$_from" ] || _from=$(ymd_shift "$(today_ymd)" -6)
    [ -n "$_to" ] || _to=$(today_ymd)
    _fs=$(ymd_to_epoch "$_from") || _fs=$(ymd_to_epoch "$(today_ymd)")
    _ts=$(ymd_to_epoch "$_to" end) || _ts=$((_fs + 7 * 86400))
    sales_csv "$_fs" "$_ts"
    ;;
  pay-on)
    cfg_set ONLINE_PAY 1
    if [ -n "$1" ]; then cfg_set JAZZCASH_NUMBER "$(sanitize_wallet "$1")"; fi
    if [ -n "$2" ]; then cfg_set EASYPAISA_NUMBER "$(sanitize_wallet "$2")"; fi
    hostapd_apply >/dev/null 2>&1 || true
    echo "online payments enabled"
    ;;
  pay-off) cfg_set ONLINE_PAY 0; echo "online payments disabled" ;;
  autoverify)
    case "${1:-}" in
      on|1)  cfg_set PAY_AUTO_VERIFY 1; echo "auto-verify on" ;;
      off|0) cfg_set PAY_AUTO_VERIFY 0; echo "auto-verify off" ;;
      *) echo "auto-verify is $(pay_autoverify_on && echo on || echo off)" ;;
    esac
    ;;
  pay-confirm)
    _r=$(with_lock pay_confirm "$1"); echo "$_r"
    ;;
  pay-reject)
    _r=$(with_lock pay_reject "$1" "${2:-}"); echo "$_r"
    ;;
  backup) with_lock backup_create; echo ;;
  ap-reload) hostapd_apply && echo "hostapd reloaded" || echo "no wlan interface or hostapd not running" ;;
  ssh)
    case "${2:-status}" in
      on)
        ipt -C RNS_IN -i br0 -p tcp --dport 22 -j DROP 2>/dev/null \
          && ipt -D RNS_IN -i br0 -p tcp --dport 22 -j DROP
        ipt -C RNS_IN -i br0 -p tcp --dport 22 -j ACCEPT 2>/dev/null \
          || ipt -I RNS_IN 1 -i br0 -p tcp --dport 22 -j ACCEPT
        echo "ssh open on LAN — WARNING: the image ships with an empty root password"
        ;;
      off)
        ipt -C RNS_IN -i br0 -p tcp --dport 22 -j ACCEPT 2>/dev/null \
          && ipt -D RNS_IN -i br0 -p tcp --dport 22 -j ACCEPT
        ipt -C RNS_IN -i br0 -p tcp --dport 22 -j DROP 2>/dev/null \
          || ipt -A RNS_IN -i br0 -p tcp --dport 22 -j DROP
        echo "ssh closed"
        ;;
      *)
        if ipt -C RNS_IN -i br0 -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
          echo "ssh open (LAN only)"
        else
          echo "ssh closed"
        fi
        ;;
    esac
    ;;
  *) echo "usage: rns-ctl status|packages|online-packages|mint <id> [n]|expire|sales [from to]|salescsv [from to]|kick <mac>|ban <mac>|unban <mac>|pause|resume|setpass <pw>|clients|payments|pay-confirm <id>|pay-reject <id> [note]|pay-on [jazzcash] [easypaisa]|pay-off|autoverify on|off|backup|ap-reload|ssh on|off|status"; exit 1 ;;
esac
