#!/bin/sh
# Isolated page shell — serves portal + admin. Does not source store/net.

_here=${0%/*}
[ -z "${RNS_HOME:-}" ] && RNS_HOME=${_here%/*}
export RNS_HOME
RNS_WWW="$RNS_HOME/www"
[ -z "${RNS_DATA:-}" ] && RNS_DATA=/data/rns
export RNS_DATA
export RNS_LAB=${RNS_LAB:-0}

if [ -z "${BB:-}" ]; then
  if [ -x /bin/busybox ]; then BB=/bin/busybox
  elif [ -x /usr/bin/busybox ]; then BB=/usr/bin/busybox
  else BB=busybox; fi
fi
export BB
export RNS_BB=$BB

# common.sh sources nothing and pulls in no network or storage code, so the
# front stays the isolated shell it is meant to be: store/net are still only
# reached through rns-http.sh.
if [ -f "$RNS_HOME/bin/common.sh" ]; then . "$RNS_HOME/bin/common.sh"; fi

SPOOL=/tmp
[ -w "$RNS_DATA" ] && SPOOL="$RNS_DATA"
PAGES_LOG=/tmp/rns_pages.log

send_headers() {
  printf 'HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\nCache-Control: no-store\r\nX-RNS-Front: 1\r\n\r\n' "$1" "$2" "$3"
}
send_bytes() {
  _len=$(printf '%s' "$3" | "$BB" wc -c | "$BB" tr -d ' ')
  send_headers "$1" "$2" "$_len"
  [ "${RNS_METHOD:-GET}" = "HEAD" ] || printf '%s' "$3"
}
send_file() {
  [ -s "$3" ] || return 1
  _len=$("$BB" wc -c < "$3" | "$BB" tr -d ' ')
  send_headers "$1" "$2" "$_len"
  [ "${RNS_METHOD:-GET}" = "HEAD" ] || cat "$3"
}
send_no_content() {
  printf 'HTTP/1.0 204 No Content\r\nConnection: close\r\n\r\n'
}

fallback_portal() {
  cat <<HTMLEOF
<!doctype html><html><head><meta charset="utf-8"><title>RNS</title></head>
<body style="font-family:sans-serif;background:#10283c;color:#123;padding:0">
<main style="max-width:420px;margin:8vh auto;background:#fff;border-radius:18px;padding:24px">
<h1>Welcome online.</h1><p>Enter the voucher from the counter.</p>
<form method="post" action="/api/redeem">
<input name="code" maxlength="16" placeholder="ABCD-1234" required style="padding:14px;font-size:22px;width:100%;box-sizing:border-box">
<button type="submit" style="margin-top:12px;padding:14px;width:100%">Connect</button>
</form></main></body></html>
HTMLEOF
}

send_portal() {
  if ! send_file "200 OK" "text/html; charset=utf-8" "$RNS_WWW/portal.html"; then
    _tmp="$SPOOL/rns-portal-fb.$$"
    fallback_portal > "$_tmp"
    send_file "200 OK" "text/html; charset=utf-8" "$_tmp" || send_bytes "200 OK" "text/html; charset=utf-8" "Welcome online."
    rm -f "$_tmp"
  fi
}
send_admin() {
  send_file "200 OK" "text/html; charset=utf-8" "$RNS_WWW/admin.html" || \
    send_bytes "200 OK" "text/html; charset=utf-8" "<!doctype html><title>Staff</title><h1>Staff login</h1>"
}

send_api_down() {
  case "${RNS_ACCEPT:-}" in
    *application/json*) send_bytes "200 OK" "application/json" '{"ok":false,"error":"Gateway functions unavailable.","pages":true}' ;;
    *) send_bytes "200 OK" "text/html; charset=utf-8" '<!doctype html><h1>Sign-in page up</h1><p>Voucher check not answering. Retry.</p>' ;;
  esac
}

read_request() {
  IFS= read -r RNS_REQ || return 1
  RNS_REQ=$(printf '%s' "$RNS_REQ" | "$BB" tr -d '\r')
  RNS_METHOD=$(printf '%s' "$RNS_REQ" | "$BB" awk '{print $1}')
  RNS_TARGET=$(printf '%s' "$RNS_REQ" | "$BB" awk '{print $2}')
  RNS_PATH=${RNS_TARGET%%\?*}
  RNS_QUERY=""
  case "$RNS_TARGET" in *\?*) RNS_QUERY=${RNS_TARGET#*\?} ;; esac
  case "$RNS_PATH" in /) ;; */) RNS_PATH=${RNS_PATH%/} ;; esac
  RNS_CL=0; RNS_COOKIE=""; RNS_ACCEPT=""; RNS_HOST=""
  while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | "$BB" tr -d '\r')
    [ -z "$_line" ] && break
    _lk=$(printf '%s' "$_line" | "$BB" cut -d: -f1 | "$BB" tr 'A-Z' 'a-z')
    _lv=$(printf '%s' "$_line" | "$BB" cut -d: -f2- | "$BB" sed 's/^ *//')
    case "$_lk" in
      content-length) RNS_CL=$_lv ;;
      cookie) RNS_COOKIE=$_lv ;;
      accept) RNS_ACCEPT=$_lv ;;
      host) RNS_HOST=$_lv ;;
    esac
  done
  case "$RNS_CL" in ''|*[!0-9]*) RNS_CL=0 ;; esac
  [ "$RNS_CL" -gt 8192 ] && RNS_CL=8192
  RNS_BODY=""
  [ "$RNS_CL" -gt 0 ] && RNS_BODY=$("$BB" dd bs=1 count="$RNS_CL" 2>/dev/null)
  [ -n "$RNS_METHOD" ] || return 1
  return 0
}

delegate_api() {
  _api="$RNS_HOME/bin/rns-http.sh"
  _out="$SPOOL/rns-api.$$"
  [ -f "$_api" ] || { send_api_down; return 0; }
  "$BB" sh -n "$_api" >/dev/null 2>&1 || { send_api_down; return 0; }
  export RNS_DELEGATED=1 RNS_METHOD RNS_PATH RNS_QUERY RNS_BODY RNS_COOKIE RNS_ACCEPT RNS_HOST RNS_CL
  export CLIENT_IP RNS_LAB RNS_DATA RNS_HOME BB RNS_BB
  "$BB" sh "$_api" > "$_out" 2>/dev/null
  if [ -s "$_out" ] && "$BB" grep -q '^HTTP/' "$_out"; then cat "$_out"
  else send_api_down; fi
  rm -f "$_out"
}

is_probe() {
  case "$1" in
    /generate_204|/gen_204|/generate204|/hotspot-detect.html|/library/test/success.html|/ncsi.txt|/connecttest.txt|/success.txt|/canonical.html|/check_network_status.txt|/connectivity-check.html|/neverssl.txt|/blank.html) return 0 ;;
  esac
  return 1
}

read_request || exit 0

# The peer address is published by the listener in the environment. Without
# it, voucher redemption cannot map a request to a device, so say so in the
# log instead of failing silently the way an undefined helper would.
if command -v resolve_client_ip >/dev/null 2>&1; then
  CLIENT_IP=$(resolve_client_ip 2>/dev/null || true)
else
  CLIENT_IP=""
fi
export CLIENT_IP
if [ -z "$CLIENT_IP" ] && [ "${RNS_LAB:-0}" != "1" ]; then
  printf '%s front: no peer address for %s %s (listener must export SOCAT_PEERADDR)\n' \
    "$("$BB" date +%s 2>/dev/null)" "${RNS_METHOD:-?}" "${RNS_PATH:-?}" \
    >> "$PAGES_LOG" 2>/dev/null
fi

case "$RNS_PATH" in
  /favicon.ico) send_no_content ;;
  /health) send_bytes "200 OK" "application/json" '{"ok":true,"service":"rns-front","pages":true,"admin":true,"portal":true}' ;;
  /admin) send_admin ;;
  /) send_portal ;;
  /api/*) delegate_api ;;
  *) send_portal ;;
esac
exit 0
