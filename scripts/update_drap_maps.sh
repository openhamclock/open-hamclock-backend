#!/bin/bash
# ============================================================
#
#   ██████╗ ██╗  ██╗██████╗
#  ██╔═══██╗██║  ██║██╔══██╗
#  ██║   ██║███████║██████╔╝
#  ██║   ██║██╔══██║██╔══██╗
#  ╚██████╔╝██║  ██║██████╔╝
#   ╚═════╝ ╚═╝  ╚═╝╚═════╝
#
#  Open HamClock Backend
#  update_drap_maps.sh
#
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#
#  You should have received a copy of the GNU Affero General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# ============================================================
set -euo pipefail

export GMT_USERDIR=/opt/hamclock-backend/tmp
cd "$GMT_USERDIR"

source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes   # populates SIZES=(...) per OHB conventions

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$OUTDIR"

TXT="drap_global_frequencies.txt"

echo "Fetching DRAP..."
curl -fsSL -A "open-hamclock-backend/1.0" \
  https://services.swpc.noaa.gov/text/drap_global_frequencies.txt \
  -o "$TXT"

python3 <<'PYEOF'
with open("drap_global_frequencies.txt") as f:
    lines = f.readlines()

lons_hdr = None
rows = []
for line in lines:
    s = line.strip()
    if not s or s.startswith('#'):
        continue
    if s.startswith('---'):
        continue
    parts = s.split()
    if lons_hdr is None:
        if '|' not in s and all(p.lstrip('-').replace('.','').isdigit() for p in parts):
            lons_hdr = [float(p) for p in parts]
        continue
    parts = s.replace('|', ' ').split()
    lat = float(parts[0])
    vals = [float(x) for x in parts[1:]]
    rows.append((lat, vals))

src_lats = [r[0] for r in rows]
src_lons = lons_hdr
src = {}
for li, (lat, vals) in enumerate(rows):
    for loi, val in enumerate(vals):
        src[(li, loi)] = val

def lon_dist(a, b):
    d = abs(a - b) % 360
    return min(d, 360 - d)

def nearest_haf(lat, lon):
    best_li = min(range(len(src_lats)), key=lambda i: abs(src_lats[i] - lat))
    best_loi = min(range(len(src_lons)), key=lambda i: lon_dist(src_lons[i], lon))
    return src.get((best_li, best_loi), 0.0)

# Write dense XYZ in -180..180 range — only nonzero values so background stays black.
with open("drap.xyz", "w") as out:
    lat = 90.0
    while lat >= -90.0:
        lon = -179.5
        while lon <= 179.5:
            val = nearest_haf(lat, lon)
            if val > 0:
               out.write(f"{lon:.2f} {lat:.2f} {val:.4f}\n")
            lon += 0.5
        lat -= 0.5
PYEOF

NPTS=$(wc -l < drap.xyz)
echo "Dense grid points with absorption: $NPTS"

if [ "$NPTS" -gt 0 ]; then
    gmt nearneighbor drap.xyz -R-180/180/-90/90 -I0.5 -S3 -r -Gdrap_nn.nc
    gmt grdfilter drap_nn.nc -Fg4 -D0 -Ni -Gdrap_s1.nc
    gmt grdfilter drap_s1.nc -Fg3 -D0 -Ni -Gdrap.nc
else
    echo "No absorption data; generating quiet grid."
    gmt grdmath -R-180/180/-90/90 -I0.5 0 = drap.nc
fi

cat > drap.cpt <<'CPTEOF'
0.0    0/0/0         0.5   10/0/20
0.5   10/0/20        1.0   30/0/50
1.0   30/0/50        2.0   55/0/80
2.0   55/0/80        3.0   80/0/120
3.0   80/0/120       5.0   110/0/180
5.0   110/0/180      7.0   80/0/255
7.0   80/0/255      10.0   0/80/255
10.0  0/80/255      13.0   0/200/220
13.0  0/200/220     17.0   0/220/100
17.0  0/220/100     21.0   180/255/0
21.0  180/255/0     25.0   255/200/0
25.0  255/200/0     30.0   255/100/0
30.0  255/100/0     35.0   255/0/0
B     0/0/0
F     255/0/0
N     0/0/0
CPTEOF

zlib_compress() {
  local in="$1" out="$2"
  python3 -c "
import zlib, sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(zlib.compress(data, 9))
" "$in" "$out"
}

# Combined: apply Day haze (if needed), resize, convert to BMPv4 RGB565 top-down.
# Uses Pillow — no ImageMagick, no policy limits, no intermediate files.
make_bmp_v4_rgb565_topdown() {
  local inpng="$1" outbmp="$2" W="$3" H="$4" DN="$5"
  python3 - <<'PY' "$inpng" "$outbmp" "$W" "$H" "$DN"
import struct, sys
from PIL import Image

inpng, outbmp, W, H, DN = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]

img = Image.open(inpng).convert("RGB")

# Resize to exact target if GMT didn't produce the right dimensions
if img.size != (W, H):
    img = img.resize((W, H), Image.LANCZOS)

# Apply day haze: 205/220/205 at 20% opacity
if DN == "D":
    overlay = Image.new("RGB", img.size, (205, 220, 205))
    img = Image.blend(img, overlay, alpha=0.20)

pixels = img.tobytes()  # raw RGB, top-down

# Encode RGB888 -> RGB565 LE
pix = bytearray(W * H * 2)
j = 0
for i in range(0, len(pixels), 3):
    r, g, b = pixels[i], pixels[i+1], pixels[i+2]
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    pix[j]   = v & 0xFF
    pix[j+1] = (v >> 8) & 0xFF
    j += 2

# BMPv4 header (BITMAPV4HEADER = 108 bytes)
bfOffBits = 14 + 108
bfSize    = bfOffBits + len(pix)
filehdr   = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, bfOffBits)

rmask, gmask, bmask, amask = 0xF800, 0x07E0, 0x001F, 0x0000
v4hdr = struct.pack("<IiiHHIIIIII",
    108,        # biSize
    W, -H,      # negative height = top-down
    1, 16,      # planes, bpp
    3,          # BI_BITFIELDS compression
    len(pix),   # image size
    0, 0, 0, 0  # pels/meter, clr used/important
)
v4hdr += struct.pack("<IIII", rmask, gmask, bmask, amask)
v4hdr += struct.pack("<I", 0x73524742)  # sRGB color space
v4hdr += b"\x00" * 48                  # endpoints + gamma

with open(outbmp, "wb") as f:
    f.write(filehdr)
    f.write(v4hdr)
    f.write(pix)

print(f"  -> Done: {outbmp}")
PY
}

echo "Rendering DRAP maps..."

render_one() {
  local DN="$1" SZ="$2"
  local W=${SZ%x*}
  local H=${SZ#*x}
  local BASE="$GMT_USERDIR/drap_${DN}_${SZ}"
  local PNG="${BASE}.png"
  local BMP="$OUTDIR/map-${DN}-${SZ}-DRAP-S.bmp"

  echo "  -> ${DN} ${SZ}"

  # Render at 72 DPI so 1 point = 1 pixel; -JQ0/${W}p produces exactly W pixels wide.
  gmt begin "$BASE" png E72
    gmt set MAP_FRAME_PEN 0p PS_PAGE_COLOR black
    gmt coast -R-180/180/-90/90 -B0 -X0 -Y-0.5p -JQ0/${W}p -Gblack -Sblack -A10000

    if [ "$NPTS" -gt 0 ]; then
      gmt grdimage drap.nc -Cdrap.cpt -nn -t25
    fi

    # White linework only (transparent interiors)
    gmt coast -R-180/180/-90/90 -B0 -JQ0/${W}p -W0.5p,white -N1/0.4p,white -A10000
  gmt end || { echo "  !! gmt failed for $DN $SZ"; return 1; }

  # Haze + resize + RGB565 BMP — all in one Pillow pass, no ImageMagick
  make_bmp_v4_rgb565_topdown "$PNG" "$BMP" "$W" "$H" "$DN" \
    || { echo "  !! bmp write failed for $DN $SZ"; return 1; }

  zlib_compress "$BMP" "${BMP}.z"
  rm -f "$PNG"
}

# Render D and N bands in parallel; sizes within each band are sequential
# to avoid thrashing RAM on the Pi 3B.
for DN in D N; do
  (
    for SZ in "${SIZES[@]}"; do
      render_one "$DN" "$SZ"
    done
  ) &
done
wait

rm -f drap_nn.nc drap_s1.nc drap.nc drap.cpt drap.xyz "$TXT"

echo "OK: DRAP maps updated into $OUTDIR"
