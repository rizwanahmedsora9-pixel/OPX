#!/bin/sh
_here=${0%/*}
[ -z "${RNS_HOME:-}" ] && RNS_HOME=${_here%/*}
export RNS_HOME
export RNS_DATA=${RNS_DATA:-/data/rns}
export RNS_LAB=${RNS_LAB:-0}
if [ -z "${BB:-}" ]; then BB=/bin/busybox; [ -x "$BB" ] || BB=busybox; fi
export BB
export RNS_BB=$BB

STATE="${RNS_DATA:-/data/rns}"
mkdir -p "$STATE" 2>/dev/null || true
[ -w "$STATE" ] || { STATE=/tmp; mkdir -p "$STATE" 2>/dev/null || true; }
PORT=${RNS_PORT:-8080}
LOG=/tmp/rns_hotspot.log

pid_alive() {
  [ -f "$STATE/httpd.pid" ] || return 1
  _pid=$(cat "$STATE/httpd.pid" 2>/dev/null)
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_pid" 2>/dev/null
}

stop_listener() {
  _old=$(cat "$STATE/httpd.pid" 2>/dev/null)
  [ -n "$_old" ] && kill "$_old" 2>/dev/null || true
  sleep 1
  [ -n "$_old" ] && kill -9 "$_old" 2>/dev/null || true
  rm -f "$STATE/httpd.pid" 2>/dev/null || true
}

probe_pages() {
  _out=""
  if command -v curl >/dev/null 2>&1; then
    _out=$(curl -sS -m 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null)
  fi
  if [ -z "$_out" ] && "$BB" wget --help >/dev/null 2>&1; then
    _out=$("$BB" wget -q -T 2 -O - "http://127.0.0.1:${PORT}/health" 2>/dev/null)
  fi
  case "$_out" in *'"pages":true'*) return 0 ;; esac
  return 1
}

wait_for_pages() {
  _i=0
  while [ "$_i" -lt 5 ]; do
    probe_pages && return 0
    _i=$((_i + 1)); sleep 1
  done
  return 1
}

write_wrap() {
  _wrap="$STATE/front-wrap.sh"
  cat > "$_wrap" <<WEOF
#!/bin/sh
export RNS_HOME='$RNS_HOME'
export RNS_DATA='${RNS_DATA:-/data/rns}'
export RNS_LAB='${RNS_LAB}'
export BB='$BB'
export RNS_BB='$BB'
export RNS_PORT='$PORT'
exec '$BB' sh '$RNS_HOME/bin/rns-front.sh'
WEOF
  chmod 755 "$_wrap" 2>/dev/null || true
}

# Preferred listener. socat forks one child per connection and, unlike
# busybox nc -e, hands the child the peer address in $SOCAT_PEERADDR — which
# is the only way the portal can tell one phone from another.
start_socat() {
  command -v socat >/dev/null 2>&1 || return 1
  write_wrap
  socat "TCP-LISTEN:$PORT,reuseaddr,fork,bind=0.0.0.0" \
        "EXEC:$STATE/front-wrap.sh" >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$STATE/httpd.pid"
  printf 'front\n' > "$STATE/httpd.mode"
  printf 'socat\n' > "$STATE/httpd.engine"
}

start_nc() {
  "$BB" nc --help 2>&1 | "$BB" grep -q -- '-e' || return 1
  write_wrap
  "$BB" nc -lk -p "$PORT" -e "$STATE/front-wrap.sh" >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$STATE/httpd.pid"
  printf 'front\n' > "$STATE/httpd.mode"
  printf 'nc-e\n' > "$STATE/httpd.engine"
}

start_nc_loop() {
  "$BB" nc --help 2>&1 | "$BB" grep -q -- '-e' || return 1
  write_wrap
  cat > "$STATE/front-loop.sh" <<LEOF
#!/bin/sh
while :; do
  '$BB' nc -l -p '$PORT' -e '$STATE/front-wrap.sh'
  '$BB' usleep 10000 2>/dev/null || true
done
LEOF
  chmod +x "$STATE/front-loop.sh"
  "$BB" sh "$STATE/front-loop.sh" >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$STATE/httpd.pid"
  printf 'front\n' > "$STATE/httpd.mode"
  printf 'nc-loop\n' > "$STATE/httpd.engine"
}

if pid_alive && probe_pages; then exit 0; fi
pid_alive && stop_listener

if start_socat && wait_for_pages; then exit 0; fi
stop_listener

if start_nc && wait_for_pages; then exit 0; fi
stop_listener

if start_nc_loop && wait_for_pages; then exit 0; fi
stop_listener

printf '%s pages: no listener could bind :%s (need socat, or busybox nc with -e)\n' \
  "$("$BB" date +%s 2>/dev/null)" "$PORT" >> "$LOG" 2>/dev/null
"$BB" wget --help >/dev/null 2>&1 && "$BB" wget -q -T 2 -O /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null || true
exit 1
