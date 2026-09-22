#!/usr/bin/env bash
# update_all_sdo.sh
# Fetch SDO "latest" JPEG products, generate BMP3 squares for all sizes,
# then zlib-compress to .bmp.z for HamClock.

set -euo pipefail

OUTDIR="${OUTDIR:-/opt/hamclock-backend/htdocs/ham/HamClock/SDO}"
TMPROOT="${TMPROOT:-/opt/hamclock-backend/htdocs/tmp}"
mkdir -p "$TMPROOT" 2>/dev/null || TMPROOT="/tmp"
TMPDIR="$(mktemp -d -p "$TMPROOT" sdo.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need curl
need python3

if command -v magick >/dev/null 2>&1; then
    CONVERT="magick"
elif command -v convert >/dev/null 2>&1; then
    CONVERT="convert"
else
    echo "ERROR: missing ImageMagick (magick or convert)" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

# Sizes HamClock uses across builds
SIZES=(170 340 510 680)

BASE="https://suntoday.lmsal.com/sdomedia/SunInTime/mostrecent"

SOURCES=(
    "COMP|${BASE}/l_211_193_171.jpg|f_211_193_171_{S}.bmp"
    "HMIB|${BASE}/t_HMImag.jpg|latest_{S}_HMIB.bmp"
    "HMIIC|${BASE}/t_HMI_cont_aiascale.jpg|latest_{S}_HMIIC.bmp"
    "A131|${BASE}/t0131.jpg|f_131_{S}.bmp"
    "A193|${BASE}/t0193.jpg|f_193_{S}.bmp"
    "A211|${BASE}/t0211.jpg|f_211_{S}.bmp"
    "A304|${BASE}/t0304.jpg|f_304_{S}.bmp"
)

ALT_BASE="https://sdo.gsfc.nasa.gov/assets/img/latest"

ALT_SOURCES=(
    "COMP|${ALT_BASE}/latest_1024_211193171.jpg|f_211_193_171_{S}.bmp"
    "HMIB|${ALT_BASE}/latest_1024_HMIB.jpg|latest_{S}_HMIB.bmp"
    "HMIIC|${ALT_BASE}/latest_1024_HMIIC.jpg|latest_{S}_HMIIC.bmp"
    "A131|${ALT_BASE}/latest_1024_0131.jpg|f_131_{S}.bmp"
    "A193|${ALT_BASE}/latest_1024_0193.jpg|f_193_{S}.bmp"
    "A211|${ALT_BASE}/latest_1024_0211.jpg|f_211_{S}.bmp"
    "A304|${ALT_BASE}/latest_1024_0304.jpg|f_304_{S}.bmp"
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

declare -A ALT_URLS
for entry in "${ALT_SOURCES[@]}"; do
    IFS='|' read -r k u _ <<<"$entry"
    ALT_URLS["$k"]="$u"
done

for entry in "${SOURCES[@]}"; do
    IFS='|' read -r key url tmpl <<<"$entry"
    alt_url="${ALT_URLS[$key]:-}"

    jpg="$TMPDIR/${key}.jpg"

    echo "Fetching $key ..."
    if ! curl -kfsS -A "open-hamclock-backend/1.0" --retry 2 --retry-delay 2 "$url" -o "$jpg"; then
        echo "Primary suntoday source failed for $key. Trying alternate NASA..."
        if [ -n "$alt_url" ] && curl -kfsS -A "open-hamclock-backend/1.0" --retry 2 --retry-delay 2 "$alt_url" -o "$jpg"; then
            echo "Successfully fetched $key from alternate NASA source."
        else
            echo "Alternate NASA source failed for $key. Moving on."
            continue
        fi
    fi

    for S in "${SIZES[@]}"; do
        fn="${tmpl/\{S\}/$S}"
        tmpbmp="${TMPDIR}/${fn}"
        tmpz="${tmpbmp}.z"
        outbmp="${OUTDIR}/${fn}"
        outz="${outbmp}.z"

        # Black out lower-left corner (timestamp metadata area) so HamClock overlays (e.g. S@) render cleanly
        x_max=$(( S * 48 / 100 ))
        y_min=$(( S * 90 / 100 ))

        "$CONVERT" "$jpg" \
            -alpha off -type TrueColor \
            -resize "${S}x${S}!" \
            -fill black -draw "rectangle 0,${y_min} ${x_max},${S}" \
            "BMP3:$tmpbmp"

        verify_bmp "$tmpbmp"
        zwrite "$tmpbmp" "$tmpz"

        mv "$tmpbmp" "$outbmp"
        mv "$tmpz" "$outz"
        chmod 0644 "$outbmp" "$outz"
    done
done

echo "OK: SDO artifacts updated in $OUTDIR"
