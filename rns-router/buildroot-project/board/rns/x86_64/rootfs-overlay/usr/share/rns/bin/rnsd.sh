#!/bin/sh
_here=${0%/*}
[ -z "${RNS_HOME:-}" ] && RNS_HOME=${_here%/*}
export RNS_HOME
export RNS_DATA=${RNS_DATA:-/data/rns}
export RNS_LAB=${RNS_LAB:-0}
if [ -z "${BB:-}" ]; then BB=/bin/busybox; [ -x "$BB" ] || BB=busybox; fi
export BB
export RNS_BB=$BB

SUP_DIR=/data/rns
mkdir -p "$SUP_DIR" 2>/dev/null || true
SUP_PID="$SUP_DIR/rnsd.pid"
SUP_LOG=/tmp/rns_hotspot.log

if [ -f "$SUP_PID" ]; then
  _old=$(cat "$SUP_PID" 2>/dev/null)
  case "$_old" in
    ''|*[!0-9]*) ;;
    *) if [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null; then exit 0; fi ;;
  esac
fi
printf '%s\n' "$$" > "$SUP_PID" 2>/dev/null || true

"$BB" sh "$RNS_HOME/bin/rns-pages.sh" || true

SETSID=""
for _c in "$BB" setsid /usr/bin/setsid /bin/setsid; do
  if "$_c" setsid true >/dev/null 2>&1; then SETSID="$_c setsid"; break; fi
done

while true; do
  "$BB" sh "$RNS_HOME/bin/rns-pages.sh" || true
  "$BB" sh "$RNS_HOME/bin/rns-worker.sh" || true
  "$BB" sh "$RNS_HOME/bin/rns-gate-min.sh" || true
  sleep 15
done
