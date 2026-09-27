#!/bin/sh
# Regression suite for the RNS gateway.
#
# Runs the real overlay scripts under busybox. Needs no root, no network and
# no firewall: the store and HTTP layers are exercised directly, and the
# listener test starts a genuine socat listener on localhost. socat is the
# only optional dependency — the live test is skipped without it.
#
#   sh tests/run-tests.sh
#
set -u

PROJ=$(cd "$(dirname "$0")/.." && pwd)
BOARD="$PROJ/buildroot-project/board/rns/x86_64"
ROOTFS="$BOARD/rootfs-overlay"
RNSH="$ROOTFS/usr/share/rns"

if [ -x /bin/busybox ]; then BB=/bin/busybox
elif [ -x /usr/bin/busybox ]; then BB=/usr/bin/busybox
else echo "FATAL: busybox not found on this host"; exit 1; fi
export BB

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip  %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }
has()  { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 — [$1] not in output" ;; esac; }
nohas(){ case "$2" in *"$1"*) bad "$3 — [$1] unexpectedly present" ;; *) ok "$3" ;; esac; }
filehas() {
  if grep -q -e "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3 — [$1] not in ${2##*/}"; fi
}
fileno() {
  if grep -q -e "$1" "$2" 2>/dev/null; then bad "$3 — [$1] still in ${2##*/}"; else ok "$3"; fi
}

WORK=$(mktemp -d 2>/dev/null || echo /tmp/rns-test.$$)
mkdir -p "$WORK/data"
trap 'rm -rf "$WORK"; [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null' EXIT

# ---------------------------------------------------------------- shell syntax
echo "== shell syntax (busybox ash)"
for f in "$RNSH"/bin/*.sh "$ROOTFS"/etc/init.d/S* "$BOARD"/post-build.sh "$BOARD"/post-image.sh; do
  out=$("$BB" sh -n "$f" 2>&1)
  if [ -z "$out" ]; then ok "syntax ${f##*/}"; else bad "syntax ${f##*/}: $out"; fi
done

# ------------------------------------------------- client address resolution
echo "== ipv4_norm / resolve_client_ip"
cat > "$WORK/unit.sh" <<'EOS'
. "$RNS_HOME/bin/common.sh"
case "$1" in
  norm) ipv4_norm "$2" ;;
  res)  resolve_client_ip ;;
esac
EOS
unit() {
  RNS_HOME="$RNSH" RNS_DATA="$WORK/data" "$BB" sh "$WORK/unit.sh" "$@"
}
eq "norm plain ipv4"        "192.168.50.77" "$(unit norm 192.168.50.77)"
eq "norm ipv4-mapped"       "10.0.0.5"      "$(unit norm ::ffff:10.0.0.5)"
eq "norm bracketed mapped"  "10.0.0.6"      "$(unit norm '[::ffff:10.0.0.6]')"
eq "norm rejects text"      ""              "$(unit norm not-an-ip)"
eq "norm rejects 999 octet" ""              "$(unit norm 999.1.1.1)"
eq "norm rejects 3 octets"  ""              "$(unit norm 10.0.0)"
eq "norm rejects empty"     ""              "$(unit norm '')"
eq "resolve from SOCAT_PEERADDR" "192.168.50.9" \
   "$(SOCAT_PEERADDR=192.168.50.9 unit res)"
eq "resolve from REMOTE_ADDR mapped" "172.16.0.2" \
   "$(REMOTE_ADDR='::ffff:172.16.0.2' unit res)"
eq "explicit CLIENT_IP wins" "1.2.3.4" \
   "$(CLIENT_IP=1.2.3.4 SOCAT_PEERADDR=5.6.7.8 unit res)"
eq "falls through a bad value" "9.9.9.9" \
   "$(SOCAT_PEERADDR=bogus REMOTE_ADDR=9.9.9.9 unit res)"
eq "resolve with nothing set is empty" "" "$(env -u CLIENT_IP -u SOCAT_PEERADDR -u REMOTE_ADDR -u TCPREMOTEIP -u RNS_CLIENT_IP "$BB" sh -c "RNS_HOME='$RNSH' RNS_DATA='$WORK/data' '$BB' sh '$WORK/unit.sh' res")"
filehas "^resolve_client_ip()" "$RNSH/bin/common.sh" "resolve_client_ip is actually defined"

# ------------------------------------------------------- store / voucher flow
echo "== voucher store"
cat > "$WORK/store.sh" <<'EOS'
. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"
store_init
case "$1" in
  pkg)    package_upsert hour1 "1 Hour" 3600 4000 1000 100 ;;
  pkgjson) packages_json ;;
  mint)   with_lock voucher_mint hour1 "${2:-1}" "" ;;
  redeem) with_lock voucher_redeem "$2" "$3" ;;
  counts) overview_json ;;
  vjson)  vouchers_json "" "" ;;
  cjson)  clients_json "" "" ;;
  bound)  exec "$BB" sh "$RNS_HOME/bin/rns-bound.sh" "$2" ;;
esac
EOS
store() { BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/data" "$BB" sh "$WORK/store.sh" "$@"; }

eq "package_upsert" "ok" "$(store pkg && echo ok)"
has '"id":"hour1"' "$(store pkgjson)" "packages_json lists the plan"
CODES=$(store mint 2)
C1=$(printf '%s' "$CODES" | cut -d' ' -f1 | tr -d '-')
C2=$(printf '%s' "$CODES" | cut -d' ' -f2 | tr -d '-')
eq "mint returns 2 codes" "2" "$(printf '%s' "$CODES" | wc -w | tr -d ' ')"
eq "redeem fresh code" "ok" "$(store redeem "$C1" 10.9.9.9 | cut -d'|' -f1)"
eq "redeem same device again" "ok" "$(store redeem "$C1" 10.9.9.9 | cut -d'|' -f1)"
eq "redeem from another device" "used" "$(store redeem "$C1" 10.9.9.10)"
eq "redeem bogus code" "invalid" "$(store redeem ZZZZZZZZ 10.9.9.9)"
eq "redeem without a device" "nomac" "$(RNS_LAB=0 BB=$BB RNS_HOME="$RNSH" RNS_DATA="$WORK/data" "$BB" sh "$WORK/store.sh" redeem "$C2" '')"
eq "counts after redeem" \
   '{"active":1,"unused":1,"expired":0,"revoked":0,"online":1,"waiting":0}' \
   "$(store counts)"
has '"status":"active"' "$(store vjson)" "vouchers_json shows the active voucher"
has '"plan":"1 Hour"'   "$(store cjson)" "clients_json joins the voucher"
eq "bound device"  "bound|02:00:00:00:09:09" "$(store bound 10.9.9.9)"
eq "unbound device" "free" "$(store bound 10.9.9.250)"

# ---------------------------------------------------------- live HTTP listener
echo "== live listener (socat)"
PORT=$((18000 + $$ % 1500))
if command -v socat >/dev/null 2>&1; then
  BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/data" RNS_PORT=$PORT \
    "$BB" sh "$RNSH/bin/rns-pages.sh"
  eq "pages picked the socat engine" "socat" "$(cat "$WORK/data/httpd.engine" 2>/dev/null)"
  LPID=$(cat "$WORK/data/httpd.pid" 2>/dev/null)

  client() {
    if "$BB" nc --help 2>&1 | grep -q -- '-e'; then
      printf '%b' "$1" | "$BB" nc 127.0.0.1 $PORT
    else
      printf '%b' "$1" | socat - "TCP:127.0.0.1:$PORT"
    fi
  }

  BODY="code=$C2"; CL=$(printf '%s' "$BODY" | wc -c | tr -d ' ')
  REQ="POST /api/redeem HTTP/1.0\r\nHost: t\r\nAccept: application/json\r\nContent-Length: $CL\r\n\r\n$BODY"
  OUT=$(client "$REQ")

  # 127.0.0.1 maps to lab MAC 02:00:00:00:00:01. Before the fix CLIENT_IP was
  # always empty and this returned {"ok":false,...,"reason":"nomac"}.
  has '"ok":true' "$OUT" "redeem over the real socket succeeds"
  has '"mac":"02:00:00:00:00:01"' "$OUT" "redeem saw the peer address from socat"
  nohas '"reason":"nomac"' "$OUT" "redeem no longer reports nomac"

  H=$(client 'GET /health HTTP/1.0\r\n\r\n')
  has '"pages":true' "$H" "/health answers"
  P=$(client 'GET / HTTP/1.0\r\n\r\n')
  has 'Connect · RNS Internet' "$P" "portal page is served"
  A=$(client 'GET /admin HTTP/1.0\r\n\r\n')
  has 'RNS Gateway · Staff' "$A" "admin page is served"
  U=$(client 'GET /api/admin/overview HTTP/1.0\r\nAccept: application/json\r\n\r\n')
  has '401 Unauthorized' "$U" "admin API rejects an anonymous caller"

  [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null
  LPID=""
else
  skip "socat not installed — live listener test not run"
fi

# --------------------------------------------------- boot scripts generate config
echo "== boot-time config generation"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/true-bin"
chmod 755 "$WORK/bin/true-bin"

DNSMASQ_BIN="$WORK/bin/true-bin" RNS_DATA="$WORK/data" \
  "$BB" sh "$ROOTFS/etc/init.d/S30dnsmasq" > "$WORK/s30.out" 2>&1
eq "S30dnsmasq exits 0" "0" "$?"
has 'started on br0' "$(cat "$WORK/s30.out")" "dnsmasq started"
filehas 'dhcp-range=192.168.50.50,192.168.50.200' "$WORK/data/dnsmasq.conf" "dhcp range written to /data"
filehas 'dhcp-option=option:router,192.168.50.1'  "$WORK/data/dnsmasq.conf" "gateway option written"

# A non-default LAN_IP must actually reach the generated config: this is what
# silently broke when the script sed-ed a read-only /etc/dnsmasq.conf.
printf 'LAN_IP=10.20.30.1\n' > "$WORK/data/config.env"
DNSMASQ_BIN="$WORK/bin/true-bin" RNS_DATA="$WORK/data" \
  "$BB" sh "$ROOTFS/etc/init.d/S30dnsmasq" >/dev/null 2>&1
filehas 'dhcp-range=10.20.30.50,10.20.30.200' "$WORK/data/dnsmasq.conf" "custom LAN_IP reaches dhcp-range"
filehas 'dhcp-option=option:router,10.20.30.1' "$WORK/data/dnsmasq.conf" "custom LAN_IP reaches the router option"

HOSTAPD_BIN="$WORK/bin/true-bin" WLAN_IF=wlan0 RNS_DATA="$WORK/data" \
  "$BB" sh "$ROOTFS/etc/init.d/S40hostapd" > "$WORK/s40.out" 2>&1
has 'started on wlan0' "$(cat "$WORK/s40.out")" "hostapd started"
filehas 'ctrl_interface=/var/run/hostapd' "$WORK/data/hostapd.conf" "hostapd control socket configured"
filehas 'bridge=br0' "$WORK/data/hostapd.conf" "hostapd joins the bridge"

# -------------------------------------------------------- build configuration
echo "== build configuration"
filehas 'BR2_PACKAGE_SOCAT=y'           "$PROJ/buildroot-project/configs/rns_x86_64_defconfig" "socat is built into the image"
filehas 'BR2_PACKAGE_HOST_XORRISO=y'    "$PROJ/buildroot-project/configs/rns_x86_64_defconfig" "host xorriso is built for the ISO"
for sym in CONFIG_BLK_DEV_INITRD CONFIG_BLK_DEV_RAM CONFIG_NET_SCHED \
           CONFIG_NET_SCH_INGRESS CONFIG_NET_CLS_ACT CONFIG_NET_ACT_POLICE \
           CONFIG_UNIX CONFIG_PACKET; do
  filehas "^$sym=y" "$BOARD/kernel.config" "$sym enabled"
done
filehas '^CONFIG_BLK_DEV_RAM_SIZE=65536' "$BOARD/kernel.config" "ramdisk larger than the rootfs"
filehas 'root=/dev/ram0' "$BOARD/post-image.sh" "boot args match the initrd root"
filehas 'INITRD /rootfs.squashfs' "$BOARD/post-image.sh" "squashfs is loaded as initrd"
filehas 'xorriso' "$BOARD/post-image.sh" "post-image can build the ISO"
filehas 'over the 10 MB target' "$BOARD/post-image.sh" "ISO size is a warning, not a failure"

# ---------------------------------------------------------- firewall posture
echo "== firewall posture"
filehas 'ipt -P FORWARD DROP' "$ROOTFS/etc/init.d/S50gate" "FORWARD defaults to DROP"
fileno 'RNS_FWD -i br0 -o' "$ROOTFS/etc/init.d/S50gate" "no blanket LAN->WAN accept at boot"
filehas '--dport 22 -j DROP' "$ROOTFS/etc/init.d/S50gate" "ssh closed by default"
filehas 'rns-gate-min.sh' "$ROOTFS/etc/init.d/S50gate" "captive rules armed at boot"
fileno 'sed -i' "$ROOTFS/etc/init.d/S30dnsmasq" "dnsmasq no longer edits read-only /etc"
fileno 'cat > /etc/hostapd.conf' "$ROOTFS/etc/init.d/S40hostapd" "hostapd no longer writes /etc"
fileno '"lab":false' "$RNSH/bin/rns-http.sh" "lab flag is not hardcoded"

# ---------------------------------------------------------- post-image.sh
echo "== post-image.sh (stubbed ISO writer)"
# Buildroot hands the script $BINARIES_DIR itself, so the artifacts sit
# directly in it.
IMG="$WORK/images"
mkdir -p "$IMG"
printf 'kernel\n' > "$IMG/bzImage"
printf 'squashfs\n' > "$IMG/rootfs.squashfs"
printf 'mbr\n' > "$IMG/isolinux.bin"
mkdir -p "$IMG/isolinux"; printf 'mbr\n' > "$IMG/isolinux/isolinux.bin"

# A stand-in for xorriso/genisoimage: records its arguments and writes an
# output file of a known size. post-image.sh's own logic — arg handling, the
# isolinux.cfg it generates, which writer it picks, and whether a large ISO
# is fatal — is what this exercises.
cat > "$WORK/bin/xorriso" <<EOS
#!/bin/sh
printf '%s\n' "\$@" > "$WORK/mkiso.args"
out=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  prev="\$a"
done
[ -n "\$out" ] && "$BB" dd if=/dev/zero of="\$out" bs=1048576 count=12 2>/dev/null
exit 0
EOS
chmod 755 "$WORK/bin/xorriso"

PATH="$WORK/bin:$PATH" "$BB" sh "$BOARD/post-image.sh" "$IMG" > "$WORK/pi.out" 2>&1
eq "post-image exits 0 with a 12 MB ISO" "0" "$?"
has 'over the 10 MB target' "$(cat "$WORK/pi.out")" "large ISO warns instead of failing"
has 'mkisofs' "$(cat "$WORK/mkiso.args" 2>/dev/null)" "xorriso invoked in mkisofs mode"
filehas 'root=/dev/ram0 rootfstype=squashfs ro' "$IMG/isolinux/isolinux.cfg" "isolinux.cfg boots the ramdisk root"
filehas 'INITRD /rootfs.squashfs' "$IMG/isolinux/isolinux.cfg" "isolinux.cfg loads the squashfs"
filehas 'console=ttyS0,115200' "$IMG/isolinux/isolinux.cfg" "serial console enabled"
rm -f "$IMG/bzImage"
out=$("$BB" sh "$BOARD/post-image.sh" "$IMG" 2>&1) || true
has 'is missing' "$out" "a missing kernel image is reported clearly"
printf 'kernel\n' > "$IMG/bzImage"
[ -f "$IMG/rns-router.iso" ] && ok "iso written to images/" || bad "iso not written"

# genisoimage fallback, and a clear error when no writer exists at all
mkdir -p "$WORK/bin2"; cp "$WORK/bin/xorriso" "$WORK/bin2/genisoimage"
rm -f "$IMG/rns-router.iso"
PATH="$WORK/bin2:$PATH" "$BB" sh "$BOARD/post-image.sh" "$IMG" >/dev/null 2>&1
eq "falls back to genisoimage" "0" "$?"
[ -f "$IMG/rns-router.iso" ] && ok "genisoimage path writes the iso" || bad "genisoimage path wrote nothing"

rm -f "$IMG/rns-router.iso"
if command -v xorriso >/dev/null 2>&1 || command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1; then
  skip "this host has an ISO writer — missing-writer path not tested"
else
  out=$("$BB" sh "$BOARD/post-image.sh" "$IMG" 2>&1) || true
  has 'BR2_PACKAGE_HOST_XORRISO' "$out" "missing ISO writer explains how to fix it"
fi

# ------------------------------------------------------------------ summary
echo
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
