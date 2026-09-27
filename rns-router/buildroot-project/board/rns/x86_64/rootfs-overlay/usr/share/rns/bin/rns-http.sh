#!/bin/sh
RNS_EXTRA_HDR=""
. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"

store_init
# resolve_client_ip (common.sh) reads the peer address the listener exports
# and validates it as IPv4; it replaced a call to a helper that never
# existed, which left CLIENT_IP empty and made every redemption fail.
CLIENT_IP=$(resolve_client_ip 2>/dev/null || true)
export CLIENT_IP

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

# Binary body (the PDF slips). Same wire format as send_raw; the file is
# already bytes, so nothing here may re-encode it.
send_pdf_file() {
  _status=$1; _file=$2; _name=$3
  _len=$("$BB" wc -c < "$_file" | "$BB" tr -d ' ')
  printf 'HTTP/1.0 %s\r\n' "$_status"
  printf 'Content-Type: application/pdf\r\n'
  printf 'Content-Length: %s\r\n' "$_len"
  printf 'Connection: close\r\n'
  printf 'Cache-Control: no-store\r\n'
  [ -n "${_name:-}" ] && printf 'Content-Disposition: inline; filename="%s"\r\n' "$_name"
  [ -n "${RNS_EXTRA_HDR:-}" ] && printf '%s\r\n' "$RNS_EXTRA_HDR"
  printf '\r\n'
  [ "${RNS_METHOD:-GET}" = "HEAD" ] || cat "$_file"
}

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
  case "$RNS_TARGET" in *\?*) RNS_QUERY=${RNS_TARGET#*?} ;; esac
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

# ------------------------------------------------------------ captive portal
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
  _lab=false; _labpass=""; _labcode=""
  if is_lab; then
    _lab=true; _labpass=$(lab_pass); _labcode=$(lab_sample_code)
    [ -n "$_labcode" ] || _labcode="-"
  fi
  _pay=false
  online_pay_on && _pay=true
  send_json "200 OK" "$(printf '{"ok":true,"lab":%s,"lab_pass":"%s","lab_code":"%s","setup_required":%s,"brand":"%s","shop":"%s","ssid":"%s","pay_online":%s,"portal_port":%s}' \
    "$_lab" "$(json_escape "$_labpass")" "$(json_escape "$_labcode")" \
    "$(auth_needed && echo true || echo false)" \
    "$(json_escape "$(cfg_get BRAND RNS)")" \
    "$(json_escape "$(cfg_get SHOP "RNS Internet")")" \
    "$(json_escape "$(cfg_get SSID RNS)")" \
    "$_pay" \
    "$(cfg_get PORTAL_PORT 8080)")"
}

health_json() {
  printf '{"ok":true,"service":"rns","pages":true,"storage":"%s"}' "$(json_escape "$RNS_DATA")"
}

# ------------------------------------------------- Buy Online (public, no login)
# The captive portal only shows Buy Online when a wallet number is configured
# and at least one online package exists, so an operator who does not take
# mobile-money payments never exposes the flow.
do_pay_packages() {
  online_pay_on || { send_json "200 OK" '{"ok":false,"error":"Online payments are not enabled."}'; return 0; }
  send_json "200 OK" "$(printf '{"ok":true,"packages":%s,"jazzcash_number":"%s","jazzcash_name":"%s","easypaisa_number":"%s","easypaisa_name":"%s","auto_verify":%s}' \
    "$(online_packages_json)" \
    "$(json_escape "$(wallet_number jazzcash)")" \
    "$(json_escape "$(cfg_get JAZZCASH_NAME '')")" \
    "$(json_escape "$(wallet_number easypaisa)")" \
    "$(json_escape "$(cfg_get EASYPAISA_NAME '')")" \
    "$(pay_autoverify_on && echo true || echo false)")"
}

do_pay_init() {
  rate_allow "$CLIENT_IP" || {
    send_json "200 OK" '{"ok":false,"error":"Too many attempts. Wait a few minutes.","reason":"slow"}'
    return 0
  }
  online_pay_on || { send_json "200 OK" '{"ok":false,"error":"Online payments are not enabled."}'; return 0; }
  _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
  [ -n "$_mac" ] || {
    send_json "200 OK" '{"ok":false,"error":"This device is not visible yet. Wait 5 seconds and try again.","reason":"nomac"}'
    return 0
  }
  _ref=$(with_lock pay_init "$(form_get package_id)" "$(form_get method)" "$_mac" "$CLIENT_IP")
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_ref")")"
    return 0
  fi
  send_json "200 OK" "$(printf '{"ok":true,"ref":"%s"}' "$(json_escape "$_ref")")"
}

# pay_submit already decides confirmed-vs-pending from PAY_AUTO_VERIFY, so this
# handler only has to translate its result and open the gate when it bound a
# voucher.
do_pay_submit() {
  rate_allow "$CLIENT_IP" || {
    send_json "200 OK" '{"ok":false,"error":"Too many attempts. Wait a few minutes.","reason":"slow"}'
    return 0
  }
  online_pay_on || { send_json "200 OK" '{"ok":false,"error":"Online payments are not enabled."}'; return 0; }
  _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
  [ -n "$_mac" ] || {
    send_json "200 OK" '{"ok":false,"error":"This device is not visible yet. Wait 5 seconds and try again.","reason":"nomac"}'
    return 0
  }
  _res=$(with_lock pay_submit "$(form_get ref)" "$(form_get tid)" "$_mac" "$CLIENT_IP")
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    _err=$(printf '%s' "$_res" | "$BB" tr -d '\n')
    case "$_err" in
      missing_ref|unknown_ref) _reason=$_err ;;
      *) _reason="" ;;
    esac
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s","reason":"%s"}' \
      "$(json_escape "${_err:-Could not verify the payment.}")" "$_reason")"
    return 0
  fi
  _st=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
  _payid=$(printf '%s' "$_res" | "$BB" cut -d'|' -f3)
  _vcode=$(printf '%s' "$_res" | "$BB" cut -d'|' -f4)
  _exp=$(printf '%s' "$_res" | "$BB" cut -d'|' -f5)
  _down=$(printf '%s' "$_res" | "$BB" cut -d'|' -f6)
  _up=$(printf '%s' "$_res" | "$BB" cut -d'|' -f7)
  _now=$(now_epoch)
  if [ "$_st" = "confirmed" ]; then
    fw_rebuild; shape_apply
    _left=$((_exp - _now)); [ "$_left" -lt 0 ] && _left=0
    send_json "200 OK" "$(printf '{"ok":true,"status":"confirmed","pay_id":"%s","voucher_code":"%s","expires":%s,"left":%s,"now":%s,"down_kbps":%s,"up_kbps":%s,"tid":"%s","ref":"%s"}' \
      "$(json_escape "$_payid")" "$(json_escape "$_vcode")" "${_exp:-0}" "$_left" "$_now" \
      "${_down:-0}" "${_up:-0}" "$(json_escape "$(form_get tid)")" "$(json_escape "$(form_get ref)")")"
  else
    send_json "200 OK" "$(printf '{"ok":true,"status":"pending","pay_id":"%s","voucher_code":"","left":0,"now":%s,"tid":"%s","ref":"%s"}' \
      "$(json_escape "$_payid")" "$_now" "$(json_escape "$(form_get tid)")" "$(json_escape "$(form_get ref)")")"
  fi
}

# The customer polls this every few seconds, so it is deliberately cheap and
# not rate limited — but it only answers to the device that raised the payment.
do_pay_status() {
  _id=$(printf '%s' "$(form_get pay_id)" | "$BB" tr -cd 'A-Za-z0-9')
  [ -n "$_id" ] || { send_json "200 OK" '{"ok":true,"status":"none"}'; return 0; }
  _row=$(pay_row "$_id")
  [ -n "$_row" ] || { send_json "200 OK" '{"ok":true,"status":"none"}'; return 0; }
  _pmac=$(printf '%s' "$_row" | "$BB" cut -d'|' -f3)
  if [ -n "$_pmac" ]; then
    _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
    [ "$_mac" = "$_pmac" ] || {
      send_json "403 Forbidden" '{"ok":false,"error":"That payment belongs to another device."}'
      return 0
    }
  fi
  _st=$(printf '%s' "$_row" | "$BB" cut -d'|' -f13)
  _payid=$(printf '%s' "$_row" | "$BB" cut -d'|' -f1)
  _ref=$(printf '%s' "$_row" | "$BB" cut -d'|' -f2)
  _tid=$(printf '%s' "$_row" | "$BB" cut -d'|' -f11)
  _vcode=$(printf '%s' "$_row" | "$BB" cut -d'|' -f17)
  _note=$(printf '%s' "$_row" | "$BB" cut -d'|' -f16)
  _label=$(printf '%s' "$_row" | "$BB" cut -d'|' -f6)
  _sec=$(printf '%s' "$_row" | "$BB" cut -d'|' -f7)
  _down=$(printf '%s' "$_row" | "$BB" cut -d'|' -f8)
  _up=$(printf '%s' "$_row" | "$BB" cut -d'|' -f9)
  _left=0; _exp=0
  if [ -n "$_vcode" ]; then
    _vrow=$(_voucher_row "$_vcode")
    _exp=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $10}')
    _now=$(now_epoch)
    [ "$(num "$_exp")" -gt "$_now" ] && _left=$(( $(num "$_exp") - _now ))
  fi
  send_json "200 OK" "$(printf '{"ok":true,"status":"%s","pay_id":"%s","ref":"%s","tid":"%s","voucher_code":"%s","package_label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"expires":%s,"left":%s,"now":%s,"note":"%s"}' \
    "$(json_escape "$_st")" "$(json_escape "$_payid")" "$(json_escape "$_ref")" \
    "$(json_escape "$_tid")" "$(json_escape "$_vcode")" "$(json_escape "$_label")" \
    "$(num "$_sec")" "$(num "$_down")" "$(num "$_up")" "$(num "$_exp")" "$(num "$_left")" \
    "$(now_epoch)" "$(json_escape "$_note")")"
}

do_pay_receipt() {
  _id=$(printf '%s' "$(form_get pay_id)" | "$BB" tr -cd 'A-Za-z0-9')
  [ -n "$_id" ] || { send_json "400 Bad Request" '{"ok":false,"error":"Missing payment id."}'; return 0; }
  _row=$(pay_row "$_id")
  [ -n "$_row" ] || { send_json "404 Not Found" '{"ok":false,"error":"Unknown payment."}'; return 0; }
  _pmac=$(printf '%s' "$_row" | "$BB" cut -d'|' -f3)
  if [ -n "$_pmac" ]; then
    _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
    [ "$_mac" = "$_pmac" ] || {
      send_json "403 Forbidden" '{"ok":false,"error":"That receipt belongs to another device."}'
      return 0
    }
  fi
  _vcode=$(printf '%s' "$_row" | "$BB" cut -d'|' -f17)
  [ -n "$_vcode" ] || {
    send_json "409 Conflict" '{"ok":false,"error":"This payment has no voucher yet."}'
    return 0
  }
  _vrow=$(_voucher_row "$_vcode")
  _rows="$RNS_DATA/receipt.$$"
  # receipt columns: voucher, label, seconds, down, up, paid_at, expires,
  #                 amount, method, tid, ref
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(fmt_code "$_vcode")" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f6)" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f7)" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f8)" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f9)" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f15)" \
    "$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $10}')" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f12)" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f10)" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f11)" \
    "$(printf '%s' "$_row" | "$BB" cut -d'|' -f2)" > "$_rows"
  _pdf=$(pdf_render receipt "$_rows" "$(cfg_get SHOP "RNS Internet")")
  if [ -z "$_pdf" ]; then
    rm -f "$_rows"
    send_json "500 Internal Server Error" '{"ok":false,"error":"Could not build the receipt."}'
    return 0
  fi
  send_pdf_file "200 OK" "$_pdf" "rns-receipt-$_id.pdf"
  rm -f "$_pdf" "$_rows"
}

# ------------------------------------------------------------------ staff API
# The Sales tab sends ISO dates; the report window is [from, to+1day).
sales_window() {
  _f=$(form_get from); _t=$(form_get to)
  [ -n "$_f" ] || _f=$(ymd_shift "$(today_ymd)" -6)
  [ -n "$_t" ] || _t=$(today_ymd)
  _fs=$(ymd_to_epoch "$_f") || _fs=$(ymd_to_epoch "$(today_ymd)")
  _ts=$(ymd_to_epoch "$_t" end) || _ts=$((_fs + 7 * 86400))
  printf '%s %s' "$_fs" "$_ts"
}

do_sales_json() {
  require_admin
  _w=$(sales_window); _from=${_w%% *}; _to=${_w##* }
  send_json "200 OK" "$(printf '{"ok":true,"from":%s,"to":%s,"sales":%s}' \
    "$_from" "$_to" "$(sales_json "$_from" "$_to")")"
}

do_sales_csv() {
  require_admin
  _w=$(sales_window); _from=${_w%% *}; _to=${_w##* }
  RNS_EXTRA_HDR='Content-Disposition: attachment; filename="rns-sales.csv"'
  send_text "200 OK" "text/csv; charset=utf-8" "$(sales_csv "$_from" "$_to")"
}

# Voucher slips. Either the current filter+search, or an explicit list of codes
# straight from the Sell tab's "PDF of these vouchers" button.
do_vouchers_pdf() {
  require_admin
  _codes=$(form_get codes)
  _status=$(form_get status); _search=$(form_get search)
  _rows="$RNS_DATA/vpdf.$$"
  "$BB" awk -F'|' -v codes="$_codes" -v filter="$_status" -v search="$_search" '
    function show(c) { return substr(c,1,4) "-" substr(c,5,8) }
    BEGIN {
      n = split(codes, a, ",")
      for (i = 1; i <= n; i++) {
        gsub(/[^A-Za-z0-9]/, "", a[i]); a[i] = toupper(a[i])
        if (a[i] != "") want[a[i]] = 1
      }
      f = tolower(filter); s = tolower(search)
    }
    NF == 0 { next }
    {
      if (length(want) > 0) { if (!($1 in want)) next }
      else {
        if (f != "" && f != "all" && $6 != f) next
        if (s != "") {
          hay = tolower($1 " " $2 " " $7 " " $8)
          if (index(hay, s) == 0) next
        }
      }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", show($1), $2, $3, $4, $5, $11, $10, $13
    }' "$VFILE" > "$_rows"
  _pdf=$(pdf_render voucher "$_rows" "$(cfg_get SHOP "RNS Internet")")
  rm -f "$_rows"
  [ -n "$_pdf" ] || {
    send_json "500 Internal Server Error" '{"ok":false,"error":"Could not build the PDF."}'
    return 0
  }
  send_pdf_file "200 OK" "$_pdf" "rns-vouchers.pdf"
  rm -f "$_pdf"
}

do_payments_list() {
  require_admin
  send_json "200 OK" "$(printf '{"ok":true,"payments":%s}' "$(payments_json)")"
}

do_pay_confirm() {
  require_admin
  _id=$(printf '%s' "$(form_get pay_id)" | "$BB" tr -cd 'A-Za-z0-9')
  [ -n "$_id" ] || { send_json "200 OK" '{"ok":false,"error":"Missing payment id."}'; return 0; }
  _res=$(with_lock pay_confirm "$_id"); _rc=$?
  if [ "$_rc" -ne 0 ]; then
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_res")")"
    return 0
  fi
  fw_rebuild; shape_apply
  _vcode=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
  _exp=$(printf '%s' "$_res" | "$BB" cut -d'|' -f3)
  _left=$((_exp - $(now_epoch))); [ "$_left" -lt 0 ] && _left=0
  send_json "200 OK" "$(printf '{"ok":true,"voucher_code":"%s","left":%s}' \
    "$(json_escape "$_vcode")" "$_left")"
}

do_pay_reject() {
  require_admin
  _id=$(printf '%s' "$(form_get pay_id)" | "$BB" tr -cd 'A-Za-z0-9')
  [ -n "$_id" ] || { send_json "200 OK" '{"ok":false,"error":"Missing payment id."}'; return 0; }
  _res=$(with_lock pay_reject "$_id" "$(form_get note)"); _rc=$?
  if [ "$_rc" -ne 0 ]; then
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_res")")"
    return 0
  fi
  send_json "200 OK" '{"ok":true}'
}

do_online_packages() {
  require_admin
  if [ "$RNS_METHOD" = "POST" ]; then
    if [ "$(form_get action)" = "delete" ]; then
      _msg=$(with_lock online_package_delete "$(form_get id)"); _rc=$?
    else
      _sec=$(form_get seconds)
      [ -z "$_sec" ] && _sec=$(duration_seconds "$(form_get duration)" "$(form_get duration_unit)")
      _msg=$(with_lock online_package_upsert "$(form_get id)" "$(form_get label)" "$_sec" \
        "$(form_get down_kbps)" "$(form_get up_kbps)" "$(form_get price)" \
        "$(form_get rate)" "$(form_get rate_unit)")
      _rc=$?
    fi
    if [ "$_rc" -ne 0 ]; then
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
      exit 0
    fi
    send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(online_packages_json)")"
    exit 0
  fi
  send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(online_packages_json)")"
}

# Both halves of the settings form post to the same endpoint. form_has (not
# form_get) decides which half arrived, because a wallet number has to be
# clearable and form_get cannot tell "absent" from "empty".
do_settings() {
  require_admin
  if [ "$RNS_METHOD" = "POST" ]; then
    _ap=reboot
    if form_has shop || form_has ssid || form_has channel || form_has max_sta; then
      _shop=$(sanitize_token "$(form_get shop)")
      [ -n "$_shop" ] && cfg_set SHOP "$_shop"
      _ssid=$(sanitize_token "$(form_get ssid)")
      [ -n "$_ssid" ] && cfg_set SSID "$_ssid"
      if form_has channel; then
        _ch=$(printf '%s' "$(form_get channel)" | "$BB" tr -cd '0-9')
        cfg_set CHANNEL "${_ch:-6}"
      fi
      if form_has max_sta; then
        _ms=$(printf '%s' "$(form_get max_sta)" | "$BB" tr -cd '0-9')
        cfg_set MAX_STA "${_ms:-128}"
      fi
      if hostapd_apply; then _ap=applied; fi
    fi
    if form_has jazzcash_number || form_has easypaisa_number || form_has pay_auto_verify; then
      if form_has jazzcash_number; then
        cfg_set JAZZCASH_NUMBER "$(sanitize_wallet "$(form_get jazzcash_number)")"
      fi
      if form_has jazzcash_name; then
        cfg_set JAZZCASH_NAME "$(sanitize_token "$(form_get jazzcash_name)")"
      fi
      if form_has easypaisa_number; then
        cfg_set EASYPAISA_NUMBER "$(sanitize_wallet "$(form_get easypaisa_number)")"
      fi
      if form_has easypaisa_name; then
        cfg_set EASYPAISA_NAME "$(sanitize_token "$(form_get easypaisa_name)")"
      fi
      if form_has pay_auto_verify; then
        cfg_set PAY_AUTO_VERIFY "$(sanitize_flag "$(form_get pay_auto_verify)")"
      fi
      log_event settings "payment settings updated"
    fi
    send_json "200 OK" "$(printf '{"ok":true,"ap":"%s"}' "$_ap")"
    exit 0
  fi
  _paused=false
  [ -f "$RNS_DATA/PAUSE" ] && _paused=true
  # online_pay and pay_auto_verify are reported as 1/0, not true/false: the
  # panel compares them against the string "1", and a JSON boolean would
  # silently hide the whole online-payments half of the UI.
  _onpay=0; online_pay_on && _onpay=1
  _auto=0; pay_autoverify_on && _auto=1
  send_json "200 OK" "$(printf '{"ok":true,"shop":"%s","ssid":"%s","channel":%s,"max_sta":%s,"paused":%s,"online_pay":%s,"jazzcash_number":"%s","jazzcash_name":"%s","easypaisa_number":"%s","easypaisa_name":"%s","pay_auto_verify":%s}' \
    "$(json_escape "$(cfg_get SHOP "RNS Internet")")" \
    "$(json_escape "$(cfg_get SSID RNS)")" \
    "$(cfg_get CHANNEL 6)" "$(cfg_get MAX_STA 128)" \
    "$_paused" "$_onpay" \
    "$(json_escape "$(wallet_number jazzcash)")" \
    "$(json_escape "$(cfg_get JAZZCASH_NAME '')")" \
    "$(json_escape "$(wallet_number easypaisa)")" \
    "$(json_escape "$(cfg_get EASYPAISA_NAME '')")" \
    "$_auto")"
}

do_backup() {
  require_admin
  _dst=$(with_lock backup_create); _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "$_dst" ]; then
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "${_dst:-unknown error}")")"
    return 0
  fi
  send_json "200 OK" "$(printf '{"ok":true,"backup":"%s"}' "$(json_escape "$_dst")")"
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
  /api/pay/packages) do_pay_packages ;;
  /api/pay/init) do_pay_init ;;
  /api/pay/submit) do_pay_submit ;;
  /api/pay/status) do_pay_status ;;
  /api/pay/receipt) do_pay_receipt ;;
  /api/admin/overview)
    require_admin; send_json "200 OK" "$(printf '{"ok":true,"counts":%s}' "$(overview_json)")" ;;
  /api/admin/vouchers)
    require_admin
    _vf=$(urldecode "$(form_get status)"); _vs=$(urldecode "$(form_get search)")
    send_json "200 OK" "$(printf '{"ok":true,"vouchers":%s}' "$(vouchers_json "$_vf" "$_vs")")" ;;
  /api/admin/vouchers.pdf) do_vouchers_pdf ;;
  /api/admin/packages)
    require_admin
    if [ "$RNS_METHOD" = "POST" ]; then
      if [ "$(form_get action)" = "delete" ]; then
        _msg=$(with_lock package_delete "$(form_get id)")
        _rc=$?
      else
        _sec=$(form_get seconds)
        [ -z "$_sec" ] && _sec=$(duration_seconds "$(form_get duration)" "$(form_get duration_unit)")
        _msg=$(with_lock package_upsert "$(form_get id)" "$(form_get label)" "$_sec" "$(form_get down_kbps)" "$(form_get up_kbps)" "$(form_get price)" "$(form_get rate)" "$(form_get rate_unit)")
        _rc=$?
      fi
      if [ "$_rc" -ne 0 ]; then send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"; exit 0; fi
      send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(packages_json)")"
      exit 0
    fi
    send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(packages_json)")" ;;
  /api/admin/online-packages) do_online_packages ;;
  /api/admin/clients)
    require_admin; send_json "200 OK" "$(printf '{"ok":true,"clients":%s}' "$(clients_json)")" ;;
  /api/admin/events)
    require_admin; send_json "200 OK" "$(printf '{"ok":true,"events":%s}' "$(events_json)")" ;;
  /api/admin/settings) do_settings ;;
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
  /api/admin/payments) do_payments_list ;;
  /api/admin/pay-confirm) do_pay_confirm ;;
  /api/admin/pay-reject) do_pay_reject ;;
  /api/admin/sales.csv) do_sales_csv ;;
  /api/admin/sales) do_sales_json ;;
  /api/admin/backup) do_backup ;;
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
