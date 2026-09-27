# Hotspot patch, firewall gate, and best-effort shaping.

. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"

_if_exists() {
  command -v ip >/dev/null 2>&1 || return 1
  ip link show "$1" >/dev/null 2>&1
}

lan_if() {
  if _if_exists br0; then printf 'br0'; return 0; fi
  _cfg=$(cfg_get LAN_IF ap0)
  if _if_exists "$_cfg"; then printf '%s' "$_cfg"; return 0; fi
  printf '%s' "$_cfg"
}

wan_if() {
  _w=$(cfg_get WAN_IF auto)
  if [ -z "$_w" ] || [ "$_w" = "auto" ]; then
    if command -v ip >/dev/null 2>&1; then
      ip route show default 2>/dev/null | "$BB" awk '{print $5; exit}'
      return
    fi
    printf ''; return
  fi
  printf '%s' "$_w"
}

ipt() {
  if is_lab; then return 0; fi
  command -v iptables >/dev/null 2>&1 || return 1
  iptables "$@"
}

ip6t() {
  is_lab && return 0
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables "$@"
}

fw_ensure() {
  command -v iptables >/dev/null 2>&1 || return 1
  ipt -N RNS_FWD 2>/dev/null || true
  ipt -t nat -N RNS_PRE 2>/dev/null || true
  ipt -N RNS_IN 2>/dev/null || true
  ipt -C FORWARD -j RNS_FWD 2>/dev/null || ipt -I FORWARD 1 -j RNS_FWD
  ipt -t nat -C PREROUTING -j RNS_PRE 2>/dev/null || ipt -t nat -I PREROUTING 1 -j RNS_PRE
  ipt -C INPUT -j RNS_IN 2>/dev/null || ipt -I INPUT 1 -j RNS_IN
}

fw_clear() {
  ipt -D FORWARD -j RNS_FWD 2>/dev/null || true
  ipt -F RNS_FWD 2>/dev/null || true
  ipt -X RNS_FWD 2>/dev/null || true
  ipt -t nat -D PREROUTING -j RNS_PRE 2>/dev/null || true
  ipt -t nat -F RNS_PRE 2>/dev/null || true
  ipt -t nat -X RNS_PRE 2>/dev/null || true
  ipt -D INPUT -j RNS_IN 2>/dev/null || true
  ipt -F RNS_IN 2>/dev/null || true
  ipt -X RNS_IN 2>/dev/null || true
}

_fw_sync_macs() {
  _tflag=$1; _chain=$2; _ifc=$3; _wantf=$4
  _havef="$RNS_DATA/fw-have.$$"
  ipt $_tflag -S "$_chain" 2>/dev/null \
    | "$BB" sed -n 's/.*--mac-source \([0-9a-f:]*\).*/\1/p' > "$_havef"
  while read -r _m; do
    [ -n "$_m" ] || continue
    "$BB" grep -qx "$_m" "$_wantf" >/dev/null 2>&1 && continue
    ipt $_tflag -D "$_chain" -i "$_ifc" -m mac --mac-source "$_m" -j RETURN 2>/dev/null || true
  done < "$_havef"
  while read -r _m; do
    [ -n "$_m" ] || continue
    "$BB" grep -qx "$_m" "$_havef" >/dev/null 2>&1 && continue
    ipt $_tflag -I "$_chain" 1 -i "$_ifc" -m mac --mac-source "$_m" -j RETURN 2>/dev/null || true
  done < "$_wantf"
  rm -f "$_havef"
}

fw_rebuild() {
  if [ -f "$RNS_DATA/PAUSE" ]; then fw_clear; return 0; fi
  _lan=$(lan_if)
  _port=$(cfg_get PORTAL_PORT 8080)
  fw_ensure || return 1

  if ! is_lab; then
    if ! ip link show "$_lan" >/dev/null 2>&1; then return 0; fi
  fi

  ipt -C RNS_IN -i "$_lan" -p tcp --dport "$_port" -j ACCEPT 2>/dev/null \
    || ipt -A RNS_IN -i "$_lan" -p tcp --dport "$_port" -j ACCEPT
  ipt -C RNS_IN -i lo -p tcp --dport "$_port" -j ACCEPT 2>/dev/null \
    || ipt -A RNS_IN -i lo -p tcp --dport "$_port" -j ACCEPT

  _base_ok=1
  for _spec in \
    "-i $_lan -p udp --dport 53 -j RETURN" \
    "-i $_lan -p tcp --dport 53 -j RETURN" \
    "-i $_lan -p udp --dport 67 -j RETURN" \
    "-i $_lan -p udp --sport 68 -j RETURN" \
    "-i $_lan -p tcp --dport 443 -j REJECT --reject-with tcp-reset" \
    "-i $_lan -j DROP"
  do
    ipt -C RNS_FWD $_spec >/dev/null 2>&1 || { _base_ok=0; break; }
  done
  if [ "$_base_ok" != "1" ]; then
    ipt -F RNS_FWD
    for _spec in \
      "-i $_lan -p udp --dport 53 -j RETURN" \
      "-i $_lan -p tcp --dport 53 -j RETURN" \
      "-i $_lan -p udp --dport 67 -j RETURN" \
      "-i $_lan -p udp --sport 68 -j RETURN" \
      "-i $_lan -p tcp --dport 443 -j REJECT --reject-with tcp-reset" \
      "-i $_lan -j DROP"
    do
      ipt -A RNS_FWD $_spec
    done
  fi

  if ! ipt -t nat -C RNS_PRE -i "$_lan" -p tcp --dport 80 -j REDIRECT --to-ports "$_port" 2>/dev/null; then
    ipt -t nat -A RNS_PRE -i "$_lan" -p tcp --dport 80 -j REDIRECT --to-ports "$_port"
  fi

  _wantf="$RNS_DATA/fw-want.$$"
  active_macs | "$BB" cut -d'|' -f1 > "$_wantf"
  _fw_sync_macs "" RNS_FWD "$_lan" "$_wantf"
  _fw_sync_macs "-t nat" RNS_PRE "$_lan" "$_wantf"
  rm -f "$_wantf"

  if ! is_lab; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    _wan=$(wan_if)
    if [ -n "$_wan" ]; then
      if ! iptables -t nat -S POSTROUTING 2>/dev/null | "$BB" grep -q MASQUERADE; then
        iptables -t nat -A POSTROUTING -o "$_wan" -j MASQUERADE 2>/dev/null || true
      fi
    fi
  fi
}

gate_heal() {
  [ -f "$RNS_DATA/PAUSE" ] && return 1
  fw_rebuild
}

# Regenerate /data/rns/hostapd.conf from config.env and ask a running hostapd
# to reload it, so the Network tab in the staff panel changes the live AP
# instead of only the next boot. hostapd_cli reload is the supported way to
# apply a new SSID/channel/client-limit without dropping every client; with no
# control socket (no wlan interface, or hostapd not running) this is a no-op
# and the settings simply wait for the next boot.
hostapd_apply() {
  _wl=""
  [ -f "$RNS_DATA/wlan.if" ] && _wl=$("$BB" tr -d ' \r\n' < "$RNS_DATA/wlan.if" 2>/dev/null)
  [ -n "$_wl" ] || return 1
  _ssid=$(cfg_get SSID RNS); _ch=$(cfg_get CHANNEL 6)
  _hw=$(cfg_get HW_MODE g); _ms=$(cfg_get MAX_STA 128)
  _conf="$RNS_DATA/hostapd.conf"
  {
    printf 'interface=%s\n' "$_wl"
    printf 'driver=nl80211\n'
    printf 'ssid=%s\n' "$_ssid"
    printf 'hw_mode=%s\n' "$_hw"
    printf 'channel=%s\n' "$_ch"
    printf 'auth_algs=1\n'
    printf 'ignore_broadcast_ssid=0\n'
    printf 'ap_isolate=1\n'
    printf 'max_num_sta=%s\n' "$_ms"
    printf 'bridge=br0\n'
    printf 'ctrl_interface=/var/run/hostapd\n'
  } > "$_conf" 2>/dev/null
  is_lab && return 0
  for _c in /usr/sbin/hostapd_cli /usr/bin/hostapd_cli /sbin/hostapd_cli hostapd_cli; do
    command -v "$_c" >/dev/null 2>&1 || continue
    for _ctrl in /var/run/hostapd /run/hostapd; do
      [ -d "$_ctrl" ] || continue
      "$_c" -p "$_ctrl" -i "$_wl" reload >> "$LOG" 2>&1 && return 0
    done
  done
  return 0
}

shape_apply() {
  is_lab && return 0
  command -v tc >/dev/null 2>&1 || return 0
  _lan=$(lan_if)
  ip link show "$_lan" >/dev/null 2>&1 || return 0
  tc qdisc del dev "$_lan" root 2>/dev/null || true
  tc qdisc del dev "$_lan" ingress 2>/dev/null || true
  tc qdisc add dev "$_lan" root handle 1: htb default 99 2>/dev/null || return 0
  tc class add dev "$_lan" parent 1: classid 1:99 htb rate 100mbit 2>/dev/null || true
  tc qdisc add dev "$_lan" handle ffff: ingress 2>/dev/null || true
  _id=10
  active_macs | while IFS='|' read -r mac ip down up; do
    [ -n "$ip" ] || continue
    [ -n "$down" ] || continue
    tc class add dev "$_lan" parent 1: classid "1:${_id}" htb rate "${down}kbit" ceil "${down}kbit" 2>/dev/null || true
    tc filter add dev "$_lan" protocol ip parent 1: prio 1 u32 match ip dst "$ip" flowid "1:${_id}" 2>/dev/null || true
    if [ -n "$up" ]; then
      tc filter add dev "$_lan" parent ffff: protocol ip prio 1 u32 match ip src "$ip" police rate "${up}kbit" burst 32k drop 2>/dev/null || true
    fi
    _id=$((_id + 1))
  done
}

deauth_mac() {
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 0
  is_lab && return 0
  _ip=$( "$BB" awk -F'|' -v m="k$_mac" '"k" $1==m {print $2; exit}' "$CFILE" 2>/dev/null )
  if [ -n "$_ip" ] && command -v conntrack >/dev/null 2>&1; then
    conntrack -D -s "$_ip" >/dev/null 2>&1 || true
    conntrack -D -d "$_ip" >/dev/null 2>&1 || true
  fi
  _cli=""
  for _c in /usr/sbin/hostapd_cli /usr/bin/hostapd_cli /sbin/hostapd_cli; do
    [ -x "$_c" ] && _cli=$_c && break
  done
  command -v hostapd_cli >/dev/null 2>&1 && [ -z "$_cli" ] && _cli=hostapd_cli
  [ -n "$_cli" ] || return 0
  _lan=$(lan_if)
  for _ctrl in /var/run/hostapd /run/hostapd; do
    [ -d "$_ctrl" ] || continue
    if "$_cli" -p "$_ctrl" -i "$_lan" disassociate "$_mac" >> "$LOG" 2>&1; then
      "$_cli" -p "$_ctrl" -i "$_lan" deauthenticate "$_mac" >> "$LOG" 2>&1 || true
      return 0
    fi
  done
  return 0
}

expire_enforce() {
  _kicked=$(with_lock voucher_sweep)
  if [ -n "$_kicked" ]; then
    fw_rebuild || true
    printf '%s\n' "$_kicked" | while read -r mac; do
      [ -n "$mac" ] || continue
      log_event expire "$mac"
      deauth_mac "$mac"
    done
    printf '%s\n' "$_kicked"
  fi
  return 0
}

client_disconnect() {
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 0
  fw_rebuild || true
  deauth_mac "$_mac"
}

neigh_scan() {
  is_lab && return 0
  [ -f /proc/net/arp ] || return 0
  _lan=$(lan_if)
  "$BB" awk -v ifc="k$_lan" '"k" $6==ifc && $4 != "00:00:00:00:00:00" {print $4, $1}' /proc/net/arp \
    | while read -r mac ip; do
        client_touch "$mac" "$ip" ""
      done
}

housekeeping() {
  expire_enforce >/dev/null
  neigh_scan
  fw_rebuild
  shape_apply
  printf '%s\n' "$(now_epoch)" > "$RNS_DATA/sweep.stamp" 2>/dev/null || true
}
