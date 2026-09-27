# Shared helpers for the RNS gateway.
# Busybox ash and mksh.

if [ -z "$BB" ]; then
  if [ -x /bin/busybox ]; then BB=/bin/busybox
  elif [ -x /usr/bin/busybox ]; then BB=/usr/bin/busybox
  else BB=busybox; fi
fi
export BB

if [ -z "$RNS_HOME" ]; then RNS_HOME=/usr/share/rns; fi
if [ -z "$RNS_DATA" ]; then RNS_DATA=/data/rns; fi
RNS_WWW="$RNS_HOME/www"
RNS_DB_DIR="$RNS_DATA/database"
RNS_LOG_DIR="$RNS_DATA/logs"
EVENTS_FILE="$RNS_LOG_DIR/events.log"
LOG="$RNS_LOG_DIR/rns.log"
MIRROR_LOG=/tmp/rns_hotspot.log

now_epoch() {
  "$BB" date +%s 2>/dev/null || date +%s
}

log_line() {
  _msg="$1"
  _ts=$(now_epoch)
  mkdir -p "$RNS_DATA" 2>/dev/null
  printf '%s %s\n' "$_ts" "$_msg" >> "$LOG" 2>/dev/null
  printf '%s %s\n' "$_ts" "$_msg" >> "$MIRROR_LOG" 2>/dev/null
}

_date_human() {
  "$BB" date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

log_event() {
  mkdir -p "$RNS_DATA" 2>/dev/null
  _d=$(printf '%s' "$2" | "$BB" tr '\t\r\n|' '    ')
  mkdir -p "$RNS_LOG_DIR" 2>/dev/null
  printf '%s|%s|%s\n' "$(now_epoch)" "$1" "$_d" >> "$EVENTS_FILE"
  log_line "$1 $_d"
}

json_escape() {
  printf '%s' "$1" | "$BB" sed 's/\\/\\\\/g; s/"/\\"/g' | "$BB" tr -d '\r\n\t'
}

sanitize_token() {
  printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9 .:_@+-#' | "$BB" cut -c1-64
}

sanitize_code() {
  printf '%s' "$1" | "$BB" tr 'a-z' 'A-Z' | "$BB" tr -cd 'A-Z0-9' | "$BB" cut -c1-12
}

sanitize_mac() {
  printf '%s' "$1" | "$BB" tr 'A-F' 'a-f' | "$BB" sed 's/[^0-9a-f:]//g' | "$BB" cut -c1-17
}

# Normalise an address to dotted IPv4. Accepts plain IPv4 and the
# IPv4-mapped form socat/httpd can hand us (::ffff:1.2.3.4). Prints
# nothing when the input is not a usable IPv4 address, so callers can
# test with [ -n ... ] instead of trusting the raw value.
ipv4_norm() {
  _s=$(printf '%s' "$1" | "$BB" tr -d '[] \t\r\n')
  _s=$(printf '%s' "$_s" | "$BB" sed 's/^::[fF][fF][fF][fF]://')
  printf '%s' "$_s" | "$BB" awk -F. '
    NF == 4 {
      ok = 1
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/)      { ok = 0; break }
        if (length($i) > 3)        { ok = 0; break }
        if (length($i) > 1 && substr($i,1,1) == "0") { ok = 0; break }
        if ($i + 0 > 255)          { ok = 0; break }
      }
      if (ok) printf "%d.%d.%d.%d", $1+0, $2+0, $3+0, $4+0
    }'
}

# Where did this request come from? Every listener we support publishes the
# peer address in the environment: socat sets SOCAT_PEERADDR, busybox httpd
# sets REMOTE_ADDR, ucspi-style servers set TCPREMOTEIP. RNS_CLIENT_IP is an
# explicit override for tests and for the nc fallback, which cannot see the
# peer at all.
resolve_client_ip() {
  _ip=""
  for _v in "${CLIENT_IP:-}" "${SOCAT_PEERADDR:-}" "${REMOTE_ADDR:-}" \
            "${TCPREMOTEIP:-}" "${RNS_CLIENT_IP:-}"; do
    [ -n "$_v" ] || continue
    _ip=$(ipv4_norm "$_v")
    [ -n "$_ip" ] && break
  done
  printf '%s' "$_ip"
}

hex_byte() {
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f]) "$BB" printf "\\x$1" ;;
    *) printf '?' ;;
  esac
}

urldecode() {
  _s=$(printf '%s' "$1" | "$BB" sed 's/+/ /g')
  _out=""
  while [ -n "$_s" ]; do
    case "$_s" in
      %??*)
        _hh=$(printf '%s' "$_s" | "$BB" cut -c2-3)
        _ch=$(hex_byte "$_hh" 2>/dev/null) || _ch="?"
        _out="$_out$_ch"
        _s=$(printf '%s' "$_s" | "$BB" cut -c4-)
        ;;
      *)
        _c=$(printf '%s' "$_s" | "$BB" cut -c1)
        _out="$_out$_c"
        _s=$(printf '%s' "$_s" | "$BB" cut -c2-)
        ;;
    esac
  done
  printf '%s' "$_out"
}

form_get() {
  _key=$1
  _blob="${RNS_QUERY}&${RNS_BODY}"
  _raw=$(printf '%s' "$_blob" | "$BB" tr '&' '\n' | "$BB" sed -n "s/^${_key}=//p" | "$BB" head -n 1)
  urldecode "$_raw"
}

cfg_path() { printf '%s/config.env' "$RNS_DATA"; }

cfg_get() {
  _k=$1; _def=$2; _f=$(cfg_path); _v=""
  if [ -f "$_f" ]; then
    _v=$( "$BB" sed -n "s/^${_k}=//p" "$_f" | "$BB" head -n 1 | "$BB" tr -d '\r' )
  fi
  if [ -z "$_v" ]; then printf '%s' "$_def"; else printf '%s' "$_v"; fi
}

cfg_set() {
  _k=$1; _v=$2; _f=$(cfg_path)
  mkdir -p "$RNS_DATA"
  touch "$_f"
  if "$BB" grep -q "^${_k}=" "$_f" 2>/dev/null; then
    _tmp="${_f}.tmp"
    "$BB" sed "s|^${_k}=.*|${_k}=${_v}|" "$_f" > "$_tmp" && mv "$_tmp" "$_f"
  else
    printf '%s=%s\n' "$_k" "$_v" >> "$_f"
  fi
}

with_lock() {
  mkdir -p "$RNS_DATA"
  if [ "${RNS_LOCK_DEPTH:-0}" -gt 0 ]; then
    "$@"
    return $?
  fi
  exec 9>>"$RNS_DATA/store.lock"
  "$BB" flock -x 9
  RNS_LOCK_DEPTH=1
  "$@"
  _rc=$?
  RNS_LOCK_DEPTH=0
  "$BB" flock -u 9
  return $_rc
}

is_lab() { [ "$RNS_LAB" = "1" ]; }

phone_ips() {
  {
    if command -v ip >/dev/null 2>&1; then
      ip -4 -o addr show 2>/dev/null | "$BB" awk '{print $4}' | "$BB" cut -d/ -f1
    fi
    printf '%s\n' 127.0.0.1
  } | "$BB" sort -u
}

is_local_ip() {
  _ip=$1
  if is_lab; then return 0; fi
  case "$_ip" in 127.*|::1) return 0 ;; "" ) return 1 ;; esac
  if [ "$(cfg_get ADMIN_LAN 0)" = "1" ]; then return 0; fi
  phone_ips | "$BB" grep -qx "$_ip"
}

le_hex_to_ip() {
  _h=$1
  _b1=$(printf '%s' "$_h" | "$BB" cut -c7-8)
  _b2=$(printf '%s' "$_h" | "$BB" cut -c5-6)
  _b3=$(printf '%s' "$_h" | "$BB" cut -c3-4)
  _b4=$(printf '%s' "$_h" | "$BB" cut -c1-2)
  printf '%d.%d.%d.%d' "0x$_b1" "0x$_b2" "0x$_b3" "0x$_b4"
}

num() {
  _v=$(printf '%s' "$1" | "$BB" tr -cd '0-9')
  [ -n "$_v" ] || _v=${2:-0}
  printf '%s' "$_v"
}

money() {
  _m=$(printf '%s' "$1" | "$BB" tr -cd '0-9.')
  case "$_m" in
    ''|*[!0-9.]*|.) printf ''; return 0 ;;
  esac
  printf '%s' "$_m" | "$BB" awk '{
    s=$0; n=split(s,p,".");
    out=p[1];
    if (n>1) { frac=substr(p[2],1,2); if (frac!="") out=out "." frac }
    gsub(/^0+/,"",out); if (out=="" || out ~ /^\./) out="0" out;
    print out
  }'
}

duration_seconds() {
  printf '%s %s' "$1" "$2" | "$BB" awk '{
    n=int($1+0); u=$2;
    if (n<=0) { print ""; exit }
    if (u=="day") print n*86400;
    else if (u=="minute") print n*60;
    else print n*3600
  }'
}

utc_offset_seconds() {
  "$BB" date +%z 2>/dev/null | "$BB" awk '{
    s=$0;
    if (s !~ /^[+-][0-9][0-9][0-9][0-9]$/) { print 0; exit }
    sign=(substr(s,1,1)=="-") ? -1 : 1;
    hh=substr(s,2,2)+0; mm=substr(s,4,2)+0;
    print sign*(hh*3600+mm*60)
  }' || printf '0'
}

ymd_to_epoch() {
  _d=$1
  case "$_d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) printf ''; return 1 ;;
  esac
  _off=$(utc_offset_seconds)
  _e=$(printf '%s %s' "$_d" "$_off" | "$BB" awk '
    function fdiv(a,b){ q=int(a/b); if (a%b!=0 && ((a<0)!=(b<0))) q--; return q }
    {
      split($1,p,"-"); y=p[1]+0; m=p[2]+0; d=p[3]+0; off=$2+0;
      yy = y - ((m<=2) ? 1 : 0);
      era = fdiv((yy>=0) ? yy : yy-399, 400);
      yoe = yy - era*400;
      doy = int((153*(m + ((m>2) ? -3 : 9)) + 2)/5) + d - 1;
      doe = yoe*365 + int(yoe/4) - int(yoe/100) + doy;
      days = era*146097 + doe - 719468;
      print days*86400 - off
    }')
  [ -n "$_e" ] || return 1
  case "$2" in
    end|next) _e=$((_e + 86400)) ;;
  esac
  printf '%s' "$_e"
}

epoch_to_ymd() {
  _ts=$(num "$1" '')
  [ -n "$_ts" ] || { printf ''; return 1; }
  _off=$(utc_offset_seconds)
  printf '%s %s' "$_ts" "$_off" | "$BB" awk '
    function fdiv(a,b){ q=int(a/b); if (a%b!=0 && ((a<0)!=(b<0))) q--; return q }
    {
      ts=$1+0; off=$2+0;
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
      printf "%04d-%02d-%02d\n", y, m, d
    }'
}

today_ymd() {
  "$BB" date '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d'
}
