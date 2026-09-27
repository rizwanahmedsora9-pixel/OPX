# Voucher, session, and client store. Flat files, no SQLite.

. "$RNS_HOME/bin/common.sh"

VFILE="$RNS_DB_DIR/vouchers.tsv"
CFILE="$RNS_DB_DIR/clients.tsv"
AFILE="$RNS_DB_DIR/admin.auth"
PFILE="$RNS_DB_DIR/packages.tsv"
CSTATE="$RNS_DB_DIR/client-states.tsv"
HFILE="$RNS_DB_DIR/voucher-history.tsv"
# Online (captive-portal) packages are deliberately separate from counter
# packages: a shop can sell a 3-hour counter bundle and a cheaper 1-hour
# student bundle online at the same time.
OPKGFILE="$RNS_DB_DIR/online-packages.tsv"
# Payments raised by the Buy Online flow, plus the short-lived references the
# portal hands a customer so staff can match a wallet transfer to a device.
PAYFILE="$RNS_DB_DIR/payments.tsv"
REFFILE="$RNS_DB_DIR/pay-refs.tsv"

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
  [ -f "$OPKGFILE" ] || printf '' > "$OPKGFILE"
  [ -f "$PAYFILE" ] || printf '' > "$PAYFILE"
  [ -f "$REFFILE" ] || printf '' > "$REFFILE"
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
ONLINE_PAY=1
PAY_AUTO_VERIFY=0
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
  [ "$(_hash_pass "$_salt" "$1")" = "$_want" ] && return 0
  if is_lab && [ "$1" = "$(cfg_get LAB_PASS rns-lab)" ]; then return 0; fi
  return 1
}

# The lab password above is a preview convenience, not a credential: it works
# only while RNS_LAB=1, which no boot script sets. /api/status reports it so
# the lab banner can tell a demo user how to get in.
lab_pass() { cfg_get LAB_PASS rns-lab; }

# A voucher a lab user can actually redeem: the oldest unused one, or "-".
lab_sample_code() {
  "$BB" awk -F'|' '$6=="new" {print $1; exit}' "$VFILE" 2>/dev/null
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
  _rate=$(money "$7")
  _ru=$8
  case "$_ru" in day|hour) ;; *) _ru='' ;; esac
  [ -n "$_id" ] && [ -n "$_label" ] && [ -n "$_sec" ] && [ -n "$_down" ] && [ -n "$_up" ] || {
    printf 'package requires id, name, duration and speeds'; return 1; }
  _tmp="${PFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v id="$_id" '$1 != id {print}' "$PFILE" > "$_tmp"
  printf '%s|%s|%s|%s|%s|%s|active|%s|%s\n' \
    "$_id" "$_label" "$_sec" "$_down" "$_up" "$_price" "$_rate" "$_ru" >> "$_tmp"
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
  while IFS='|' read -r id label sec down up price state rate rate_unit; do
    [ -n "$id" ] && [ "$state" != "disabled" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"id":"%s","label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"price":"%s","rate":"%s","rate_unit":"%s"}' \
      "$(json_escape "$id")" "$(json_escape "$label")" "$(num "$sec")" \
      "$(num "$down")" "$(num "$up")" "$(json_escape "$(money "$price")")" \
      "$(json_escape "$(money "$rate")")" "$(json_escape "$rate_unit")"
  done < "$PFILE"
  printf ']'
}

_rand_code() {
  "$BB" od -An -N4 -tx1 /dev/urandom | "$BB" tr -d ' \n' | "$BB" cut -c1-8 | "$BB" tr 'a-f' 'A-F'
}

# One unused 8-character code. Retries rather than handing out a duplicate,
# which would silently hand a second customer someone else's voucher.
_new_code() {
  _i=0
  while [ "$_i" -lt 50 ]; do
    _c=$(_rand_code)
    _code_exists "$_c" || { printf '%s' "$_c"; return 0; }
    _i=$((_i + 1))
  done
  return 1
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
    _code=$(_new_code) || { printf 'could not allocate a code'; return 1; }
    printf '%s|%s|%s|%s|%s|new|||||%s|%s|%s\n' \
      "$_code" "$_label" "$_sec" "$_down" "$_up" "$_now" "$_note" "$_price" >> "$VFILE"
    _shown=$(fmt_code "$_code")
    [ -z "$_out" ] && _out="$_shown" || _out="$_out $_shown"
    _i=$((_i + 1))
  done
  log_event mint "$_count x $_label"
  printf '%s' "$_out"
}

# A package row from either list: "online" for the captive-portal Buy Online
# flow, anything else for the counter packages the Sell tab uses.
_pkg_row_of() {
  case "$1" in
    online) online_package_row "$2" ;;
    *) package_row "$2" ;;
  esac
}

# Mint a voucher that is already bound to one device — the online payment
# path needs this, because the customer never types a code. The fourth
# argument selects which package list the plan lives in.
# Returns "ok|code|label|expires|down|up" or an error string.
voucher_mint_bound() {
  _plan=$1; _mac=$(sanitize_mac "$2"); _ip=$3; _src=${4:-counter}
  _row=$(_pkg_row_of "$_src" "$_plan")
  [ -n "$_row" ] || { printf 'unknown package'; return 1; }
  [ -n "$_mac" ] || { printf 'no device'; return 1; }
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _price=$(money "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')")
  _code=$(_new_code) || { printf 'could not allocate a code'; return 1; }
  _now=$(now_epoch); _exp=$((_now + _sec))
  # created (11) is set so an online sale shows up in the sales report on the
  # day it was paid for, and the price belongs in 13, not in the note column.
  printf '%s|%s|%s|%s|%s|active|%s|%s|%s|%s|%s|%s|%s\n' \
    "$_code" "$_label" "$_sec" "$_down" "$_up" "$_mac" "$_ip" "$_now" "$_exp" \
    "$_now" "online" "$_price" >> "$VFILE"
  client_touch "$_mac" "$_ip" ""
  log_event mint_online "$_code to $_mac"
  printf 'ok|%s|%s|%s|%s|%s' "$_code" "$_label" "$_exp" "$_down" "$_up"
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

# Sales report for a [from,to) epoch window, shared by the JSON endpoint the
# admin Sales tab renders and the CSV export. fmt is "json" or "csv".
#
#   vouchers.tsv columns:
#     1 code  2 label  3 sec  4 down  5 up  6 status  7 mac  8 ip
#     9 activated  10 expires  11 created  12 note  13 price
sales_data() {
  _from=$(num "$1" 0); _to=$(num "$2" 0); _fmt=$3
  [ "$_to" -gt "$_from" ] || _to=$((_from + 86400))
  _off=$(utc_offset_seconds)
  "$BB" awk -F'|' -v from="$_from" -v to="$_to" -v off="$_off" -v fmt="$_fmt" '
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
    # Paisa, or -1 when the price is missing/unusable, so the caller can both
    # skip the money and still report how many codes were unpriced.
    function paisa(s,   ip,fr) {
      if (s == "" || s !~ /^[0-9]+(\.[0-9]*)?$/) return -1;
      if (index(s,".") > 0) {
        ip = substr(s, 1, index(s,".")-1);
        fr = substr(s, index(s,".")+1) "00";
      } else { ip = s; fr = "00" }
      gsub(/^0+/,"",ip); if (ip=="") ip="0";
      return (ip*100) + (fr+0);
    }
    function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
    function rs(p) { return sprintf("%d.%02d", int(p/100), p%100) }
    function csvq(s) {
      if (s ~ /[",\r\n]/) { gsub(/"/,"\"\"",s); return "\"" s "\"" }
      return s
    }
    function isort(arr, n,   i,j,t) {
      for (i=2;i<=n;i++){ t=arr[i]; j=i-1; while (j>=1 && arr[j] > t){ arr[j+1]=arr[j]; j-- } arr[j+1]=t }
    }
    NF == 0 { next }
    {
      label=$2; created=$11; act=$9; status=$6; price=$13;
      p = paisa(price);
      if (created !~ /^[0-9]+$/) { undated++ }
      else if (created+0 >= from+0 && created+0 < to+0) {
        m_count++; m_paisa += (p<0?0:p); if (p<0) unpriced++;
        d = ymd(created+0); dm[d]++; dmr[d] += (p<0?0:p);
        dp[label]++; dpr[label] += (p<0?0:p);
      }
      if (act ~ /^[0-9]+$/ && act+0 > 0 && status != "new" \
          && act+0 >= from+0 && act+0 < to+0) {
        r_count++; r_paisa += (p<0?0:p); if (p<0) unpriced++;
        d = ymd(act+0); dr[d]++; drr[d] += (p<0?0:p);
        rp[label]++; rpr[label] += (p<0?0:p);
      }
    }
    END {
      nd=0; for (k in dm) days[++nd]=k; for (k in dr) if (!(k in dm)) days[++nd]=k;
      isort(days,nd);
      np=0; for (k in dp) pkgs[++np]=k; for (k in rp) if (!(k in dp)) pkgs[++np]=k;
      isort(pkgs,np);
      if (fmt == "csv") {
        print "section,key,generated,redeemed,generated_rs,redeemed_rs";
        for (i=1;i<=nd;i++) {
          k=days[i];
          print "day," csvq(k) "," dm[k]+0 "," dr[k]+0 "," rs(dmr[k]+0) "," rs(drr[k]+0);
        }
        for (i=1;i<=np;i++) {
          k=pkgs[i];
          print "package," csvq(k) "," dp[k]+0 "," rp[k]+0 "," rs(dpr[k]+0) "," rs(rpr[k]+0);
        }
        print "total,," m_count+0 "," r_count+0 "," rs(m_paisa+0) "," rs(r_paisa+0);
      } else {
        printf "{\"totals\":{\"minted\":%d,\"minted_revenue\":\"%s\",", m_count+0, rs(m_paisa+0);
        printf "\"redeemed\":%d,\"redeemed_revenue\":\"%s\",", r_count+0, rs(r_paisa+0);
        printf "\"unpriced\":%d,\"undated\":%d},", unpriced+0, undated+0;
        printf "\"by_day\":[";
        for (i=1;i<=nd;i++) {
          k=days[i];
          if (i>1) printf ",";
          printf "{\"day\":\"%s\",\"minted\":%d,\"redeemed\":%d,\"revenue\":\"%s\",\"redeemed_revenue\":\"%s\"}", \
            esc(k), dm[k]+0, dr[k]+0, rs(dmr[k]+0), rs(drr[k]+0);
        }
        printf "],\"by_package\":[";
        for (i=1;i<=np;i++) {
          k=pkgs[i];
          if (i>1) printf ",";
          printf "{\"label\":\"%s\",\"minted\":%d,\"redeemed\":%d,\"revenue\":\"%s\",\"redeemed_revenue\":\"%s\"}", \
            esc(k), dp[k]+0, rp[k]+0, rs(dpr[k]+0), rs(rpr[k]+0);
        }
        printf "]}";
      }
    }' "$VFILE"
}

sales_json() { sales_data "$1" "$2" json; }
sales_csv()  { sales_data "$1" "$2" csv; }

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

# ------------------------------------------------------------------ settings
# Wallet / online-payment settings. A wallet number is the only switch: no
# number configured means Buy Online stays hidden on the captive portal, so
# an operator who does not take mobile-money payments never sees the feature.
wallet_number() {
  case "$1" in
    jazzcash)  cfg_get JAZZCASH_NUMBER '' ;;
    easypaisa) cfg_get EASYPAISA_NUMBER '' ;;
    *) printf '' ;;
  esac
}

online_pay_on() {
  [ "$(cfg_get ONLINE_PAY 1)" = "1" ] || return 1
  [ -n "$(cfg_get JAZZCASH_NUMBER '')" ] || [ -n "$(cfg_get EASYPAISA_NUMBER '')" ]
}

sanitize_wallet() {
  printf '%s' "$1" | "$BB" tr -cd '0-9-' | "$BB" cut -c1-20
}

sanitize_flag() {
  case "$1" in 1|on|yes|true) printf '1' ;; *) printf '0' ;; esac
}

# --------------------------------------------------------- online packages
# id|label|seconds|down|up|price|state|rate|rate_unit
online_package_upsert() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _label=$(sanitize_token "$2")
  _sec=$(printf '%s' "$3" | "$BB" tr -cd '0-9')
  _down=$(printf '%s' "$4" | "$BB" tr -cd '0-9')
  _up=$(printf '%s' "$5" | "$BB" tr -cd '0-9')
  _price=$(money "$6")
  _rate=$(money "$7")
  _ru=$8
  case "$_ru" in day|hour) ;; *) _ru='' ;; esac
  [ -n "$_id" ] && [ -n "$_label" ] && [ -n "$_sec" ] && [ -n "$_down" ] && [ -n "$_up" ] || {
    printf 'online package requires id, name, duration and speeds'; return 1; }
  [ -n "$_price" ] || { printf 'online package requires a price'; return 1; }
  _tmp="${OPKGFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v id="$_id" '$1 != id {print}' "$OPKGFILE" > "$_tmp"
  printf '%s|%s|%s|%s|%s|%s|active|%s|%s\n' \
    "$_id" "$_label" "$_sec" "$_down" "$_up" "$_price" "$_rate" "$_ru" >> "$_tmp"
  mv "$_tmp" "$OPKGFILE"
  log_event online_package "$_id $_label"
}

online_package_row() {
  "$BB" awk -F'|' -v id="$1" '$1==id && ($7=="" || $7=="active") {print; exit}' "$OPKGFILE"
}

online_package_delete() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  [ -n "$_id" ] || { printf 'missing id'; return 1; }
  _row=$(online_package_row "$_id")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  _tmp="${OPKGFILE}.tmp"
  "$BB" awk -F'|' -v id="$_id" '$1 != id {print}' "$OPKGFILE" > "$_tmp"
  mv "$_tmp" "$OPKGFILE"
  printf 'deleted'
}

online_packages_json() {
  printf '['
  _first=1
  while IFS='|' read -r id label sec down up price state rate rate_unit; do
    [ -n "$id" ] && [ "$state" != "disabled" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"id":"%s","label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"price":"%s","rate":"%s","rate_unit":"%s"}' \
      "$(json_escape "$id")" "$(json_escape "$label")" "$(num "$sec")" \
      "$(num "$down")" "$(num "$up")" "$(json_escape "$(money "$price")")" \
      "$(json_escape "$(money "$rate")")" "$(json_escape "$rate_unit")"
  done < "$OPKGFILE"
  printf ']'
}

# ------------------------------------------------- online payments (Buy Online)
# pay_id|ref|mac|ip|package_id|package_label|seconds|down|up|method|tid|amount|
# status|created|updated|note|voucher_code
pay_init() {
  _pkg=$1; _method=$2; _mac=$(sanitize_mac "$3"); _ip=$4
  case "$_method" in jazzcash|easypaisa) ;; *) printf 'bad method'; return 1 ;; esac
  [ -n "$(wallet_number "$_method")" ] || { printf 'no wallet number for that method'; return 1; }
  _row=$(online_package_row "$_pkg")
  [ -n "$_row" ] || { printf 'unknown package'; return 1; }
  [ -n "$_mac" ] || { printf 'no device'; return 1; }
  case "$(client_state "$_mac")" in banned) printf 'banned'; return 1 ;; esac

  _now=$(now_epoch)
  # Drop references that were never submitted, so the file cannot grow forever.
  _tmp="${REFFILE}.tmp"
  "$BB" awk -F'|' -v now="$_now" -v ttl=7200 \
    'NF && $6 ~ /^[0-9]+$/ && $6+0 > now-ttl {print}' "$REFFILE" > "$_tmp" 2>/dev/null
  mv "$_tmp" "$REFFILE" 2>/dev/null

  _ref=""; _try=0
  while [ "$_try" -lt 20 ]; do
    _ref=$(rand_token 8)
    "$BB" awk -F'|' -v r="$_ref" '$2==r {f=1} END{exit !f}' "$REFFILE" 2>/dev/null || break
    _try=$((_try + 1))
  done
  [ -n "$_ref" ] || { printf 'could not allocate a reference'; return 1; }
  _exp=$((_now + 7200))
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$_ref" "$_pkg" "$_method" "$_mac" "$_ip" "$_now" "$_exp" >> "$REFFILE"
  log_event pay_init "$_ref $_pkg $_method"
  printf '%s' "$_ref"
}

# Look up a live reference and consume it. Returns the package id on stdout.
pay_ref_take() {
  _ref=$1; _mac=$2
  _now=$(now_epoch)
  _row=$("$BB" awk -F'|' -v r="$_ref" -v now="$_now" -v m="$_mac" '
    $1==r && $7 ~ /^[0-9]+$/ && $7+0 > now && $4==m {print; exit}' "$REFFILE" 2>/dev/null)
  [ -n "$_row" ] || return 1
  _tmp="${REFFILE}.tmp"
  "$BB" awk -F'|' -v r="$_ref" '$1 != r {print}' "$REFFILE" > "$_tmp" && mv "$_tmp" "$REFFILE"
  printf '%s' "$_row"
}

# Auto-verify is deliberately honest about what it can and cannot check: the
# gateway has no API into JazzCash or EasyPaisa, so "verified" means the
# tracking ID is one we issued, the TID is well formed, the amount matches
# the package price and the device is not banned. A staff member still sees
# every payment in the Payments tab and can reject a bad one.
pay_autoverify_on() { [ "$(cfg_get PAY_AUTO_VERIFY 0)" = "1" ]; }

# Returns "ok|status|pay_id|voucher_code|expires|down|up" or an error string.
pay_submit() {
  _ref=$1; _tid=$(sanitize_tid "$2"); _mac=$(sanitize_mac "$3"); _ip=$4
  [ -n "$_ref" ] || { printf 'missing ref'; return 1; }
  [ ${#_tid} -ge 6 ] || { printf 'tid too short'; return 1; }
  _rrow=$(pay_ref_take "$_ref" "$_mac") || { printf 'unknown ref'; return 1; }
  _pkg=$(printf '%s' "$_rrow" | "$BB" awk -F'|' '{print $2}')
  _method=$(printf '%s' "$_rrow" | "$BB" awk -F'|' '{print $3}')
  _row=$(online_package_row "$_pkg")
  [ -n "$_row" ] || { printf 'unknown package'; return 1; }
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _price=$(money "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')")

  _payid=$(rand_token 12)
  _now=$(now_epoch)
  _status=pending
  _vcode=""
  if pay_autoverify_on; then
    _res=$(voucher_mint_bound "$_pkg" "$_mac" "$_ip" online) || { printf '%s' "$_res"; return 1; }
    _vcode=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
    _status=confirmed
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s||%s\n' \
    "$_payid" "$_ref" "$_mac" "$_ip" "$_pkg" "$_label" "$_sec" "$_down" "$_up" \
    "$_method" "$_tid" "$_price" "$_status" "$_now" "$_now" "$_vcode" >> "$PAYFILE"
  log_event pay_submit "$_payid $_tid $_status"
  if [ "$_status" = "confirmed" ]; then
    printf 'ok|confirmed|%s|%s|%s|%s|%s' "$_payid" "$_vcode" "$((_now + _sec))" "$_down" "$_up"
  else
    printf 'ok|pending|%s||||' "$_payid"
  fi
}

pay_row() {
  "$BB" awk -F'|' -v id="$1" '$1==id {print; exit}' "$PAYFILE" 2>/dev/null
}

# pay_id|ref|mac|ip|package_id|package_label|seconds|down|up|method|tid|amount|
# status|created|updated|note|voucher_code
pay_set_status() {
  _id=$1; _st=$2; _note=$3; _vcode=$4
  _tmp="${PAYFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v id="$_id" -v st="$_st" -v note="$_note" -v vc="$_vcode" \
    -v now="$(now_epoch)" '
    $1==id { $13=st; $15=now; if (note != "") $16=note; if (vc != "") $17=vc }
    {print}' "$PAYFILE" > "$_tmp" && mv "$_tmp" "$PAYFILE"
}

# Staff confirms a payment: bind a voucher to the customer's device right now.
# Returns "ok|voucher_code|expires|down|up".
pay_confirm() {
  _id=$1
  _row=$(pay_row "$_id")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  _st=$(printf '%s' "$_row" | "$BB" cut -d'|' -f13)
  case "$_st" in
    confirmed) printf 'already confirmed'; return 1 ;;
    rejected) printf 'already rejected'; return 1 ;;
  esac
  _mac=$(printf '%s' "$_row" | "$BB" cut -d'|' -f3)
  _ip=$(printf '%s' "$_row" | "$BB" cut -d'|' -f4)
  _pkg=$(printf '%s' "$_row" | "$BB" cut -d'|' -f5)
  case "$(client_state "$_mac")" in banned) printf 'device is banned'; return 1 ;; esac
  _res=$(voucher_mint_bound "$_pkg" "$_mac" "$_ip" online) || { printf '%s' "$_res"; return 1; }
  _vcode=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
  _exp=$(printf '%s' "$_res" | "$BB" cut -d'|' -f4)
  _down=$(printf '%s' "$_res" | "$BB" cut -d'|' -f5)
  _up=$(printf '%s' "$_res" | "$BB" cut -d'|' -f6)
  pay_set_status "$_id" confirmed '' "$_vcode"
  log_event pay_confirm "$_id $_vcode"
  printf 'ok|%s|%s|%s|%s' "$_vcode" "$_exp" "$_down" "$_up"
}

pay_reject() {
  _id=$1; _note=$(sanitize_token "$2")
  _row=$(pay_row "$_id")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  _st=$(printf '%s' "$_row" | "$BB" cut -d'|' -f13)
  case "$_st" in
    confirmed) printf 'already confirmed'; return 1 ;;
    rejected) printf 'already rejected'; return 1 ;;
  esac
  pay_set_status "$_id" rejected "$_note" ''
  log_event pay_reject "$_id $_note"
  printf 'ok'
}

payments_json() {
  _now=$(now_epoch)
  printf '['
  _first=1
  # Newest first: staff work the queue from the top. Piped rather than
  # redirected, because < "$(...)" would hand awk's output to the shell as a
  # file name and the list would come back empty.
  "$BB" awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) if (a[i] != "") print a[i]}' \
    "$PAYFILE" 2>/dev/null \
    | while IFS='|' read -r payid ref mac ip pkg label sec down up method tid amount \
                             status created updated note vcode; do
    [ -n "$payid" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    _left=0
    if [ "$status" = "confirmed" ] && [ -n "$_vcode" ]; then
      _vrow=$(_voucher_row "$_vcode")
      [ -n "$_vrow" ] || _vrow=""
      _vexp=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $10}')
      if [ "$(num "$_vexp")" -gt "$_now" ]; then _left=$(( $(num "$_vexp") - _now )); fi
    fi
    printf '{"pay_id":"%s","ref":"%s","mac":"%s","ip":"%s","package_id":"%s","package_label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"method":"%s","tid":"%s","amount":"%s","status":"%s","created":%s,"updated":%s,"note":"%s","voucher_code":"%s","left":%s}' \
      "$(json_escape "$payid")" "$(json_escape "$ref")" "$(json_escape "$mac")" \
      "$(json_escape "$ip")" "$(json_escape "$pkg")" "$(json_escape "$label")" \
      "$(num "$sec")" "$(num "$down")" "$(num "$up")" "$(json_escape "$method")" \
      "$(json_escape "$tid")" "$(json_escape "$(money "$amount")")" "$(json_escape "$status")" \
      "$(num "$created")" "$(num "$updated")" "$(json_escape "$note")" \
      "$(json_escape "$vcode")" "$(num "$_left")"
  done
  printf ']'
}

# -------------------------------------------------------------------- backup
# A dated snapshot of the database plus the running config. tar is a busybox
# applet, so this needs no extra package; gzip is used when it is there.
backup_create() {
  _stamp=$("$BB" date '+%Y%m%d-%H%M%S' 2>/dev/null || now_epoch)
  _base="$RNS_DATA/backups/rns-$_stamp"
  _dst=""
  if command -v tar >/dev/null 2>&1; then
    tar cf "$_base.tar" -C "$RNS_DATA" database config.env 2>/dev/null
    [ -s "$_base.tar" ] && _dst="$_base.tar"
  fi
  if [ -z "$_dst" ]; then
    mkdir -p "$_base" 2>/dev/null
    cp -a "$RNS_DB_DIR" "$_base/database" 2>/dev/null
    [ -f "$RNS_DATA/config.env" ] && cp -a "$RNS_DATA/config.env" "$_base/config.env" 2>/dev/null
    [ -d "$_base/database" ] && _dst="$_base"
  fi
  [ -n "$_dst" ] || { printf 'could not write the backup'; return 1; }
  if [ -f "$_dst" ] && command -v gzip >/dev/null 2>&1; then
    if gzip -f "$_dst" 2>/dev/null && [ -s "${_dst}.gz" ]; then _dst="${_dst}.gz"; fi
  fi
  # Keep the newest handful and drop the rest, so /data cannot fill up.
  _n=0
  for _f in $(ls -1t "$RNS_DATA/backups"/rns-* 2>/dev/null); do
    _n=$((_n + 1))
    [ "$_n" -gt 8 ] && rm -f "$_f"
  done
  log_event backup "${_dst##*/}"
  printf '%s' "$_dst"
}
