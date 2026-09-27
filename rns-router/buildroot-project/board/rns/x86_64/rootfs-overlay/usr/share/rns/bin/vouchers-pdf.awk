# Minimal PDF writer for the voucher slips and the online-payment receipt.
#
# There is no ghostscript, no language runtime and no PDF library in the
# image, so the slips are emitted straight from awk. The output is plain
# ASCII, which keeps awk's length() equal to the byte count the xref table
# needs (the shell runs this under LC_ALL=C for the same reason).
#
#   awk -v mode=voucher|receipt -v off=<utc offset seconds> -v shop="<name>" \
#       -f vouchers-pdf.awk <rows.tsv
#
# TAB separated input:
#   voucher: display, label, seconds, down_kbps, up_kbps, created, expires, price
#   receipt: voucher_code, label, seconds, down_kbps, up_kbps, paid_at,
#            expires, amount, method, tid, ref
#
# One slip per page: staff print these and hand them to customers.

BEGIN { FS = "\t"; n = 0 }

function fdiv(a, b) { q = int(a / b); if (a % b != 0 && ((a < 0) != (b < 0))) q--; return q }

function esc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/\(/, "\\(", s)
  gsub(/\)/, "\\)", s)
  return s
}

# Epoch -> "YYYY-MM-DD HH:MM" in the router's own timezone.
function dt(ts,   local, days, z, era, doe, yoe, y, doy, mp, d, m, hh, mi) {
  if (ts !~ /^[0-9]+$/ || ts + 0 <= 0) return "-"
  local = ts + off + 0
  days = fdiv(local, 86400)
  z = days + 719468
  era = fdiv((z >= 0) ? z : z - 146096, 146097)
  doe = z - era * 146097
  yoe = fdiv(doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096), 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = mp + ((mp < 10) ? 3 : -9)
  y = y + ((m <= 2) ? 1 : 0)
  hh = int((local - days * 86400) / 3600)
  mi = int((local - days * 86400 - hh * 3600) / 60)
  return sprintf("%04d-%02d-%02d %02d:%02d", y, m, d, hh, mi)
}

function dur(sec,   d, h, m, _s) {
  sec = sec + 0
  if (sec <= 0) return "-"
  if (sec % 86400 == 0) { d = sec / 86400; _s = (d == 1) ? "" : "s"; return d " day" _s }
  if (sec % 3600 == 0) { h = sec / 3600; _s = (h == 1) ? "" : "s"; return h " hour" _s }
  m = int((sec + 59) / 60); if (m < 1) m = 1
  return m " min"
}

function spd(k,   v) {
  v = k + 0
  if (v >= 1024) return (int(v / 102.4 + 0.5) / 10) " Mbps"
  return v " Kbps"
}

function rs(p,   ip, fr) {
  if (p == "" || p !~ /^[0-9]+(\.[0-9]*)?$/) return "-"
  if (index(p, ".") > 0) {
    ip = substr(p, 1, index(p, ".") - 1)
    fr = substr(p, index(p, ".") + 1) "00"
  } else { ip = p; fr = "00" }
  sub(/^0+/, "", ip); if (ip == "") ip = "0"
  return "Rs " ip "." substr(fr, 1, 2)
}

function method_name(m) {
  if (m == "jazzcash") return "JazzCash"
  if (m == "easypaisa") return "EasyPaisa"
  if (m == "") return "-"
  return m
}

# ---- content-stream helpers -------------------------------------------------
function txt(x, y, sz, fn, t) {
  return "BT /F" fn " " sz " Tf 1 0 0 1 " x " " y " Tm (" esc(t) ") Tj ET\n"
}
function rule(x1, y1, x2, y2) { return x1 " " y1 " m " x2 " " y2 " l S\n" }
function put(s) { out = out s }
# xoff, not off: "off" is the scalar UTC offset handed in with -v off= and
# read by dt(). Reusing one name as a scalar and an array is undefined in awk
# and silently corrupts the xref table on busybox 1.30.
function obj(num) { xoff[num] = length(out); put(num " 0 obj\n") }
function objclose() { put("endobj\n") }

function body_voucher(i,   s, y, rows, k, nr) {
  s = "1 w 40 40 515 762 re S\n"
  s = s txt(56, 764, 13, 2, "RNS GATEWAY")
  s = s txt(56, 748, 9, 1, shop == "" ? "Wi-Fi hotspot" : shop)
  s = s rule(56, 738, 539, 738)
  s = s txt(56, 706, 9, 1, "VOUCHER")
  s = s txt(56, 660, 32, 2, R_disp[i])
  s = s txt(56, 636, 9, 1, "One code unlocks one device. Keep this slip.")
  s = s rule(56, 620, 539, 620)

  y = 592
  nr = split("Package|" R_label[i] "|Speed|" spd(R_down[i]) " down / " spd(R_up[i]) " up" \
        "|Duration|" dur(R_sec[i]) "|Price|" rs(R_price[i]) \
        "|Valid from|" dt(R_c[i]) "|Valid until|" dt(R_e[i]), rows, "|")
  for (k = 1; k + 1 <= nr; k += 2) {
    s = s txt(56, y, 9, 1, rows[k])
    s = s txt(210, y - 1, 12, 2, rows[k + 1])
    s = s rule(56, y - 9, 539, y - 9)
    y -= 30
  }
  s = s txt(56, 62, 8, 1, "RNS Gateway - voucher slip")
  return s
}

function body_receipt(i,   s, y, rows, k, nr) {
  s = "1 w 40 40 515 762 re S\n"
  s = s txt(56, 764, 13, 2, "RNS GATEWAY")
  s = s txt(56, 748, 9, 1, shop == "" ? "Wi-Fi hotspot" : shop)
  s = s rule(56, 738, 539, 738)
  s = s txt(56, 706, 9, 1, "PAYMENT RECEIPT")
  s = s txt(56, 660, 26, 2, R_disp[i])
  s = s txt(56, 636, 9, 1, "Payment accepted - internet is active on this device.")
  s = s rule(56, 620, 539, 620)

  y = 592
  nr = split("Package|" R_label[i] "|Speed|" spd(R_down[i]) " down / " spd(R_up[i]) " up" \
        "|Duration|" dur(R_sec[i]) "|Amount paid|" rs(R_amt[i]) \
        "|Method|" method_name(R_method[i]) "|Transaction ID|" R_tid[i] \
        "|Tracking ID|" R_ref[i] "|Paid at|" dt(R_c[i]) "|Valid until|" dt(R_e[i]), rows, "|")
  for (k = 1; k + 1 <= nr; k += 2) {
    s = s txt(56, y, 9, 1, rows[k])
    s = s txt(210, y - 1, 12, 2, rows[k + 1])
    s = s rule(56, y - 9, 539, y - 9)
    y -= 30
  }
  s = s txt(56, 62, 8, 1, "RNS Gateway - online payment receipt")
  return s
}

function body_blank(   s) {
  s = "1 w 40 40 515 762 re S\n"
  s = s txt(56, 764, 13, 2, "RNS GATEWAY")
  s = s txt(56, 748, 9, 1, shop == "" ? "Wi-Fi hotspot" : shop)
  s = s rule(56, 738, 539, 738)
  s = s txt(56, 700, 16, 2, "Nothing to print")
  s = s txt(56, 672, 10, 1, "No vouchers matched this filter.")
  return s
}

function content(i) {
  if (i > n) return body_blank()
  if (mode == "receipt") return body_receipt(i)
  return body_voucher(i)
}

{
  if (NF < 5) next
  n++
  R_disp[n] = $1; R_label[n] = $2; R_sec[n] = $3; R_down[n] = $4; R_up[n] = $5
  R_c[n] = $6; R_e[n] = $7; R_price[n] = $8
  if (mode == "receipt") {
    R_amt[n] = $8; R_method[n] = $9; R_tid[n] = $10; R_ref[n] = $11
  }
}

END {
  pages = (n > 0) ? n : 1
  out = "%PDF-1.4\n"

  obj(1); put("<</Type/Catalog/Pages 2 0 R>>"); objclose()
  kids = ""
  # No bare "name (" here: older busybox awk reads that as a call to a function
  # of that name and dies with "Call to undefined function".
  for (i = 1; i <= pages; i++) {
    _p = 3 + 2 * i
    if (kids != "") kids = kids " "
    kids = kids _p " 0 R"
  }
  obj(2); put("<</Type/Pages/Kids[" kids "]/Count " pages ">>"); objclose()
  obj(3); put("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"); objclose()
  obj(4); put("<</Type/Font/Subtype/Type1/BaseFont/Helvetica-Bold>>"); objclose()
  for (i = 1; i <= pages; i++) {
    pobj = 3 + 2 * i; cobj = 4 + 2 * i
    obj(pobj)
    put("<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]" \
        "/Resources<</Font<</F1 3 0 R/F2 4 0 R>>>>/Contents " cobj " 0 R>>")
    objclose()
    c = content(i)
    obj(cobj); put("<</Length " length(c) ">>\nstream\n"); put(c); put("\nendstream\n"); objclose()
  }

  xref = length(out)
  put("xref\n0 " (5 + 2 * pages) "\n")
  put("0000000000 65535 f \n")
  for (i = 1; i <= 4 + 2 * pages; i++) put(sprintf("%010d 00000 n \n", xoff[i]))
  put("trailer\n<</Size " (5 + 2 * pages) " /Root 1 0 R>>\nstartxref\n" xref "\n%%EOF\n")
  printf "%s", out
}
