#!/bin/sh
_here=${0%/*}
RNS_HOME=${RNS_HOME:-${_here%/*}}
if [ -z "${BB:-}" ]; then BB=/bin/busybox; [ -x "$BB" ] || BB=busybox; fi
PORT=8080; LAN=br0
ipt() { command -v iptables >/dev/null 2>&1 || return 1; iptables "$@"; }

ipt -N RNS_FWD 2>/dev/null || true
ipt -t nat -N RNS_PRE 2>/dev/null || true
ipt -N RNS_IN 2>/dev/null || true
ipt -C FORWARD -j RNS_FWD 2>/dev/null || ipt -I FORWARD 1 -j RNS_FWD
ipt -t nat -C PREROUTING -j RNS_PRE 2>/dev/null || ipt -t nat -I PREROUTING 1 -j RNS_PRE
ipt -C INPUT -j RNS_IN 2>/dev/null || ipt -I INPUT 1 -j RNS_IN

ipt -C RNS_IN -i "$LAN" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
  || ipt -A RNS_IN -i "$LAN" -p tcp --dport "$PORT" -j ACCEPT

ipt -C RNS_FWD -i "$LAN" -p udp --dport 53 -j RETURN 2>/dev/null \
  || ipt -A RNS_FWD -i "$LAN" -p udp --dport 53 -j RETURN
ipt -C RNS_FWD -i "$LAN" -p tcp --dport 53 -j RETURN 2>/dev/null \
  || ipt -A RNS_FWD -i "$LAN" -p tcp --dport 53 -j RETURN

ipt -t nat -C RNS_PRE -i "$LAN" -p tcp --dport 80 -j REDIRECT --to-ports "$PORT" 2>/dev/null \
  || ipt -t nat -A RNS_PRE -i "$LAN" -p tcp --dport 80 -j REDIRECT --to-ports "$PORT"

ipt -C RNS_FWD -i "$LAN" -p tcp --dport 443 -j REJECT --reject-with tcp-reset 2>/dev/null \
  || ipt -A RNS_FWD -i "$LAN" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
ipt -C RNS_FWD -i "$LAN" -j DROP 2>/dev/null \
  || ipt -A RNS_FWD -i "$LAN" -j DROP

exit 0
