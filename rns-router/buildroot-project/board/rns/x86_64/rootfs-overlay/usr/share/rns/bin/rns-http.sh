#!/bin/sh
RNS_EXTRA_HDR=""
. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"

store_init
CLIENT_IP=$(resolve_client_ip 2>/dev/null || true)

send_raw() {
  _status=$1; _ctype=$2; _file=$3
  _len=$("$BB" wc -c < "$_file" | "$BB" tr -d ' ')
  printf 'HTTP/1.0 %s\r\n' "$_status"
  printf 'Content-Type: %s\r\n' "$_ctype"
  printf 'Content-Length: %s\r\n' "$_len"
  printf 'Connection: close\r\n'
  printf 'Cache-Control: no-store\r\n'
  [ -n "${RNS_EXTRA_HDR:-}" ] && printf '%s\r\n' "$RNS_EXTRA_HDR"
  printf '\r\n'
  [ "${RNS_METHOD:-GET}" = "HEAD" ] || cat "$_file"
}

send_text() {
  _tmp="$RNS_DATA/body.$$"
  printf '%s' "$3" > "$_tmp"
  send_raw "$1" "$2" "$_tmp"
  rm -f "$_tmp"
}

send_json() { send_text "$1" "application/json; charset=utf-8" "$2"; }
send_html_file() { send_raw "200 OK" "text/html; charset=utf-8" "$1"; }

send_no_content() {
  printf 'HTTP/1.0 204 No Content\r\nConnection: close\r\n\r\n'
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
  return 0
}

session_token() {
  printf '%s' "$RNS_COOKIE" | "$BB" tr ';' '\n' | "$BB" sed 's/^ *//' \
    | "$BB" sed -n 's/^rns=//p' | "$BB" head -n 1 | "$BB" tr -cd '0-9a-f'
}

wants_json() { printf '%s' "$RNS_ACCEPT" | "$BB" grep -q 'application/json'; }

require_admin() {
  _tok=$(session_token)
  auth_session_ok "$_tok" || { send_json "401 Unauthorized" '{"ok":false,"error":"Login required."}'; exit 0; }
}

html_result() {
  _tmp="$RNS_DATA/body.$$"
  cat > "$_tmp" <<HTMLEOF
<!doctype html><html><head><meta charset="utf-8"><title>$1</title></head>
<body style="font-family:sans-serif;background:#f4efe4;color:#14211b;padding:24px">
<h1>$1</h1><p>$2</p><p><a href="/">Back</a></p></body></html>
HTMLEOF
  send_raw "200 OK" "text/html; charset=utf-8" "$_tmp"
  rm -f "$_tmp"
}

do_redeem() {
  _code=$(form_get code)
  _res=$(with_lock voucher_redeem "$_code" "$CLIENT_IP")
  _rc=$?
  _kind=$(printf '%s' "$_res" | "$BB" cut -d'|' -f1)
  if [ "$_rc" -eq 0 ] && [ "$_kind" = "ok" ]; then
    fw_rebuild; shape_apply
    _plan=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
    _exp=$(printf '%s' "$_res" | "$BB" cut -d'|' -f3)
    _down=$(printf '%s' "$_res" | "$BB" cut -d'|' -f4)
    _up=$(printf '%s' "$_res" | "$BB" cut -d'|' -f5)
    _mac=$(printf '%s' "$_res" | "$BB" cut -d'|' -f6)
    _left=$((_exp - $(now_epoch))); [ "$_left" -lt 0 ] && _left=0
    if wants_json; then
      send_json "200 OK" "$(printf '{"ok":true,"plan":"%s","expires":%s,"left":%s,"now":%s,"down_kbps":%s,"up_kbps":%s,"mac":"%s"}' \
        "$(json_escape "$_plan")" "$_exp" "$_left" "$(now_epoch)" "${_down:-0}" "${_up:-0}" "$(json_escape "$_mac")")"
    else
      html_result "Internet is on" "$_plan is active on this phone."
    fi
    return
  fi
  _err="That code is not valid."
  case "$_kind" in
    used) _err="This code is already used on another phone." ;;
    slow) _err="Too many tries. Wait a few minutes." ;;
    nomac) _err="This phone is not visible yet. Wait 5 seconds and try again." ;;
    kicked) _err="Your connection was paused by staff." ;;
    banned) _err="This device is blocked." ;;
  esac
  if wants_json; then
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s","reason":"%s"}' "$(json_escape "$_err")" "$(json_escape "$_kind")")"
  else
    html_result "Not connected" "$_err"
  fi
}

do_me() {
  _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
  _row=""
  [ -n "$_mac" ] && _row=$(voucher_for_mac "$_mac")
  if [ -z "$_row" ]; then
    _why=""
    if [ -n "$_mac" ]; then
      case "$(client_state "$_mac")" in banned) _why=banned ;; kicked) _why=kicked ;; esac
    fi
    send_json "200 OK" "$(printf '{"ok":true,"bound":false,"reason":"%s","now":%s}' "$_why" "$(now_epoch)")"
    return
  fi
  _plan=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _exp=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $10}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _left=$((_exp - $(now_epoch))); [ "$_left" -lt 0 ] && _left=0
  send_json "200 OK" "$(printf '{"ok":true,"bound":true,"plan":"%s","expires":%s,"left":%s,"now":%s,"down_kbps":%s,"up_kbps":%s}' \
    "$(json_escape "$_plan")" "${_exp:-0}" "$_left" "$(now_epoch)" "${_down:-0}" "${_up:-0}")"
}

status_public() {
  send_json "200 OK" "$(printf '{"ok":true,"lab":false,"setup_required":%s,"brand":"%s","shop":"%s","ssid":"%s","portal_port":%s}' \
    "$(auth_needed && echo true || echo false)" \
    "$(json_escape "$(cfg_get BRAND RNS)")" \
    "$(json_escape "$(cfg_get SHOP "RNS Internet")")" \
    "$(json_escape "$(cfg_get SSID RNS)")" \
    "$(cfg_get PORTAL_PORT 8080)")"
}

health_json() {
  printf '{"ok":true,"service":"rns","pages":true,"storage":"%s"}' "$(json_escape "$RNS_DATA")"
}

if [ "${RNS_DELEGATED:-0}" != "1" ]; then
  read_request || exit 0
fi

case "$RNS_PATH" in
  /favicon.ico) send_text "204 No Content" "text/plain" "" ;;
  /health) send_json "200 OK" "$(health_json)" ;;
  /api/status) status_public ;;
  /api/me) do_me ;;
  /api/redeem) do_redeem ;;
  /api/setup)
    _msg=$(auth_setup "$(form_get password)")
    if [ $? -eq 0 ]; then
      _tok=$(auth_login "$(form_get password)" "$(form_get remember)")
      RNS_EXTRA_HDR="Set-Cookie: rns=$_tok; Path=/; HttpOnly; SameSite=Lax"
      send_json "200 OK" '{"ok":true}'
    else
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    fi ;;
  /api/login)
    _tok=$(auth_login "$(form_get password)" "$(form_get remember)")
    if [ -n "$_tok" ]; then
      RNS_EXTRA_HDR="Set-Cookie: rns=$_tok; Path=/; HttpOnly; SameSite=Lax"
      send_json "200 OK" '{"ok":true}'
    else
      send_json "200 OK" '{"ok":false,"error":"Wrong password."}'
    fi ;;
  /api/logout)
    auth_logout "$(session_token)"
    RNS_EXTRA_HDR="Set-Cookie: rns=; Path=/; Max-Age=0"
    send_json "200 OK" '{"ok":true}' ;;
  /api/admin/overview)
    require_admin; send_json "200 OK" "$(printf '{"ok":true,"counts":%s}' "$(overview_json)")" ;;
  /api/admin/vouchers)
    require_admin
    _vf=$(urldecode "$(form_get status)"); _vs=$(urldecode "$(form_get search)")
    send_json "200 OK" "$(printf '{"ok":true,"vouchers":%s}' "$(vouchers_json "$_vf" "$_vs")")" ;;
  /api/admin/packages)
    require_admin
    if [ "$RNS_METHOD" = "POST" ]; then
      if [ "$(form_get action)" = "delete" ]; then
        _msg=$(with_lock package_delete "$(form_get id)")
        _rc=$?
      else
        _sec=$(form_get seconds)
        [ -z "$_sec" ] && _sec=$(duration_seconds "$(form_get duration)" "$(form_get duration_unit)")
        _msg=$(with_lock package_upsert "$(form_get id)" "$(form_get label)" "$_sec" "$(form_get down_kbps)" "$(form_get up_kbps)" "$(form_get price)")
        _rc=$?
      fi
      if [ "$_rc" -ne 0 ]; then send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"; exit 0; fi
      send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(packages_json)")"
      exit 0
    fi
    send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(packages_json)")" ;;
  /api/admin/clients)
    require_admin; send_json "200 OK" "$(printf '{"ok":true,"clients":%s}' "$(clients_json)")" ;;
  /api/admin/events)
    require_admin; send_json "200 OK" "$(printf '{"ok":true,"events":%s}' "$(events_json)")" ;;
  /api/admin/settings)
    require_admin
    if [ "$RNS_METHOD" = "POST" ]; then
      [ -n "$(form_get ssid)" ] && cfg_set SSID "$(sanitize_token "$(form_get ssid)")"
      [ -n "$(form_get shop)" ] && cfg_set SHOP "$(sanitize_token "$(form_get shop)")"
      [ -n "$(form_get channel)" ] && cfg_set CHANNEL "$(form_get channel | "$BB" tr -cd '0-9')"
      [ -n "$(form_get max_sta)" ] && cfg_set MAX_STA "$(form_get max_sta | "$BB" tr -cd '0-9')"
    fi
    send_json "200 OK" "$(printf '{"ok":true,"shop":"%s","ssid":"%s","channel":%s,"max_sta":%s}' \
      "$(json_escape "$(cfg_get SHOP "RNS Internet")")" \
      "$(json_escape "$(cfg_get SSID RNS)")" \
      "$(cfg_get CHANNEL 6)" "$(cfg_get MAX_STA 128)")" ;;
  /api/admin/mint)
    require_admin
    _codes=$(with_lock voucher_mint "$(form_get plan)" "$(form_get count)" "$(form_get note)")
    _rc=$?
    if [ "$_rc" -ne 0 ]; then send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_codes")")"
    else
      _jsonc=""
      for _c in $_codes; do
        [ -n "$_jsonc" ] && _jsonc="$_jsonc,"
        _jsonc="${_jsonc}\"$(json_escape "$_c")\""
      done
      send_json "200 OK" "{\"ok\":true,\"codes\":[${_jsonc}]}"
    fi ;;
  /api/admin/revoke)
    require_admin
    _msg=$(with_lock voucher_revoke "$(form_get code)"); _rc=$?
    fw_rebuild
    if [ "$_rc" -ne 0 ]; then send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else send_json "200 OK" '{"ok":true}'; fi ;;
  /api/admin/delete)
    require_admin
    _msg=$(with_lock voucher_delete "$(form_get code)"); _rc=$?
    fw_rebuild
    if [ "$_rc" -ne 0 ]; then send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else send_json "200 OK" '{"ok":true}'; fi ;;
  /api/admin/unbind)
    require_admin
    _code=$(sanitize_code "$(form_get code)")
    _row=$(_voucher_row "$_code")
    _mac=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
    _msg=$(with_lock voucher_unbind "$_code"); _rc=$?
    [ -n "$_mac" ] && deauth_mac "$_mac"
    fw_rebuild
    if [ "$_rc" -ne 0 ]; then send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else send_json "200 OK" '{"ok":true}'; fi ;;
  /api/admin/client-status|/api/admin/kick)
    require_admin
    _mac=$(sanitize_mac "$(form_get mac)")
    _state=$(form_get state); [ -n "$_state" ] || _state=kicked
    _msg=$(with_lock client_set_state "$_mac" "$_state"); _rc=$?
    case "$_state" in
      kicked|banned) client_disconnect "$_mac" ;;
      *) fw_rebuild ;;
    esac
    if [ "$_rc" -ne 0 ]; then send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else send_json "200 OK" "$(printf '{"ok":true,"state":"%s"}' "$(json_escape "$_state")")"; fi ;;
  /api/admin/pause)
    require_admin
    if [ -f "$RNS_DATA/PAUSE" ]; then
      rm -f "$RNS_DATA/PAUSE"; fw_rebuild
      send_json "200 OK" '{"ok":true,"paused":false}'
    else
      printf '1\n' > "$RNS_DATA/PAUSE"; fw_clear
      send_json "200 OK" '{"ok":true,"paused":true}'
    fi ;;
  /api/admin/password)
    require_admin
    _old=$(form_get old); _new=$(form_get new)
    _nlen=$(printf '%s' "$_new" | "$BB" wc -c | "$BB" tr -d ' ')
    if [ "$_nlen" -lt 6 ]; then send_json "200 OK" '{"ok":false,"error":"New password must be at least 6 characters."}'; exit 0; fi
    if ! auth_check_pass "$_old"; then send_json "200 OK" '{"ok":false,"error":"Current password is wrong."}'; exit 0; fi
    _set_pass admin "$_new"
    send_json "200 OK" '{"ok":true}' ;;
  /admin)
    send_html_file "$RNS_WWW/admin.html" ;;
  /)
    send_html_file "$RNS_WWW/portal.html" ;;
  *)
    _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
    _row=""
    [ -n "$_mac" ] && _row=$(voucher_for_mac "$_mac")
    if [ -n "$_row" ]; then
      if gate_heal; then
        _host=$(printf '%s' "$RNS_HOST" | "$BB" tr -cd 'A-Za-z0-9.:_-' | "$BB" cut -c1-253)
        if [ -n "$_host" ]; then
          printf 'HTTP/1.0 302 Found\r\nLocation: http://%s%s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' "$_host" "$RNS_PATH"
          exit 0
        fi
      fi
    fi
    send_html_file "$RNS_WWW/portal.html" ;;
esac
