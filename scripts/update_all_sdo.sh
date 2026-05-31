#!/usr/bin/env bash
# update_all_sdo.sh
# Fetch SDO "latest" JPEG products, generate BMP3 squares for all sizes,
# then zlib-compress to .bmp.z for HamClock.

set -euo pipefail

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/SDO"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need curl
need convert
need python3

mkdir -p "$OUTDIR"
mkdir -p "$TMPDIR"

# Sizes HamClock uses across builds
SIZES=(170 340 510 680)

BASE="https://sdo.gsfc.nasa.gov/assets/img/latest"

SOURCES=(
  "COMP|${BASE}/latest_1024_211193171.jpg|f_211_193_171_{S}.bmp"
  "HMIB|${BASE}/latest_1024_HMIB.jpg|latest_{S}_HMIB.bmp"
  "HMIIC|${BASE}/latest_1024_HMIIC.jpg|latest_{S}_HMIIC.bmp"
  "A131|${BASE}/latest_1024_0131.jpg|f_131_{S}.bmp"
  "A193|${BASE}/latest_1024_0193.jpg|f_193_{S}.bmp"
  "A211|${BASE}/latest_1024_0211.jpg|f_211_{S}.bmp"
  "A304|${BASE}/latest_1024_0304.jpg|f_304_{S}.bmp"
)

ALT_BASE="https://suntoday.lmsal.com/sdomedia/SunInTime/mostrecent"
 
ALT_SOURCES=(
  "COMP|${ALT_BASE}/l_211_193_171.jpg|f_211_193_171_{S}.bmp"
  "HMIB|${ALT_BASE}/t_HMImag.jpg|latest_{S}_HMIB.bmp"
  "HMIIC|${ALT_BASE}/t_HMI_cont_aiascale.jpg|latest_{S}_HMIIC.bmp"
  "A131|${ALT_BASE}/t0131.jpg|f_131_{S}.bmp"
  "A193|${ALT_BASE}/t0193.jpg|f_193_{S}.bmp"
  "A211|${ALT_BASE}/t0211.jpg|f_211_{S}.bmp"
  "A304|${ALT_BASE}/t0304.jpg|f_304_{S}.bmp"
)

zwrite() {
  local in="$1"
  local out="$2"
  python3 - "$in" "$out" <<'PY'
import sys, zlib
inp, outp = sys.argv[1], sys.argv[2]
data = open(inp, "rb").read()
open(outp, "wb").write(zlib.compress(data, 9))
PY
}

verify_bmp() {
  local bmp="$1"
  python3 - "$bmp" <<'PY'
import sys
p=sys.argv[1]
with open(p,'rb') as f:
    sig=f.read(2)
if sig != b'BM':
    raise SystemExit(f"BAD BMP signature for {p}: {sig!r}")
PY
}

for entry in "${SOURCES[@]}"; do
    IFS='|' read -r key url tmpl <<<"$entry"

    jpg="$TMPDIR/${key}.jpg"

    echo "Fetching $key ..."
    curl -fsS -A "open-hamclock-backend/1.0" --retry 2 --retry-delay 2 "$url" -o "$jpg"
    if [ $? -ne 0 ]; then
        echo "NASA source failed for $key. Trying alternate suntoday..."
        curl -kfsS -A "open-hamclock-backend/1.0" --retry 2 --retry-delay 2 "$url" -o "$jpg" || continue
        if [ $? -ne 0 ]; then
            echo "Alternate suntoday source failed for $key. Moving on."
            continue
        fi
    fi

    for S in "${SIZES[@]}"; do
        outbmp="${OUTDIR}/${tmpl/\{S\}/$S}"
        outz="${outbmp}.z"

        convert "$jpg" \
            -alpha off -type TrueColor \
            -resize "${S}x${S}!" \
            "BMP3:$outbmp"

        verify_bmp "$outbmp"
        zwrite "$outbmp" "$outz"
        chmod 0644 "$outbmp" "$outz"
    done
done

echo "OK: SDO artifacts updated in $OUTDIR"
