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
filehas 'BR2_LINUX_KERNEL_BZIMAGE=y'    "$PROJ/buildroot-project/configs/rns_x86_64_defconfig" "kernel image is named bzImage"
filehas 'ldlinux.c32'                   "$PROJ/buildroot-project/configs/rns_x86_64_defconfig" "syslinux C32 module is installed"
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
mkdir -p "$IMG/syslinux"
printf 'kernel\n' > "$IMG/bzImage"
printf 'squashfs\n' > "$IMG/rootfs.squashfs"
printf 'boot\n' > "$IMG/syslinux/isolinux.bin"
printf 'c32\n'  > "$IMG/syslinux/ldlinux.c32"

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

# RNS_MKISO pins the writer: GitHub's runners ship a real xorriso, and a
# search-based test would silently exercise that instead of the stub.
PATH="$WORK/bin:$PATH" RNS_MKISO=xorriso \
  "$BB" sh "$BOARD/post-image.sh" "$IMG" > "$WORK/pi.out" 2>&1
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
[ -f "$IMG/isolinux/isolinux.bin" ] && ok "isolinux.bin staged from syslinux/" || bad "isolinux.bin not staged"
[ -f "$IMG/isolinux/ldlinux.c32" ] && ok "ldlinux.c32 staged beside isolinux.bin" || bad "ldlinux.c32 not staged"

# syslinux 6 refuses to boot without ldlinux.c32, so a missing one must be fatal
# Simulate a clean output/images: the isolinux/ dir is derived, so drop the
# copy the previous run staged as well as the source.
mv "$IMG/syslinux/ldlinux.c32" "$WORK/ldlinux.c32.bak"
rm -rf "$IMG/isolinux"
out=$(PATH="$WORK/bin:$PATH" "$BB" sh "$BOARD/post-image.sh" "$IMG" 2>&1) || true
has 'BR2_TARGET_SYSLINUX_C32' "$out" "a missing ldlinux.c32 is refused with the fix"
mv "$WORK/ldlinux.c32.bak" "$IMG/syslinux/ldlinux.c32"

# The non-xorriso invocation path, and a writer that cannot be found.
mkdir -p "$WORK/bin2"; cp "$WORK/bin/xorriso" "$WORK/bin2/genisoimage"
rm -f "$IMG/rns-router.iso"
PATH="$WORK/bin2:$PATH" RNS_MKISO=genisoimage \
  "$BB" sh "$BOARD/post-image.sh" "$IMG" >/dev/null 2>&1
eq "honours RNS_MKISO=genisoimage" "0" "$?"
[ -f "$IMG/rns-router.iso" ] && ok "genisoimage path writes the iso" || bad "genisoimage path wrote nothing"

rm -f "$IMG/rns-router.iso"
out=$(RNS_MKISO=/nonexistent-iso-writer "$BB" sh "$BOARD/post-image.sh" "$IMG" 2>&1) || true
has 'not on PATH' "$out" "an unusable RNS_MKISO is reported instead of a mystery failure"


# ----------------------------------------------------------------- CI workflow
echo "== CI workflow"
WF="$PROJ/../.github/workflows/build-iso.yml"
if [ ! -f "$WF" ]; then
  bad ".github/workflows/build-iso.yml is missing"
else
  ok "workflow file present"
  # Pull every `run:` block out of the YAML and syntax-check it as bash. The
  # blocks deliberately use shell env vars rather than ${{ }} so they are
  # valid bash on their own.
  awk '
    function indent(l,  i) { i = 0; while (substr(l, i+1, 1) == " ") i++; return i }
    /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ { inb = 1; base = -1; next }
    /^[[:space:]]*run:[[:space:]]*[^|[:space:]]/ {
      line = $0; sub(/^[[:space:]]*run:[[:space:]]*/, "", line); print line; next
    }
    inb {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      cur = indent($0)
      if (base < 0) base = cur
      if (cur >= base) { print substr($0, base + 1); next }
      inb = 0
    }
  ' "$WF" > "$WORK/ci-runs.sh"
  lines=$(wc -l < "$WORK/ci-runs.sh" | tr -d ' ')
  if [ "$lines" -gt 5 ]; then
    ok "extracted $lines lines of workflow shell"
  else
    bad "only extracted $lines lines of workflow shell — extractor is broken"
  fi
  out=$(bash -n "$WORK/ci-runs.sh" 2>&1) || bad "workflow shell is not valid bash: $out"
  [ -z "$out" ] && ok "every run: block is valid bash"
  filehas 'rns-router/tests/run-tests.sh' "$WF" "workflow runs the test suite"
  filehas './rns-router/build.sh'          "$WF" "workflow uses the shared builder"
  filehas 'output/images/rns-router.iso'   "$WF" "artifact path matches build.sh output"
  filehas 'if-no-files-found: error'       "$WF" "a missing ISO fails the job"
  filehas 'actions/upload-artifact'        "$WF" "ISO is uploaded as an artifact"
  filehas 'BR2_DL_DIR'                     "$WF" "download cache is external and cacheable"
fi

# ----------------------------------------------------- post-build.sh robustness
echo "== post-build.sh on a realistic target tree"
PB="$WORK/target"
mkdir -p "$PB/etc/init.d" "$PB/usr/share/rns/bin"
# Buildroot's dropbear package leaves /etc/dropbear as a symlink into the
# per-boot tmpfs (ln -snf /var/run/dropbear). mkdir -p on a symlink fails
# with "File exists" — that is exactly what killed the CI build during
# target-finalize. post-build.sh must survive it and still finish its work.
ln -s /var/run/dropbear "$PB/etc/dropbear"
if "$BB" sh "$BOARD/post-build.sh" "$PB" >/dev/null 2>"$WORK/pb.err"; then
  ok "post-build.sh survives the dropbear symlink"
else
  bad "post-build.sh failed with the dropbear symlink: $(cat "$WORK/pb.err")"
fi
if [ -d "$PB/data/rns" ]; then
  ok "post-build.sh creates /data/rns"
else
  bad "post-build.sh did not create /data/rns"
fi


# =====================================================================
# New admin panel: settings, sales, PDF slips, online packages, payments
# =====================================================================
echo "== form_has distinguishes absent from empty"
cat > "$WORK/forms.sh" <<'EOS'
. "$RNS_HOME/bin/common.sh"
case "$1" in
  has) form_has "$2" ;;
esac
EOS
formhas() { RNS_QUERY="$3" RNS_BODY="$4" RNS_HOME="$RNSH" RNS_DATA="$WORK/data" \
  "$BB" sh "$WORK/forms.sh" has "$2"; }
eq "form_has sees a submitted field"  "0" "$(formhas x jazzcash_number 'jazzcash_number=0300' ''; echo $?)"
eq "form_has sees an empty field"    "0" "$(formhas x jazzcash_number 'jazzcash_number=' ''; echo $?)"
eq "form_has misses an absent field" "1" "$(formhas x jazzcash_number 'shop=RNS' ''; echo $?)"
eq "form_has reads the POST body"    "0" "$(formhas x easypaisa_number '' 'easypaisa_number=0301'; echo $?)"

echo "== new panel store helpers"
cat > "$WORK/newstore.sh" <<'EOS'
. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"
store_init
case "$1" in
  token)   rand_token "$2" ;;
  money)   money_fmt "$2" ;;
  shift)   ymd_shift "$2" "$3" ;;
  opkg)    online_package_upsert "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" ;;
  opkgjson) online_packages_json ;;
  opkgdel) online_package_delete "$2" ;;
  opkgrow) online_package_row "$2" ;;
  payinit) pay_init "$2" "$3" "$4" "$5" ;;
  paysub)  pay_submit "$2" "$3" "$4" "$5" ;;
  payconf) pay_confirm "$2" ;;
  payrej)  pay_reject "$2" "$3" ;;
  payjson) payments_json ;;
  payrow)  pay_row "$2" ;;
  sales)   sales_json "$2" "$3" ;;
  csv)     sales_csv "$2" "$3" ;;
  backup)  backup_create ;;
  wallet)  online_pay_on && echo on || echo off ;;
  bound)   voucher_for_mac "$2" | "$BB" awk -F'|' '{printf "%s|%s|%s|%s|%s\n", $1, $6, $7, $12, $13}' ;;
  mintb)   voucher_mint_bound "$2" "$3" "$4" online ;;
  vrow)    _voucher_row "$2" ;;
  apconf)  hostapd_apply && echo reloaded || echo noap ;;
  cfgset)  cfg_set "$2" "$3" ;;
  cfgget)  cfg_get "$2" "$3" ;;
  now)     now_epoch ;;
  pdfv)    pdf_render voucher "$2" "$3" ;;
  pdfr)    pdf_render receipt "$2" "$3" ;;
esac
EOS
nstore() { BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/data" "$BB" sh "$WORK/newstore.sh" "$@"; }
nlock()  { BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/data" \
  "$BB" sh -c '. "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; . "$RNS_HOME/bin/net.sh"; store_init; with_lock "$@"' _ "$@"; }

T=$(nstore token 8)
eq "rand_token honours the length" "8" "$(printf '%s' "$T" | wc -c | tr -d ' ')"
case "$T" in *0*|*1*|*O*|*I*) bad "rand_token avoids look-alike characters" ;;
  ????????) ok "rand_token avoids look-alike characters" ;;
  *) bad "rand_token avoids look-alike characters — got [$T]" ;; esac
neq() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 — both are [$2]"; fi; }
neq "rand_token is not constant" "AAAAAAAA" "$T"
neq "rand_token differs per call" "$T" "$(nstore token 8)"

eq "money_fmt pads to two decimals" "0.50"  "$(nstore money 0.5)"
eq "money_fmt keeps whole rupees"   "150.00" "$(nstore money 150)"
eq "money_fmt truncates the third"  "12.34" "$(nstore money 12.345)"
eq "money_fmt rejects junk"         "0.00"  "$(nstore money abc)"
eq "money_fmt handles a bare dot"   "0.00"  "$(nstore money .)"

_D=$(ymd_shift_helper() { :; }; today_ymd_d=$("$BB" date '+%Y-%m-%d'); printf '%s' "$today_ymd_d")
eq "ymd_shift lands on a real date" \
   "7" "$(nstore shift "$_D" -7 | "$BB" awk -F- '{print ($1>2000 && $2>=1 && $2<=12 && $3>=1 && $3<=31) ? 7 : 0}')"

# ------------------------------------------- store mutex (was a no-op flock)
echo "== with_lock actually excludes a second writer"
mkdir -p "$WORK/lockdata"
lklock() { BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/lockdata" \
  "$BB" sh -c '. "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; . "$RNS_HOME/bin/net.sh"; store_init; with_lock "$@"' _ "$@"; }
# Hold the lock across a sleep, then check that a second caller cannot get in
# until the holder has finished. This is the deterministic version of "does the
# mutex work at all" -- a no-op lock (which is what a missing flock applet
# gives you) lets the second caller straight through.
cat > "$WORK/holder.sh" <<'EOS'
. "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; . "$RNS_HOME/bin/net.sh"
store_init
with_lock sh -c 'echo in > "$RNS_DATA/phase"; sleep 3; echo out > "$RNS_DATA/phase"'
EOS
BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/lockdata" "$BB" sh "$WORK/holder.sh" &
sleep 2
eq "the holder is inside the critical section" "in" \
   "$(cat "$WORK/lockdata/phase" 2>/dev/null)"
_t0=$("$BB" date +%s)
lklock true
_t1=$("$BB" date +%s)
eq "a second writer waits for the lock" "yes" \
   "$("$BB" awk -v a="$_t0" -v b="$_t1" 'BEGIN{print (b-a>=1) ? "yes" : "no"}')"
eq "and only runs once the holder is done" "out" \
   "$(cat "$WORK/lockdata/phase" 2>/dev/null)"
wait
eq "the lock directory is released" "gone" \
   "$([ -d "$WORK/lockdata/store.lock.d" ] && echo present || echo gone)"
# A writer that died holding the lock must not wedge every later request.
mkdir -p "$WORK/lockdata/store.lock.d"
printf '%s\n' "999999" > "$WORK/lockdata/store.lock.d/pid"
eq "a lock whose owner is gone is stolen" "ok" \
   "$(lklock client_touch 02:00:00:00:00:43 10.9.9.43 >/dev/null 2>&1 && echo ok)"
unset _t0 _t1

# Regression for a silent data-loss bug: awk's -v coerces a value that is a
# *valid numeric string* into a number, and a field that looks numeric is
# compared numerically too. Voucher codes are random hex, so codes like
# 06E82054 or 124E6045 are valid numbers (they overflow to inf) and a plain
# "$1==c" then compares inf to inf and never finds the row -- a customer's paid
# voucher would simply not resolve. Every field==key awk in the store now
# prefixes both sides with a letter to force a string compare. This runs in its
# own data dir so the planted rows do not disturb the sales report below.
echo "== numeric-looking codes still resolve"
mkdir -p "$WORK/regdata"
nreg() { BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/regdata" "$BB" sh "$WORK/newstore.sh" "$@"; }
nreglock() { BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$WORK/regdata" \
  "$BB" sh -c '. "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; . "$RNS_HOME/bin/net.sh"; store_init; with_lock "$@"' _ "$@"; }
for NCODE in 06E82054 124E6045 12345678 1E5 000E0000 81F60BBF; do
  _n=$(nreg now)
  printf '%s|1 Hour|3600|4000|1000|active|02:00:00:00:00:77|10.9.9.77|%s|%s|%s||100\n' \
    "$NCODE" "$_n" "$((_n + 3600))" "$_n" >> "$WORK/regdata/database/vouchers.tsv"
  eq "a code awk reads as a number is stored" "$NCODE" \
     "$(nreg vrow "$NCODE" | "$BB" cut -d'|' -f1)"
  eq "the paying device still resolves it" "$NCODE" \
     "$(nreg bound 02:00:00:00:00:77 | "$BB" cut -d'|' -f1)"
  eq "revoking a numeric-looking code works" "ok" \
     "$(nreglock voucher_revoke "$NCODE" >/dev/null 2>&1 && echo ok)"
  eq "and the revoke actually landed" "revoked" \
     "$(nreg vrow "$NCODE" | "$BB" cut -d'|' -f6)"
done
unset NCODE _n

echo "== online packages"
eq "online_package_upsert" "ok" "$(nstore opkg op1 "Student Hour" 3600 2048 1024 25 30 hour >/dev/null && echo ok)"
has '"id":"op1"' "$(nstore opkgjson)" "online_packages_json lists the package"
has '"price":"25"' "$(nstore opkgjson)" "online package keeps its price"
eq "online package upsert replaces" "1" "$(nstore opkgjson | "$BB" tr ',' '\n' | "$BB" grep -c '"id":"op1"')"
nstore opkg op2 "Night Bundle" 86400 4096 2048 100 >/dev/null
eq "a second online package is kept" "2" "$(nstore opkgjson | "$BB" tr ',' '\n' | "$BB" grep -c '"id":"op')"
eq "online_package_delete" "deleted" "$(nstore opkgdel op2)"
eq "deleting removes the row" "1" "$(nstore opkgjson | "$BB" tr ',' '\n' | "$BB" grep -c '"id":"op')"
eq "deleting a missing package fails" "not found" "$(nstore opkgdel op2 2>&1)"
eq "an online package needs a price" \
   "online package requires a price" "$(nstore opkg op3 "No Price" 3600 2048 1024 '' 2>&1)"

echo "== online payments"
nstore cfgset JAZZCASH_NUMBER "0300-1234567"
nstore cfgset JAZZCASH_NAME "Ali Raza"
eq "a wallet number switches online pay on" "on" "$(nstore wallet)"
REF=$(nstore payinit op1 jazzcash 02:00:00:00:00:09 10.9.9.9)
case "$REF" in ????????) ok "pay_init issues an 8-character reference" ;;
  *) bad "pay_init issued a bad reference [$REF]" ;; esac
eq "a bad method is refused" "bad method" "$(nstore payinit op1 westernunion 02:00:00:00:00:09 10.9.9.9 2>&1)"
eq "an unknown package is refused" "unknown package" "$(nstore payinit nope jazzcash 02:00:00:00:00:09 10.9.9.9 2>&1)"
nstore cfgset JAZZCASH_NUMBER ""
eq "no wallet number switches online pay off" "off" "$(nstore wallet)"
eq "pay_init refuses with no wallet" \
   "no wallet number for that method" "$(nstore payinit op1 jazzcash 02:00:00:00:00:09 10.9.9.9 2>&1)"
nstore cfgset JAZZCASH_NUMBER "0300-1234567"

# Manual flow: submit, staff confirm, voucher bound to the device.
SUB=$(nlock pay_submit "$REF" 847392016 02:00:00:00:00:09 10.9.9.9)
eq "manual pay_submit is pending" "ok|pending" "$(printf '%s' "$SUB" | "$BB" cut -d'|' -f1-2)"
PAYID=$(printf '%s' "$SUB" | "$BB" cut -d'|' -f3)
eq "the payment row is written" "pending" "$(nstore payrow "$PAYID" | "$BB" cut -d'|' -f13)"
has '"tid":"847392016"' "$(nstore payjson)" "payments_json shows the TID"
has '"package_label":"Student Hour"' "$(nstore payjson)" "payments_json joins the package"
eq "a used reference is single-use" \
   "unknown ref" "$(nlock pay_submit "$REF" 847392016 02:00:00:00:00:09 10.9.9.9 2>&1)"
eq "a short TID is refused" "tid too short" "$(nlock pay_submit "$(nstore payinit op1 jazzcash 02:00:00:00:00:09 10.9.9.9)" 12 02:00:00:00:00:09 10.9.9.9 2>&1)"
eq "confirming mints a voucher for that device" "ok" "$(nlock pay_confirm "$PAYID" | "$BB" cut -d'|' -f1)"
VCODE=$(nstore payrow "$PAYID" | "$BB" cut -d'|' -f17)
[ -n "$VCODE" ] && ok "the voucher code is stored on the payment" \
  || bad "the voucher code is missing from the payment"
eq "the voucher is bound to the paying MAC" \
   "$VCODE|active|02:00:00:00:00:09|online|25" \
   "$(nstore bound 02:00:00:00:00:09)"
eq "the voucher carries the online price" "25" "$(nstore vrow "$VCODE" | "$BB" cut -d'|' -f13)"
eq "the voucher carries a sale date" "1" "$(nstore vrow "$VCODE" | "$BB" awk -F'|' '{print ($11 ~ /^[0-9]+$/) ? 1 : 0}')"
eq "confirming twice is refused" "already confirmed" "$(nlock pay_confirm "$PAYID" 2>&1)"
eq "rejecting a confirmed payment is refused" "already confirmed" "$(nlock pay_reject "$PAYID" 2>&1)"

# Auto-verify: same path, no staff step.
nstore cfgset PAY_AUTO_VERIFY 1
REF2=$(nstore payinit op1 jazzcash 02:00:00:00:00:0a 10.9.9.10)
SUB2=$(nlock pay_submit "$REF2" 998877665 02:00:00:00:00:0a 10.9.9.10)
eq "auto-verify confirms immediately" "ok|confirmed" "$(printf '%s' "$SUB2" | "$BB" cut -d'|' -f1-2)"
PAYID2=$(printf '%s' "$SUB2" | "$BB" cut -d'|' -f3)
eq "auto-verify activates the voucher" "confirmed" "$(nstore payrow "$PAYID2" | "$BB" cut -d'|' -f13)"
eq "auto-verify binds the second device" \
   "active" "$(nstore vrow "$(nstore payrow "$PAYID2" | "$BB" cut -d'|' -f17)" | "$BB" cut -d'|' -f6)"
nstore cfgset PAY_AUTO_VERIFY 0

# Reject path.
REF3=$(nstore payinit op1 jazzcash 02:00:00:00:00:0b 10.9.9.11)
SUB3=$(nlock pay_submit "$REF3" 555666777 02:00:00:00:00:0b 10.9.9.11)
PAYID3=$(printf '%s' "$SUB3" | "$BB" cut -d'|' -f3)
eq "rejecting a pending payment works" "ok" "$(nlock pay_reject "$PAYID3" "no money received")"
eq "the rejection reason is stored" \
   "rejected|no money received" "$(nstore payrow "$PAYID3" | "$BB" cut -d'|' -f13,16 | "$BB" tr '|' '\n' | "$BB" paste -sd'|')"
eq "confirming a rejected payment is refused" \
   "already rejected" "$(nlock pay_confirm "$PAYID3" 2>&1)"
eq "a rejected payment mints no voucher" "" "$(nstore payrow "$PAYID3" | "$BB" cut -d'|' -f17)"

echo "== payments are listed newest first"
_FIRST=$(nstore payjson | "$BB" sed -n 's/.*"pay_id":"\([A-Z0-9]*\)".*/\1/p' | "$BB" tail -1)
eq "the oldest payment is last" "$PAYID" "$_FIRST"
_LAST=$(nstore payjson | "$BB" awk '{match($0,/"pay_id":"[A-Z0-9]*/); print substr($0,RSTART+10,RLENGTH-10)}')
eq "the newest payment is first" "$PAYID3" "$_LAST"

echo "== sales report"
_NOW=$(nstore now)
# start the window a little early: the vouchers above were minted seconds ago
_WIN=$((_NOW - 300))
# 2 x "1 Hour" (100.00) minted by the counter checks above + 2 x "Student Hour" (25.00) minted here
_EXP='{"totals":{"minted":4,"minted_revenue":"250.00","redeemed":4,"redeemed_revenue":"250.00","unpriced":0,"undated":0},"by_day":[{"day":"DAY","minted":4,"redeemed":4,"revenue":"250.00","redeemed_revenue":"250.00"}],"by_package":[{"label":"1 Hour","minted":2,"redeemed":2,"revenue":"200.00","redeemed_revenue":"200.00"},{"label":"Student Hour","minted":2,"redeemed":2,"revenue":"50.00","redeemed_revenue":"50.00"}]}'
eq "sales_json reports the totals" \
   "$(printf '%s' "$_EXP" | "$BB" sed "s/DAY/$("$BB" date '+%Y-%m-%d')/")" \
   "$(nstore sales "$_WIN" "$((_NOW + 86400))")"
eq "sales_csv has a header, day, both packages and a total row" "5" \
   "$(nstore csv "$_WIN" "$((_NOW + 86400))" | "$BB" wc -l | "$BB" tr -d ' ')"

has 'section,key,generated,redeemed,generated_rs,redeemed_rs' \
   "$(nstore csv "$_WIN" "$((_NOW + 86400))")" "sales_csv header"
has 'total,,4,4,250.00,250.00' \
   "$(nstore csv "$_WIN" "$((_NOW + 86400))")" "sales_csv totals row"

echo "== backup"
BK=$(nstore backup)
[ -s "$BK" ] && ok "backup_create writes a file" || bad "backup_create wrote nothing"
case "$BK" in */backups/rns-*) ok "the backup lands in backups/" ;;
  *) bad "the backup is in the wrong place: $BK" ;; esac
_n=$(ls -1 "$WORK/data/backups"/rns-* 2>/dev/null | "$BB" wc -l | "$BB" tr -d ' ')
eq "a backup is kept" "1" "$_n"

echo "== voucher PDF slips"
# A structural check: the xref table must point at real objects and every
# stream length must match its bytes, or the file is not a usable PDF.
cat > "$WORK/pdfcheck.awk" <<'EOS'
# Validate a PDF without assuming anything about how it was laid out: find
# where each "N 0 obj" actually sits by scanning the bytes, then check the xref
# table agrees. The previous version assumed a fixed 20-byte xref entry stride
# and derived the entry start from the subsection header, which disagreed with
# the emitter under busybox awk 1.30 and reported every offset as wrong.
{ buf = buf $0 "\n" }
{
  # 0-based byte offset of the first byte of this record
  line = $0; s = line
  while (match(s, /[0-9]+ 0 obj/)) {
    tok = substr(s, RSTART, RLENGTH)
    n = tok + 0
    if (!(n in actual)) actual[n] = base + RSTART - 1
    s = substr(s, RSTART + RLENGTH)
  }
  base += length(line) + 1
}
END {
  ok = 1
  if (substr(buf, 1, 8) != "%PDF-1.4") { print "no header"; exit 1 }
  last = 0
  for (i = 1; i + 8 <= length(buf); i++) if (substr(buf, i, 9) == "startxref") last = i
  if (last == 0) { print "no startxref"; exit 1 }
  sx = substr(buf, last + 10, 20) + 0
  if (substr(buf, sx + 1, 4) != "xref") { print "startxref misses the table"; exit 1 }
  p = index(substr(buf, sx + 1), "\n") + sx
  hdr = substr(buf, p + 1, 20); sub(/\n.*/, "", hdr)
  split(hdr, a, " "); count = a[2] + 0
  base2 = index(substr(buf, p + 1), "\n") + p
  for (k = 0; k < count; k++) {
    e = substr(buf, base2 + k * 20 + 1, 20)
    if (length(e) < 20) { printf "xref entry %d is truncated\n", k; ok = 0; continue }
    off = substr(e, 1, 10) + 0; kind = substr(e, 18, 1)
    if (kind != "n") continue
    if (!(k in actual)) { printf "object %d: not present in the file\n", k; ok = 0; continue }
    if (off != actual[k]) {
      printf "object %d: xref says %d, really at %d\n", k, off, actual[k]
      printf "  xref region: [%s]\n", substr(buf, sx + 1, 120)
      printf "  actual:"
      for (a in actual) printf " %d@%d", a, actual[a]
      printf "\n"
      ok = 0
    }
  }
  # every object the file declares must be in the xref too
  for (n in actual) if (n + 0 > count - 1) { printf "object %d is outside the xref\n", n; ok = 0 }
  n = 0
  for (i = 1; i + 13 <= length(buf); i++) {
    if (substr(buf, i, 10) == "<</Length ") {
      j = i + 10; L = ""
      while (substr(buf, j, 1) != ">") { L = L substr(buf, j, 1); j++ }
      L = L + 0
      s2 = index(substr(buf, j), "stream\n") + j + 6
      if (substr(buf, s2 + L, 10) != "\nendstream") {
        printf "stream %d length is wrong\n", n; ok = 0
      }
      n++
    }
  }
  if (n == 0) { print "no streams"; exit 1 }
  print ok ? "ok" : "broken"
  exit ok ? 0 : 1
}
EOS
pdfcheck() { LC_ALL=C "$BB" awk -f "$WORK/pdfcheck.awk" "$1"; }

_rows="$WORK/vrows.tsv"
printf 'ABCD-1234\tStudent Hour\t3600\t2048\t1024\t%s\t%s\t25\n' "$_NOW" "$((_NOW + 3600))" > "$_rows"
printf 'WXYZ-9876\tNight Bundle\t86400\t4096\t2048\t%s\t%s\t100\n' "$_NOW" "$((_NOW + 86400))" >> "$_rows"
_p=$(nstore pdfv "$_rows" "RNS Internet")
[ -n "$_p" ] && ok "pdf_render emits a voucher slip" \
  || bad "pdf_render produced nothing [$(cat "$WORK/data/pdf.err" 2>/dev/null)]"
eq "the voucher PDF is structurally valid" "ok" "$(pdfcheck "$_p")"
has 'VOUCHER' "$(LC_ALL=C "$BB" awk '/stream$/{f=1;next} /^endstream/{f=0} f' "$_p")" "the slip says VOUCHER"
rm -f "$_p"

_rrows="$WORK/rrows.tsv"
printf 'WXYZ-9876\tStudent Hour\t3600\t2048\t1024\t%s\t%s\t25\tjazzcash\t847392016\tRN7K4Q2M\n' \
  "$_NOW" "$((_NOW + 3600))" > "$_rrows"
_p=$(nstore pdfr "$_rrows" "RNS Internet")
eq "the receipt PDF is structurally valid" "ok" "$(pdfcheck "$_p")"
has 'PAYMENT RECEIPT' "$(LC_ALL=C "$BB" awk '/stream$/{f=1;next} /^endstream/{f=0} f' "$_p")" "the slip says PAYMENT RECEIPT"
rm -f "$_p"

: > "$WORK/empty.tsv"
_p=$(nstore pdfv "$WORK/empty.tsv" "RNS Internet")
eq "an empty list still yields a valid PDF" "ok" "$(pdfcheck "$_p")"
rm -f "$_p"

echo "== hostapd_apply writes the live config"
printf 'wlan0\n' > "$WORK/data/wlan.if"
nstore cfgset SSID "My Hotspot"; nstore cfgset CHANNEL 11; nstore cfgset MAX_STA 32
nstore apconf >/dev/null 2>&1
filehas 'ssid=My Hotspot'   "$WORK/data/hostapd.conf" "hostapd_apply writes the SSID"
filehas 'channel=11'        "$WORK/data/hostapd.conf" "hostapd_apply writes the channel"
filehas 'max_num_sta=32'    "$WORK/data/hostapd.conf" "hostapd_apply writes the client limit"
filehas 'ctrl_interface=/var/run/hostapd' "$WORK/data/hostapd.conf" "hostapd_apply keeps the control socket"

# ------------------------------------------- live HTTP: the new endpoints
echo "== live HTTP: new admin endpoints (socat)"
PORT2=$((21000 + $$ % 800))
if command -v socat >/dev/null 2>&1; then
  W2="$WORK/http2"; mkdir -p "$W2"
  BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$W2" RNS_PORT=$PORT2 \
    "$BB" sh "$RNSH/bin/rns-ctl.sh" setpass hunter22 >/dev/null 2>&1
  BB=$BB RNS_LAB=1 RNS_HOME="$RNSH" RNS_DATA="$W2" RNS_PORT=$PORT2 \
    "$BB" sh "$RNSH/bin/rns-pages.sh" >/dev/null 2>&1
  sleep 1
  LPID=$(cat "$W2/httpd.pid" 2>/dev/null)
  if [ -n "${LPID:-}" ]; then
    hreq() {
      { printf '%s %s HTTP/1.0\r\nHost: t\r\nAccept: application/json\r\n' "$1" "$2"
        [ -n "${4:-}" ] && printf 'Cookie: rns=%s\r\n' "$4"
        if [ -n "${3:-}" ]; then
          printf 'Content-Type: application/x-www-form-urlencoded\r\n'
          printf 'Content-Length: %s\r\n\r\n%s' "$(printf '%s' "$3" | wc -c | tr -d ' ')" "$3"
        else printf '\r\n'; fi
      } | socat - "TCP:127.0.0.1:$PORT2" 2>/dev/null
    }
    hbody() { tr -d '\r' | "$BB" awk 'f{print} /^$/{f=1}'; }

    S=$(hreq GET /api/status)
    has '"pay_online":false' "$S" "pay_online is off until a wallet number exists"
    has '"lab_pass"' "$S" "/api/status reports the lab password"
    has '"lab_code"' "$S" "/api/status reports a lab sample code"

    hreq POST /api/login "password=hunter22" >/dev/null
    CK=$(hreq POST /api/login "password=hunter22" | "$BB" sed -n 's/.*Set-Cookie: rns=\([0-9a-f]*\).*/\1/p')
    [ -n "$CK" ] && ok "login sets a session cookie" || bad "login did not set a cookie"

    hreq POST /api/admin/packages "id=hour1&label=1%20Hour&seconds=3600&down_kbps=4000&up_kbps=1000&price=50&rate=50&rate_unit=hour" "$CK" >/dev/null
    hreq POST /api/admin/online-packages "id=op1&label=Student%20Hour&seconds=3600&down_kbps=2048&up_kbps=1024&price=25" "$CK" >/dev/null
    P=$(hreq GET /api/admin/packages "" "$CK" | hbody)
    has '"rate":"50"' "$P" "package_upsert stores the rate"
    has '"rate_unit":"hour"' "$P" "package_upsert stores the rate unit"
    O=$(hreq GET /api/admin/online-packages "" "$CK" | hbody)
    has '"id":"op1"' "$O" "online packages are listed over HTTP"

    hreq POST /api/admin/settings "jazzcash_number=0300-1234567&jazzcash_name=Ali%20Raza&pay_auto_verify=0" "$CK" >/dev/null
    S2=$(hreq GET /api/status)
    has '"pay_online":true' "$S2" "a wallet number turns pay_online on"
    ST=$(hreq GET /api/admin/settings "" "$CK" | hbody)
    has '"online_pay":1' "$ST" "settings reports online_pay as 1"
    has '"jazzcash_number":"0300-1234567"' "$ST" "settings reports the wallet number"
    has '"pay_auto_verify":0' "$ST" "settings reports pay_auto_verify as 0"
    has '"paused":false' "$ST" "settings reports the gate state"
    hreq POST /api/admin/settings "jazzcash_number=" "$CK" >/dev/null
    ST2=$(hreq GET /api/admin/settings "" "$CK" | hbody)
    has '"jazzcash_number":""' "$ST2" "an empty wallet number clears the setting"
    hreq POST /api/admin/settings "jazzcash_number=0300-1234567" "$CK" >/dev/null

    # Online payment end to end over the real socket.
    R=$(hreq POST /api/pay/init "package_id=op1&method=jazzcash" | hbody | "$BB" sed -n 's/.*"ref":"\([A-Z0-9]*\)".*/\1/p')
    [ -n "$R" ] && ok "pay_init hands out a reference" || bad "pay_init returned no reference"
    PP=$(hreq GET /api/pay/packages | hbody)
    has '"id":"op1"' "$PP" "pay/packages lists the online packages"
    has '"jazzcash_number":"0300-1234567"' "$PP" "pay/packages reports the wallet"
    SU=$(hreq POST /api/pay/submit "ref=$R&tid=847392016&package_id=op1&method=jazzcash" | hbody)
    has '"status":"pending"' "$SU" "manual mode leaves the payment pending"
    PID=$(printf '%s' "$SU" | "$BB" sed -n 's/.*"pay_id":"\([A-Z0-9]*\)".*/\1/p')
    has '"tid":"847392016"' "$(hreq GET /api/admin/payments "" "$CK" | hbody)" "the payment shows up for staff"
    has '"status":"pending"' "$(hreq GET "/api/pay/status?pay_id=$PID" | hbody)" "the customer can poll the status"
    nohas '"status":"none"' "$(hreq GET "/api/pay/status?pay_id=$PID" | hbody)" "polling finds the payment"
    hreq POST /api/admin/pay-confirm "pay_id=$PID" "$CK" >/dev/null
    CF=$(hreq GET "/api/pay/status?pay_id=$PID" | hbody)
    has '"status":"confirmed"' "$CF" "staff confirmation flips the status"
    has '"voucher_code":"' "$CF" "the confirmed payment reports its voucher"
    RC=$(hreq GET "/api/pay/receipt?pay_id=$PID" | "$BB" head -c 400)
    has 'Content-Type: application/pdf' "$RC" "the receipt is served as a PDF"
    has '%PDF-1.4' "$RC" "the receipt starts like a PDF"
    # A second device must not be able to read someone else's payment.
    hreq POST /api/admin/settings "pay_auto_verify=1" "$CK" >/dev/null

    # Sales report over HTTP.
    hreq POST /api/admin/mint "plan=hour1&count=2&note=cash" "$CK" >/dev/null
    TODAY=$("$BB" date '+%Y-%m-%d')
    SA=$(hreq GET "/api/admin/sales?from=$TODAY&to=$TODAY" "" "$CK" | hbody)
    has '"minted":3' "$SA" "the sales report counts generated codes"
    has '"minted_revenue":"125.00"' "$SA" "the sales report totals rupees"
    has '"by_day":[' "$SA" "the sales report has a per-day breakdown"
    has '"by_package":[' "$SA" "the sales report has a per-package breakdown"
    CS=$(hreq GET "/api/admin/sales.csv?from=$TODAY&to=$TODAY" "" "$CK")
    has 'Content-Type: text/csv' "$CS" "the CSV export is served as text/csv"
    has 'section,key,generated,redeemed' "$CS" "the CSV export has a header"
    has 'Content-Disposition: attachment' "$CS" "the CSV export is an attachment"

    # Voucher PDF over HTTP, both entry points.
    V1=$(hreq GET "/api/admin/vouchers.pdf?status=all" "" "$CK" | "$BB" head -c 200)
    has 'Content-Type: application/pdf' "$V1" "the voucher PDF is served as application/pdf"
    has '%PDF-1.4' "$V1" "the voucher PDF starts like a PDF"
    CODE=$(hreq GET "/api/admin/vouchers?status=new" "" "$CK" | hbody | "$BB" sed -n 's/.*"code":"\([A-Z0-9]*\)".*/\1/p' | "$BB" head -1)
    V2=$(hreq GET "/api/admin/vouchers.pdf?codes=$CODE" "" "$CK" | "$BB" head -c 200)
    has '%PDF-1.4' "$V2" "the PDF of specific codes is served"

    BKJ=$(hreq POST /api/admin/backup "x=1" "$CK" | hbody)
    has '"ok":true' "$BKJ" "backup succeeds over HTTP"
    has 'backups/rns-' "$BKJ" "backup reports where it wrote"

    # Everything staff-facing must still demand a session.
    eq "sales without a session is refused" "HTTP/1.0 401 Unauthorized" \
       "$(hreq GET /api/admin/sales | "$BB" tr -d '\r' | "$BB" head -1)"
    eq "payments without a session is refused" "HTTP/1.0 401 Unauthorized" \
       "$(hreq GET /api/admin/payments | "$BB" tr -d '\r' | "$BB" head -1)"
    eq "the voucher PDF without a session is refused" "HTTP/1.0 401 Unauthorized" \
       "$(hreq GET /api/admin/vouchers.pdf | "$BB" tr -d '\r' | "$BB" head -1)"
    eq "the CSV export without a session is refused" "HTTP/1.0 401 Unauthorized" \
       "$(hreq GET /api/admin/sales.csv | "$BB" tr -d '\r' | "$BB" head -1)"
    eq "online packages without a session is refused" "HTTP/1.0 401 Unauthorized" \
       "$(hreq GET /api/admin/online-packages | "$BB" tr -d '\r' | "$BB" head -1)"
    eq "backup without a session is refused" "HTTP/1.0 401 Unauthorized" \
       "$(hreq POST /api/admin/backup "x=1" | "$BB" tr -d '\r' | "$BB" head -1)"
    eq "pay-confirm without a session is refused" "HTTP/1.0 401 Unauthorized" \
       "$(hreq POST /api/admin/pay-confirm "pay_id=x" | "$BB" tr -d '\r' | "$BB" head -1)"

    # Online pay can be switched off entirely.
    hreq POST /api/admin/settings "jazzcash_number=" "$CK" >/dev/null
    OFF=$(hreq GET /api/pay/packages | hbody)
    has '"ok":false' "$OFF" "pay/packages refuses when no wallet is configured"
    has 'not enabled' "$OFF" "pay/packages says online payments are off"

    kill "$LPID" 2>/dev/null; LPID=""
  else
    skip "second listener did not start"
  fi
else
  skip "socat not installed — new-endpoint live tests not run"
fi
# ------------------------------------------------------------------ summary
echo
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
