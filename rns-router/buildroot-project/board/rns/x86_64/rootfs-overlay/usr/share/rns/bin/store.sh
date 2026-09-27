# Voucher, session, and client store. Flat files, no SQLite.

. "$RNS_HOME/bin/common.sh"

VFILE="$RNS_DB_DIR/vouchers.tsv"
CFILE="$RNS_DB_DIR/clients.tsv"
AFILE="$RNS_DB_DIR/admin.auth"
PFILE="$RNS_DB_DIR/packages.tsv"
CSTATE="$RNS_DB_DIR/client-states.tsv"
HFILE="$RNS_DB_DIR/voucher-history.tsv"

store_init() {
  mkdir -p "$RNS_DATA" "$RNS_DB_DIR" "$RNS_LOG_DIR" \
           "$RNS_DATA/backups" "$RNS_DATA/exports" "$RNS_DATA/sessions" \
           "$RNS_DATA/ratelimit"
  [ -f "$VFILE" ] || printf '' > "$VFILE"
  [ -f "$CFILE" ] || printf '' > "$CFILE"
  [ -f "$CSTATE" ] || printf '' > "$CSTATE"
  [ -f "$HFILE" ] || printf '' > "$HFILE"
  [ -f "$EVENTS_FILE" ] || printf '' > "$EVENTS_FILE"
  [ -f "$PFILE" ] || printf '' > "$PFILE"
  if [ ! -f "$RNS_DATA/config.env" ]; then
    cat > "$RNS_DATA/config.env" <<CFG
SSID=RNS
CHANNEL=6
HW_MODE=g
MAX_STA=128
LAN_IF=br0
WAN_IF=auto
PORTAL_PORT=8080
BRAND=RNS
SHOP=RNS Internet
LAN_IP=192.168.50.1
CFG
  fi
}

_hash_pass() {
  printf '%s' "${1}:${2}" | "$BB" sha256sum | "$BB" awk '{print $1}'
}

_set_pass() {
  _salt=$("$BB" od -An -N8 -tx1 /dev/urandom | "$BB" tr -d ' \n')
  _hash=$(_hash_pass "$_salt" "$2")
  printf '%s %s %s\n' "$1" "$_salt" "$_hash" > "$AFILE"
  chmod 600 "$AFILE" 2>/dev/null
}

auth_needed() { [ ! -f "$AFILE" ]; }

auth_setup() {
  _len=$(printf '%s' "$1" | "$BB" wc -c | "$BB" tr -d ' ')
  [ "$_len" -ge 6 ] || { printf 'password must be at least 6 characters'; return 1; }
  [ -f "$AFILE" ] && { printf 'password already set'; return 1; }
  _set_pass admin "$1"
  log_event setup "admin password created"
  return 0
}

auth_check_pass() {
  [ -f "$AFILE" ] || return 1
  _salt=$( "$BB" awk '{print $2}' "$AFILE" )
  _want=$( "$BB" awk '{print $3}' "$AFILE" )
  [ "$(_hash_pass "$_salt" "$1")" = "$_want" ]
}

auth_login() {
  auth_check_pass "$1" || return 1
  _tok=$("$BB" od -An -N16 -tx1 /dev/urandom | "$BB" tr -d ' \n')
  _ttl=43200
  [ "$2" = "1" ] && _ttl=2592000
  printf '%s admin\n' "$(( $(now_epoch) + _ttl ))" > "$RNS_DATA/sessions/$_tok"
  printf '%s' "$_tok"
  log_event login "admin session"
}

auth_logout() {
  case "$1" in *[!0-9a-f]*|"") return 0 ;; esac
  rm -f "$RNS_DATA/sessions/$1"
}

auth_session_ok() {
  case "$1" in *[!0-9a-f]*|"") return 1 ;; esac
  [ -f "$RNS_DATA/sessions/$1" ] || return 1
  _exp=$( "$BB" awk '{print $1}' "$RNS_DATA/sessions/$1" )
  [ "$_exp" -ge "$(now_epoch)" ] || { rm -f "$RNS_DATA/sessions/$1"; return 1; }
  return 0
}

package_upsert() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _label=$(sanitize_token "$2")
  _sec=$(printf '%s' "$3" | "$BB" tr -cd '0-9')
  _down=$(printf '%s' "$4" | "$BB" tr -cd '0-9')
  _up=$(printf '%s' "$5" | "$BB" tr -cd '0-9')
  _price=$(money "$6")
  [ -n "$_id" ] && [ -n "$_label" ] && [ -n "$_sec" ] && [ -n "$_down" ] && [ -n "$_up" ] || {
    printf 'package requires id, name, duration and speeds'; return 1; }
  _tmp="${PFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v id="$_id" '$1 != id {print}' "$PFILE" > "$_tmp"
  printf '%s|%s|%s|%s|%s|%s|active\n' "$_id" "$_label" "$_sec" "$_down" "$_up" "$_price" >> "$_tmp"
  mv "$_tmp" "$PFILE"
  log_event package "$_id $_label"
}

package_row() {
  "$BB" awk -F'|' -v id="$1" '$1==id && ($7=="" || $7=="active") {print; exit}' "$PFILE"
}

package_delete() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  [ -n "$_id" ] || { printf 'missing id'; return 1; }
  _row=$(package_row "$_id")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  _tmp="${PFILE}.tmp"
  "$BB" awk -F'|' -v id="$_id" '$1 != id {print}' "$PFILE" > "$_tmp"
  mv "$_tmp" "$PFILE"
  printf 'deleted'
}

packages_json() {
  printf '['
  _first=1
  while IFS='|' read -r id label sec down up price state; do
    [ -n "$id" ] && [ "$state" != "disabled" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"id":"%s","label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"price":"%s"}' \
      "$(json_escape "$id")" "$(json_escape "$label")" "$(num "$sec")" \
      "$(num "$down")" "$(num "$up")" "$(json_escape "$(money "$price")")"
  done < "$PFILE"
  printf ']'
}

_rand_code() {
  "$BB" od -An -N4 -tx1 /dev/urandom | "$BB" tr -d ' \n' | "$BB" cut -c1-8 | "$BB" tr 'a-f' 'A-F'
}

_code_exists() {
  "$BB" awk -F'|' -v c="$1" '$1==c {found=1} END{exit !found}' "$VFILE"
}

fmt_code() {
  printf '%s-%s' "$(printf '%s' "$1" | "$BB" cut -c1-4)" "$(printf '%s' "$1" | "$BB" cut -c5-8)"
}

voucher_mint() {
  _plan=$1; _count=$2; _note=$(sanitize_token "$3")
  _row=$(package_row "$_plan")
  [ -n "$_row" ] || { printf 'unknown package'; return 1; }
  case "$_count" in ''|*[!0-9]*) _count=1 ;; esac
  [ "$_count" -ge 1 ] && [ "$_count" -le 100 ] || { printf 'count must be 1 to 100'; return 1; }
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _price=$(money "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')")
  _now=$(now_epoch); _out=""; _i=0
  while [ "$_i" -lt "$_count" ]; do
    _try=0; _code=""
    while [ "$_try" -lt 20 ]; do
      _code=$(_rand_code)
      _code_exists "$_code" || break
      _try=$((_try + 1))
    done
    printf '%s|%s|%s|%s|%s|new|||||%s|%s|%s\n' \
      "$_code" "$_label" "$_sec" "$_down" "$_up" "$_now" "$_note" "$_price" >> "$VFILE"
    _shown=$(fmt_code "$_code")
    [ -z "$_out" ] && _out="$_shown" || _out="$_out $_shown"
    _i=$((_i + 1))
  done
  log_event mint "$_count x $_label"
  printf '%s' "$_out"
}

_voucher_row() {
  "$BB" awk -F'|' -v c="$1" '$1==c {print; exit}' "$VFILE"
}

voucher_set_status() {
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v c="$1" -v st="$2" '$1==c { $6=st } {print}' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
}

voucher_revoke() {
  _code=$(sanitize_code "$1")
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  voucher_set_status "$_code" revoked
  log_event revoke "$_code"
}

voucher_delete() {
  _code=$(sanitize_code "$1")
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  case "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')" in
    active|expired) printf 'kept for audit'; return 1 ;;
  esac
  printf '%s|delete|%s\n' "$(now_epoch)" "$_row" >> "$HFILE"
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v c="$_code" '$1!=c {print}' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  log_event delete "$_code"
}

voucher_unbind() {
  _code=$(sanitize_code "$1")
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  printf '%s|unbind|%s\n' "$(now_epoch)" "$_row" >> "$HFILE"
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v c="$_code" '
    $1==c { $6="new"; $7=""; $8=""; $9=""; $10="" }
    {print}' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  log_event unbind "$_code"
}

voucher_sweep() {
  _now=$(now_epoch)
  _tmp="${VFILE}.sweep.$$"
  _kick="${VFILE}.kick.$$"
  rm -f "$_kick"
  "$BB" awk -F'|' -v OFS='|' -v now="$_now" -v kick="$_kick" '
    NF == 0 { next }
    $6=="active" {
      if ($7 == "") { $6="new"; $8=""; $9=""; $10=""; print; next }
      if ($10 !~ /^[0-9]+$/ || $10+0 <= 0) {
        start = ($9 ~ /^[0-9]+$/ && $9+0 > 0) ? $9+0 : now+0
        if ($9 !~ /^[0-9]+$/ || $9+0 <= 0) $9 = now
        $10 = start + ($3+0)
      }
      if (($10+0) <= (now+0)) { print $7 >> kick; $6="expired" }
    }
    {print}' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  if [ -f "$_kick" ]; then
    "$BB" sed '/^$/d' "$_kick" | "$BB" sort -u
    rm -f "$_kick"
  fi
}

voucher_expire_for_mac() {
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || { printf '0'; return 0; }
  _now=$(now_epoch)
  _tmp="${VFILE}.kickv.$$"; _cnt="${VFILE}.kickn.$$"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v now="$_now" -v cf="$_cnt" '
    $6=="active" && $7==m { $6="expired"; if ($10 !~ /^[0-9]+$/ || $10+0 > now+0) $10=now; n++ }
    {print}
    END { printf "%d", n+0 > cf }' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  _n=$(cat "$_cnt" 2>/dev/null); rm -f "$_cnt"
  printf '%s' "${_n:-0}"
}

rate_allow() {
  _ip=$1; [ -n "$_ip" ] || _ip=unknown
  _safe=$(printf '%s' "$_ip" | "$BB" tr -cd '0-9.')
  [ -n "$_safe" ] || _safe=unknown
  _f="$RNS_DATA/ratelimit/$_safe"
  _now=$(now_epoch); _count=0; _start=$_now
  if [ -f "$_f" ]; then
    _count=$( "$BB" awk '{print $1}' "$_f" )
    _start=$( "$BB" awk '{print $2}' "$_f" )
  fi
  if [ $((_now - _start)) -gt 300 ]; then _count=0; _start=$_now; fi
  [ "$_count" -ge 8 ] && return 1
  _count=$((_count + 1))
  printf '%s %s\n' "$_count" "$_start" > "$_f"
  return 0
}

arp_mac() {
  _ip=$1; _mac=""
  if [ -f /proc/net/arp ]; then
    _mac=$( "$BB" awk -v ip="$_ip" '$1==ip && $4!="00:00:00:00:00:00" {print $4; exit}' /proc/net/arp )
  fi
  sanitize_mac "$_mac"
}

mac_for_ip() {
  _mac=$(arp_mac "$1")
  [ -n "$_mac" ] && { printf '%s' "$_mac"; return 0; }
  if is_lab; then
    printf '02:00:00:00:%s:%s' \
      "$(printf '%s' "$1" | "$BB" awk -F. '{printf "%02x", $3+0}')" \
      "$(printf '%s' "$1" | "$BB" awk -F. '{printf "%02x", $4+0}')"
    return 0
  fi
  return 1
}

client_state() {
  _mac=$(sanitize_mac "$1")
  _state=$("$BB" awk -F'|' -v m="$_mac" '$1==m {print $2; exit}' "$CSTATE" 2>/dev/null)
  [ -n "$_state" ] && printf '%s' "$_state" || printf 'active'
}

client_set_state() {
  _mac=$(sanitize_mac "$1")
  _state=$(printf '%s' "$2" | "$BB" tr -cd 'a-zA-Z')
  case "$_state" in active|kicked|banned) ;; *) printf 'invalid'; return 1 ;; esac
  [ -n "$_mac" ] || { printf 'missing mac'; return 1; }
  _tmp="${CSTATE}.tmp.$$"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" '$1!=m {print}' "$CSTATE" > "$_tmp"
  if [ "$_state" = "active" ]; then mv "$_tmp" "$CSTATE"
  else
    printf '%s|%s|%s\n' "$_mac" "$_state" "$(now_epoch)" >> "$_tmp"
    mv "$_tmp" "$CSTATE"
  fi
  case "$_state" in banned) voucher_expire_for_mac "$_mac" >/dev/null ;; esac
  log_event client_state "$_mac $_state"
}

client_is_blocked() { [ "$(client_state "$1")" = "banned" ]; }
client_is_offline() {
  case "$(client_state "$1")" in kicked|banned) return 0 ;; esac
  return 1
}

client_touch() {
  _mac=$(sanitize_mac "$1"); _ip=$2; _host=$(sanitize_token "$3")
  [ -n "$_mac" ] || return 0
  _now=$(now_epoch); _tmp="${CFILE}.tmp"
  if "$BB" awk -F'|' -v m="$_mac" '$1==m {found=1} END{exit !found}' "$CFILE"; then
    "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v ip="$_ip" -v h="$_host" -v now="$_now" '
      $1==m { if (ip != "") $2=ip; if (h != "") $3=h; $5=now }
      {print}' "$CFILE" > "$_tmp" && mv "$_tmp" "$CFILE"
  else
    printf '%s|%s|%s|%s|%s||||\n' "$_mac" "$_ip" "$_host" "$_now" "$_now" >> "$CFILE"
  fi
}

voucher_redeem() {
  _code=$(sanitize_code "$1"); _ip=$2
  _len=$(printf '%s' "$_code" | "$BB" wc -c | "$BB" tr -d ' ')
  case "$_len" in 8|9|10|11|12) ;; *) printf 'invalid'; return 1 ;; esac
  rate_allow "$_ip" || { printf 'slow'; return 1; }
  _mac=$(mac_for_ip "$_ip") || { printf 'nomac'; return 1; }
  _was_kicked=0
  case "$(client_state "$_mac")" in
    banned) printf 'banned'; return 1 ;;
    kicked) _was_kicked=1 ;;
  esac
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { log_event redeem_fail "bad code"; printf 'invalid'; return 1; }
  _status=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')
  _vmac=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _exp=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $10}')
  _now=$(now_epoch)
  case "$_status" in
    revoked|expired) printf 'invalid'; return 1 ;;
    active)
      if [ "$_vmac" = "$_mac" ] && [ "$_was_kicked" -eq 1 ]; then printf 'kicked'; return 1; fi
      if [ "$_vmac" = "$_mac" ]; then
        client_touch "$_mac" "$_ip" ""
        voucher_set_ip "$_mac" "$_ip"
        printf 'ok|%s|%s|%s|%s|%s' "$_label" "$_exp" "$_down" "$_up" "$_mac"
        return 0
      fi
      printf 'used'; return 1 ;;
    new)
      [ "$_was_kicked" -eq 1 ] && voucher_expire_for_mac "$_mac" >/dev/null
      _exp=$((_now + _sec))
      _tmp="${VFILE}.tmp"
      "$BB" awk -F'|' -v OFS='|' -v c="$_code" -v mac="$_mac" -v ip="$_ip" -v now="$_now" -v ends="$_exp" '
        $1==c { $6="active"; $7=mac; $8=ip; $9=now; $10=ends; print; next }
        {print}' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
      client_touch "$_mac" "$_ip" ""
      if [ "$_was_kicked" -eq 1 ]; then client_set_state "$_mac" active >/dev/null 2>&1 || true; fi
      log_event redeem "$_code -> $_mac"
      printf 'ok|%s|%s|%s|%s|%s' "$_label" "$_exp" "$_down" "$_up" "$_mac"
      return 0 ;;
    *) printf 'invalid'; return 1 ;;
  esac
}

voucher_set_ip() {
  _mac=$(sanitize_mac "$1"); _ip=$(printf '%s' "$2" | "$BB" tr -cd '0-9.')
  [ -n "$_mac" ] && [ -n "$_ip" ] || return 1
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v ip="$_ip" '
    $6=="active" && $7==m && $8 != ip { $8=ip }
    {print}' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
}

voucher_for_mac() {
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 1
  client_is_offline "$_mac" && return 1
  _now=$(now_epoch)
  "$BB" awk -F'|' -v m="$_mac" -v now="$_now" '
    $6=="active" && $7==m && $10 ~ /^[0-9]+$/ && $10+0 > now+0 {print; exit}' "$VFILE"
}

vouchers_json() {
  _filter=$(printf '%s' "$1" | "$BB" tr 'A-Z' 'a-z')
  _search=$(printf '%s' "$2" | "$BB" tr 'A-Z' 'a-z')
  _now=$(now_epoch)
  printf '['
  _first=1
  while IFS='|' read -r code label sec down up status mac ip act exp created note price; do
    [ -n "$code" ] || continue
    _hay=$(printf '%s %s %s %s' "$code" "$label" "$mac" "$ip" | "$BB" tr 'A-Z' 'a-z')
    case "$_filter" in
      ''|all) ;;
      used) [ "$status" = "active" ] || continue ;;
      *) [ "$status" = "$_filter" ] || continue ;;
    esac
    [ -z "$_search" ] || case "$_hay" in *"$_search"*) ;; *) continue ;; esac
    _left=0
    if [ "$status" = "active" ] && [ "$(num "$exp")" -gt 0 ]; then
      _left=$(( $(num "$exp") - _now )); [ "$_left" -lt 0 ] && _left=0
    fi
    _shown=$(fmt_code "$code")
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"code":"%s","display":"%s","plan":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"status":"%s","mac":"%s","ip":"%s","activated":%s,"expires":%s,"created":%s,"note":"%s","price":"%s","left":%s}' \
      "$(json_escape "$code")" "$(json_escape "$_shown")" "$(json_escape "$label")" \
      "$(num "$sec")" "$(num "$down")" "$(num "$up")" "$(json_escape "$status")" \
      "$(json_escape "$mac")" "$(json_escape "$ip")" "$(num "$act")" "$(num "$exp")" \
      "$(num "$created")" "$(json_escape "$note")" "$(json_escape "$(money "$price")")" "$(num "$_left")"
  done < "$VFILE"
  printf ']'
}

clients_json() {
  _now=$(now_epoch)
  printf '['
  _first=1
  while IFS='|' read -r mac ip host first last name phone note voucher; do
    [ -n "$mac" ] || continue
    _online=0
    if [ -n "$last" ] && [ $((_now - last)) -lt 90 ]; then _online=1; fi
    _vrow=$(voucher_for_mac "$mac")
    _state=$(client_state "$mac")
    _st="waiting"
    case "$_state" in banned) _st=banned ;; kicked) _st=kicked ;; *) [ -n "$_vrow" ] && _st=active ;; esac
    _vcode=""; _vplan=""; _vdown=0; _vup=0; _vexp=0
    if [ -n "$_vrow" ]; then
      _vcode=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $1}')
      _vplan=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $2}')
      _vdown=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $4}')
      _vup=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $5}')
      _vexp=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $10}')
    fi
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"mac":"%s","ip":"%s","host":"%s","first":%s,"last":%s,"name":"%s","phone":"%s","note":"%s","voucher":"%s","plan":"%s","down_kbps":%s,"up_kbps":%s,"expires":%s,"online":%s,"state":"%s"}' \
      "$(json_escape "$mac")" "$(json_escape "$ip")" "$(json_escape "$host")" \
      "$(num "$first")" "$(num "$last")" "$(json_escape "$name")" "$(json_escape "$phone")" \
      "$(json_escape "$note")" "$(json_escape "$_vcode")" "$(json_escape "$_vplan")" \
      "$(num "$_vdown")" "$(num "$_vup")" "$(num "$_vexp")" "$_online" "$_st"
  done < "$CFILE"
  printf ']'
}

count_status() {
  "$BB" awk -F'|' -v s="$1" '$6==s {n++} END{print n+0}' "$VFILE"
}

overview_json() {
  _now=$(now_epoch)
  _active=$(count_status active)
  _new=$(count_status new)
  _expired=$(count_status expired)
  _revoked=$(count_status revoked)
  _waiting=0; _online=0
  while IFS='|' read -r mac ip host first last name phone note voucher; do
    [ -n "$mac" ] || continue
    if [ -n "$last" ] && [ $((_now - last)) -lt 90 ]; then
      if [ -n "$(voucher_for_mac "$mac")" ]; then _online=$((_online + 1))
      else _waiting=$((_waiting + 1)); fi
    fi
  done < "$CFILE"
  printf '{"active":%s,"unused":%s,"expired":%s,"revoked":%s,"online":%s,"waiting":%s}' \
    "$_active" "$_new" "$_expired" "$_revoked" "$_online" "$_waiting"
}

sales_report() {
  _from=$(num "$1" 0); _to=$(num "$2" 0)
  [ "$_to" -gt "$_from" ] || _to=$((_from + 86400))
  _off=$(utc_offset_seconds)
  "$BB" awk -F'|' -v from="$_from" -v to="$_to" -v off="$_off" '
    function fdiv(a,b){ q=int(a/b); if (a%b!=0 && ((a<0)!=(b<0))) q--; return q }
    function ymd(ts,   local,days,z,era,doe,yoe,y,doy,mp,d,m) {
      local = ts + off;
      days = fdiv(local, 86400);
      z = days + 719468;
      era = fdiv((z>=0) ? z : z-146096, 146097);
      doe = z - era*146097;
      yoe = fdiv(doe - int(doe/1460) + int(doe/36524) - int(doe/146096), 365);
      y = yoe + era*400;
      doy = doe - (365*yoe + int(yoe/4) - int(yoe/100));
      mp = int((5*doy + 2)/153);
      d = doy - int((153*mp+2)/5) + 1;
      m = mp + ((mp<10) ? 3 : -9);
      y = y + ((m<=2) ? 1 : 0);
      return sprintf("%04d-%02d-%02d", y, m, d);
    }
    function paisa(s,   a,ip,fr) {
      if (s == "" || s !~ /^[0-9]*\.?[0-9]*$/) return 0;
      if (index(s,".") > 0) { split(s,a,"."); ip=a[1]; fr=substr(a[2] "00",1,2) }
      else { ip=s; fr="00" }
      gsub(/^0+/,"",ip); if (ip=="") ip="0";
      return (ip*100) + (fr+0);
    }
    NF == 0 { next }
    {
      label=$2; created=$11; price=$13;
      if (created !~ /^[0-9]+$/) created="";
      if (created != "" && created+0 >= from+0 && created+0 < to+0) {
        m_count++; m_paisa += paisa(price);
        d=ymd(created+0); dm[d]++;
      }
    }
    END {
      printf "T|%d|%d|%d\n", m_count+0, 0, m_paisa+0;
    }' "$VFILE"
}

events_json() {
  "$BB" tail -n 40 "$EVENTS_FILE" 2>/dev/null | "$BB" awk -F'|' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    BEGIN { printf "["; comma="" }
    $1 ~ /^[0-9]+$/ {
      printf "%s{\"t\":%s,\"action\":\"%s\",\"detail\":\"%s\"}", comma, $1, esc($2), esc($3)
      comma=","
    }
    END { printf "]" }'
}

active_macs() {
  _now=$(now_epoch)
  while IFS='|' read -r _code _label _sec _down _up _status _mac _ip _act _exp _created _note _price; do
    [ "$_status" = "active" ] && [ -n "$_mac" ] || continue
    _exp=$(num "$_exp")
    [ "$_exp" -gt "$_now" ] || continue
    client_is_offline "$_mac" && continue
    printf '%s|%s|%s|%s\n' "$_mac" "$_ip" "$_down" "$_up"
  done < "$VFILE"
}

sanitize_tid() {
  printf '%s' "$1" | "$BB" tr 'a-z' 'A-Z' | "$BB" tr -cd 'A-Z0-9-' | "$BB" cut -c1-32
}
