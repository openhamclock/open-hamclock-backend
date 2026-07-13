#!/usr/bin/env bash
# kc2g_muf_heatmap.sh
# Generates MUF heatmap BMPs (RGB565, zlib-compressed) for HamClock
# Matches aurora map pipeline: D/N variants, all sizes from lib_sizes.sh
set -euo pipefail

# Skip generation if we are proxying maps from a central Alpha server
if [[ -n "${PROXY_MAPS:-}" && "${PROXY_MAPS}" != "false" ]]; then
    echo "PROXY_MAPS is set to a hostname (${PROXY_MAPS}) - skipping local map generation."
    exit 0
fi

export GMT_USERDIR=/opt/hamclock-backend/htdocs/tmp
mkdir -p "$GMT_USERDIR"
cd "$GMT_USERDIR"

PYTHON_BIN="/opt/hamclock-backend/venv/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="/usr/bin/python3"
fi

source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes
echo "Building sizes: ${OHB_SIZES_NORM}"

gmt set GMT_GRAPHICS_FORMAT png

MUFD_URL="https://prop.kc2g.com/renders/current/mufd-normal-now.geojson"
STAS_URL="https://prop.kc2g.com/api/stations.json"
OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
CPT="/opt/hamclock-backend/scripts/muf_hamclock.cpt"
R="-180/180/-90/90"

mkdir -p "$OUTDIR"

if [[ ! -f "$CPT" ]]; then
    echo "ERROR: $CPT not found" >&2; exit 1
fi

# ── 1. Fetch ───────────────────────────────────────────────────────────────────
echo "Fetching MUF data..."
curl -fsSL "$MUFD_URL" -o mufd.geojson
curl -fsSL "$STAS_URL" -o stations.json

# ── 2. Build smooth grid (once) ────────────────────────────────────────────────
python3 - << 'PYEOF'
import json, sys
import numpy as np
from datetime import datetime, timezone
from scipy.interpolate import griddata
from scipy.ndimage import gaussian_filter

# Keep calibration in sync with the markers: only recent observations feed the
# percentile stretch, otherwise stale MUF values distort the color scaling.
MAX_AGE_MINUTES = 60
MIN_CS = 25.0   # cs >= 25, or cs == -1 (no scoring) -- matches KC2G's renderer

def _parse_time(t):
    if not t:
        return None
    t = t.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(t)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt

_now = datetime.now(timezone.utc)

gj   = json.load(open("mufd.geojson"))
stas = json.load(open("stations.json"))

# Contour points
pts = []
for feat in gj["features"]:
    value = float(feat["properties"]["level-value"])
    geom  = feat["geometry"]
    coords = geom["coordinates"]
    lines = [coords] if geom["type"] == "LineString" else coords
    for line in lines:
        for lon, lat in line:
            pts.append((float(lon), float(lat), value))
pts = np.array(pts)
print(f"  Contour levels: {sorted(set(pts[:,2]))}", file=sys.stderr)

# Station range for stretch calibration (recent observations only)
sta_mufd = []
for row in stas:
    mufd = row.get("mufd") or row.get("muf")
    if mufd is None: continue
    ts = _parse_time(row.get("time"))
    if ts is None: continue
    if (_now - ts).total_seconds() / 60.0 > MAX_AGE_MINUTES: continue
    try:
        cs = float(row.get("cs"))
    except (TypeError, ValueError):
        cs = -1.0
    if 0.0 <= cs < MIN_CS: continue
    sta_mufd.append(float(mufd))
sta_mufd = np.array(sta_mufd)
sta_lo = max(5.0,  np.percentile(sta_mufd,  5))
sta_hi = min(35.0, np.percentile(sta_mufd, 95))
print(f"  Station 5–95pct: {sta_lo:.1f} – {sta_hi:.1f} MHz", file=sys.stderr)

# Interpolate at 0.5°
lons = np.linspace(-180, 180, 721)
lats = np.linspace(-90,   90, 361)
glon, glat = np.meshgrid(lons, lats)

print("  Interpolating...", file=sys.stderr)
grid = griddata(pts[:, :2], pts[:, 2], (glon, glat), method="linear")
nan_mask = np.isnan(grid)
if nan_mask.any():
    grid_nn = griddata(pts[:, :2], pts[:, 2], (glon, glat), method="nearest")
    grid[nan_mask] = grid_nn[nan_mask]
grid = gaussian_filter(grid, sigma=1.5)

c_min, c_max = grid.min(), grid.max()
grid = sta_lo + (grid - c_min) / (c_max - c_min) * (sta_hi - sta_lo)
grid = np.clip(grid, 5, 35)
print(f"  Final: {grid.min():.1f} – {grid.max():.1f} MHz", file=sys.stderr)

with open("mufd_grid.xyz", "w") as f:
    for j in range(grid.shape[0]):
        for i in range(grid.shape[1]):
            f.write(f"{lons[i]:.2f}\t{lats[j]:.2f}\t{grid[j,i]:.3f}\n")
print("  Done.", file=sys.stderr)
PYEOF

gmt xyz2grd mufd_grid.xyz -R${R} -I0.5 -Gmufd.grd
echo "  Grid: $(gmt grdinfo mufd.grd -C | awk '{print $6, "-", $7, "MHz"}')"

# ── 3. Station files (once) ────────────────────────────────────────────────────
python3 - << 'PYEOF'
import json, sys
from datetime import datetime, timezone

# Drop observations older than this. stations.json keeps the LAST reading for
# every station ever, so dead stations carry MUF values that are years old.
# KC2G's "current" render is built from very recent data; bump this to 90-120
# if the map ends up too sparse for your liking.
MAX_AGE_MINUTES = 60
# Confidence floor. The field is "cs" (GIRO C-score, 0-100), NOT "confidence".
# KC2G's own renderer keeps observations with cs >= 25, OR cs == -1 (meaning
# the ionosonde doesn't do confidence scoring). Matching that here.
MIN_CS = 25.0

def parse_time(t):
    if not t:
        return None
    t = t.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(t)
    except ValueError:
        return None
    if dt.tzinfo is None:          # naive timestamps are UTC
        dt = dt.replace(tzinfo=timezone.utc)
    return dt

now = datetime.now(timezone.utc)

with open("stations.json") as fh:
    data = json.load(fh)

circles, labels = [], []
kept = stale = other = 0
for row in data:
    st   = row.get("station", {})
    lon  = st.get("longitude")
    lat  = st.get("latitude")
    mufd = row.get("mufd") or row.get("muf")
    if lon is None or lat is None or mufd is None:
        other += 1; continue

    ts = parse_time(row.get("time"))
    if ts is None:
        other += 1; continue
    if (now - ts).total_seconds() / 60.0 > MAX_AGE_MINUTES:
        stale += 1; continue

    try:
        cs = float(row.get("cs"))
    except (TypeError, ValueError):
        cs = -1.0
    if 0.0 <= cs < MIN_CS:         # scored but essentially no confidence
        other += 1; continue

    lon = float(lon); lat = float(lat); mufd = float(mufd)
    circles.append(f"{lon:.3f}\t{lat:.3f}\t{mufd:.2f}")
    labels.append( f"{lon:.3f}\t{lat:.3f}\t{mufd:.0f}")
    kept += 1

with open("stations_circles.txt", "w") as f:
    f.write("\n".join(circles) + "\n")
with open("stations_labels.txt", "w") as f:
    f.write("\n".join(labels) + "\n")
print(f"  {kept} stations kept | {stale} dropped (older than {MAX_AGE_MINUTES} min) "
      f"| {other} dropped (missing/low-cs)", file=sys.stderr)
PYEOF

# ── 4. Render each DN variant × size ──────────────────────────────────────────
echo "Rendering maps..."

for DN in D N; do
    for SZ in "${SIZES[@]}"; do

        W="${SZ%%x*}"
        H="${SZ##*x}"
        BASE="muf_${DN}_${SZ}"
        PNG="${BASE}.png"
        PNG_FIXED="${BASE}_fixed.png"
        BMP="${BASE}.bmp"
        F_BMP="${OUTDIR}/map-${DN}-${SZ}-MUF-RT.bmp"
        F_Z="${OUTDIR}/map-${DN}-${SZ}-MUF-RT.bmp.z"

        echo "  -> ${DN} ${SZ}"

        # Scale marker/font/line sizes relative to 660px baseline
        W_IN=$(echo "scale=4; $W / 100" | bc)
        CIRCLE_IN=$(echo "scale=4; 0.15 * $W / 660" | bc)
        FONT_PT=$(echo "scale=0; 6 * $W / 660" | bc)
        COAST_PT=$(echo "scale=4; 0.6 * $W / 660" | bc)
        BORDER_PT=$(echo "scale=4; 0.4 * $W / 660" | bc)
        CONTOUR_PT=$(echo "scale=4; 0.5 * $W / 660" | bc)
        J="Q0/${W_IN}i"

        gmt begin "$BASE" png E100
            gmt set MAP_FRAME_TYPE=plain MAP_FRAME_WIDTH=0p MAP_FRAME_PEN=0p,white
            # Black base
            gmt coast -R${R} -J${J} -Gblack -Sblack -Dc --MAP_FRAME_PEN=0p
            # MUF heatmap
            gmt grdimage mufd.grd -R${R} -J${J} -C${CPT} -Q
            # Day white veil (D maps only)
            if [[ "$DN" == "D" ]]; then
                gmt coast -R${R} -J${J} -Gwhite -Swhite -Dc -t80 --MAP_FRAME_PEN=0p
            fi
            # Coastlines + borders
            gmt coast -R${R} -J${J} -W${COAST_PT}p,black -N1/${BORDER_PT}p,black -Dc
            # Contour lines
            gmt grdcontour mufd.grd -R${R} -J${J} -C2 -W${CONTOUR_PT}p,white@60 -S4
            # Station circles + labels
            gmt plot stations_circles.txt -R${R} -J${J} \
                -Sc${CIRCLE_IN}i -G0/200/0 -W0.5p,black
            gmt text stations_labels.txt  -R${R} -J${J} \
                -F+f${FONT_PT}p,Helvetica-Bold,black+jCM
        gmt end || { echo "    gmt failed for ${DN} ${SZ}"; continue; }

        # Resize to exact pixel dimensions
        convert "$PNG" -resize "${SZ}!" "$PNG_FIXED" \
            || { echo "    resize failed for ${DN} ${SZ}"; continue; }

        # Extract raw RGB bytes, then write proper BMPv4 RGB565 top-down
        RAW="${BASE}.raw"
        convert "$PNG_FIXED" RGB:"$RAW" || { echo "    raw extract failed for ${DN} ${SZ}"; continue; }
        python3 - << EOF
import struct, sys
from PIL import Image, ImageEnhance
inraw, outbmp, W, H, DN = "$RAW", "$BMP", int($W), int($H), "$DN"

raw = open(inraw, "rb").read()
exp = W*H*3
if len(raw) != exp:
    raise SystemExit(f"RAW size {len(raw)} != expected {exp}")

# Darken Night image so the grayline is visible.
# MUF-RT has global coverage so D and N are naturally very similar (N/D=0.84).
# Applying 0.44 brings N/D to 0.37, matching DRAP's grayline contrast.
if DN == "N":
    img = Image.frombytes("RGB", (W, H), raw)
    raw = ImageEnhance.Brightness(img).enhance(0.44).tobytes()

pix = bytearray(W*H*2)
j = 0
for i in range(0, len(raw), 3):
    r = raw[i]; g = raw[i+1]; b = raw[i+2]
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    pix[j:j+2] = struct.pack("<H", v)
    j += 2

bfOffBits = 14 + 108
bfSize = bfOffBits + len(pix)
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, bfOffBits)

biSize = 108
rmask, gmask, bmask, amask = 0xF800, 0x07E0, 0x001F, 0x0000
cstype = 0x73524742  # sRGB
endpoints = b"\x00"*36
gamma = b"\x00"*12

v4hdr = struct.pack("<IiiHHIIIIII",
    biSize, W, -H, 1, 16, 3, len(pix), 0, 0, 0, 0
) + struct.pack("<IIII", rmask, gmask, bmask, amask) \
  + struct.pack("<I", cstype) + endpoints + gamma

with open(outbmp, "wb") as f:
    f.write(filehdr)
    f.write(v4hdr)
    f.write(pix)
EOF
        rm -f "$RAW"
        # Zlib compress
        python3 - << EOF
import zlib
data = open("$BMP", "rb").read()
open("${BMP}.z", "wb").write(zlib.compress(data, 9))
EOF

        mv "$BMP" "$F_BMP"
        mv "${BMP}.z" "$F_Z"
        chmod 0644 "$F_BMP" "$F_Z" 2>/dev/null || true

        echo "    -> ${F_BMP} and ${F_Z}"

        # Clean up intermediates for this size
        rm -f "$PNG" "$PNG_FIXED"

    done
done

# ── 5. Clean up shared intermediates ──────────────────────────────────────────
rm -f mufd.geojson stations.json mufd_grid.xyz mufd.grd \
      stations_circles.txt stations_labels.txt

echo "Sleeping for 30 seconds..."
sleep 30
echo "Done."
