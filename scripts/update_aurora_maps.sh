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
#  update_aurora_maps.sh
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
set -e

export GMT_USERDIR=/opt/hamclock-backend/tmp
cd $GMT_USERDIR

source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes

JSON=ovation.json
XYZ=ovation.xyz

echo "Fetching OVATION..."
curl -fs https://services.swpc.noaa.gov/json/ovation_aurora_latest.json -o "$JSON"

python3 <<'EOF'
import json
d = json.load(open("ovation.json"))
with open("ovation.xyz", "w") as f:
    for lon, lat, val in d["coordinates"]:
        if val <= 0:
            continue
        # Exclude OVATION's equatorial artifact band.
        # lat=0 is the peak row; lat=-1,-2,-3 form a noise skirt
        # that the Gaussian filter smears northward across the equator.
        if -3.0 <= lat <= 3.0:
            continue
        if lon > 180.0:
            lon -= 360.0
        f.write(f"{lon:.6f} {lat:.6f} {val:.6f}\n")
        if lon == -180.0 or lon == 180.0:
            f.write(f"-180.000000 {lat:.6f} {val:.6f}\n")
            f.write(f"180.000000 {lat:.6f} {val:.6f}\n")
EOF

echo "Gridding aurora..."
gmt nearneighbor "$XYZ" -R-180/180/-90/90 -I0.25 -S8 -Lx -Gaurora_raw.nc
gmt grdclip aurora_raw.nc -Sb0/NaN -Gaurora_preclip.nc
gmt grdfilter aurora_preclip.nc -Fg12 -D0 -Gaurora.nc
gmt grdclip aurora.nc -Sb3/NaN -Gaurora_clipped.nc

# ---------------------------------------------------------------------------
# CPT: CSI colorbar exact colors, fully opaque at every value.
# The Gaussian filter creates the feathering naturally — no alpha needed.
# Low grid values (val=1-5) map to dark/dim colors that fade into black.
# High grid values (val=20+) map to vivid green/yellow/orange/red.
# To make aurora brighter: raise the green values in the CPT.
# To make it more transparent: lower them.
# ---------------------------------------------------------------------------
python3 <<'PYEOF'
# Pure CSI colors — no blending, no alpha curve
# Night map (N): raw colors render directly on black background
# Day map (D): colors adjusted so they look the same against #4A494A gray

csi = [
    (  1,    0,   4,   0),   # val=1: nearly black — filter noise floor
    (  2,    0,   8,   0),   # val=2: very dim
    (  3,    0,  20,   0),   # val=3: dim green
    (  5,    0,  60,   0),   # val=5: faint green
    (  8,    4, 110,   4),   # val=8: dim-medium green
    ( 12,    8, 160,   8),   # val=12: medium green
    ( 18,   16, 210,  16),   # val=18: bright green
    ( 25,   32, 240,   0),   # val=25: vivid green
    ( 35,   80, 252,   0),   # val=35: vivid green-yellow
    ( 50,  248, 252,   0),   # val=50: yellow
    ( 60,  240, 196,  16),   # val=60: orange-yellow
    ( 70,  232, 136,  32),   # val=70: orange
    ( 80,  232,  84,  32),   # val=80: orange-red
    (100,  248,   0,   0),   # val=100: red
]

bg_d = (74, 73, 74)

def clamp(x): return min(255, max(0, int(round(x))))

# Dense 1-unit CPT to avoid ribbing from sparse breakpoints
def csi_color_at(v):
    for i in range(len(csi)-1):
        v0,r0,g0,b0 = csi[i]
        v1,r1,g1,b1 = csi[i+1]
        if v0 <= v <= v1:
            t = (v-v0)/(v1-v0) if v1>v0 else 0
            return (r0+t*(r1-r0), g0+t*(g1-g0), b0+t*(b1-b0))
    return csi[-1][1], csi[-1][2], csi[-1][3]

# Night CPT: raw CSI colors on black — fully opaque, filter does feathering
with open('aurora_N.cpt', 'w') as f:
    f.write('# COLOR_MODEL = RGB\n')
    for v0 in range(1, 100):
        v1 = v0 + 1
        r0,g0,b0 = csi_color_at(v0)
        r1,g1,b1 = csi_color_at(v1)
        f.write(f'{v0:3d}  {clamp(r0)}/{clamp(g0)}/{clamp(b0)}   '
                f'{v1:3d}  {clamp(r1)}/{clamp(g1)}/{clamp(b1)}\n')
    f.write('N   0/0/0\n')

# Day CPT: values below AURORA_THRESHOLD are set to exact background color
# so the Gaussian filter's outer decay tail is completely invisible against
# the day map gray. Above threshold, same vivid CSI colors as night map.
# The threshold should match the post-filter grdclip value (Sb2/NaN) — 
# anything that survives the clip renders as aurora color, not background.
BG_D = (74, 73, 74)
FADE_START = 2   # val where fade from background begins
FADE_END   = 8   # val where aurora color is fully visible

with open('aurora_D.cpt', 'w') as f:
    f.write('# COLOR_MODEL = RGB\n')
    for v0 in range(1, 100):
        v1 = v0 + 1
        r0,g0,b0 = csi_color_at(v0)
        r1,g1,b1 = csi_color_at(v1)
        # Below FADE_START: exact background color
        # Between FADE_START and FADE_END: smooth transition
        # Above FADE_END: full aurora color
        for vi, (ri,gi,bi) in [(v0,(r0,g0,b0)), (v1,(r1,g1,b1))]:
            if vi < FADE_START:
                nr,ng,nb = BG_D
            elif vi < FADE_END:
                t = (vi - FADE_START) / (FADE_END - FADE_START)
                nr = BG_D[0] + t*(ri - BG_D[0])
                ng = BG_D[1] + t*(gi - BG_D[1])
                nb = BG_D[2] + t*(bi - BG_D[2])
            else:
                nr,ng,nb = ri,gi,bi
            if vi == v0:
                r0,g0,b0 = nr,ng,nb
            else:
                r1,g1,b1 = nr,ng,nb
        f.write(f'{v0:3d}  {clamp(r0)}/{clamp(g0)}/{clamp(b0)}   '
                f'{v1:3d}  {clamp(r1)}/{clamp(g1)}/{clamp(b1)}\n')
    f.write('N   74/73/74\n')
PYEOF

make_bmp_v4_rgb565_topdown() {
  local inraw="$1" outbmp="$2" W="$3" H="$4"
  python3 - <<'PY' "$inraw" "$outbmp" "$W" "$H"
import struct, sys
inraw, outbmp, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
raw = open(inraw, "rb").read()
exp = W*H*3
if len(raw) != exp:
    raise SystemExit(f"RAW size {len(raw)} != expected {exp}")
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
cstype = 0x73524742
endpoints = b"\x00"*36
gammab = b"\x00"*12
v4hdr = struct.pack("<IiiHHIIIIII",
    biSize, W, -H, 1, 16, 3, len(pix), 0, 0, 0, 0
) + struct.pack("<IIII", rmask, gmask, bmask, amask) \
  + struct.pack("<I", cstype) + endpoints + gammab
with open(outbmp, "wb") as f:
    f.write(filehdr); f.write(v4hdr); f.write(pix)
PY
}

zlib_compress() {
  local in="$1" out="$2"
  python3 -c "
import zlib, sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(zlib.compress(data, 9))
" "$in" "$out"
}

export MAGICK_LIMIT_WIDTH=65536
export MAGICK_LIMIT_HEIGHT=65536
export MAGICK_LIMIT_AREA=4096MB
export MAGICK_LIMIT_MEMORY=2048MB
export MAGICK_LIMIT_MAP=4096MB
export MAGICK_LIMIT_DISK=8192MB
im_convert() {
  convert \
    -limit width  65536 -limit height 65536 \
    -limit area   4096MB -limit memory 2048MB \
    -limit map    4096MB -limit disk   8192MB \
    "$@"
}

echo "Rendering maps..."

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$OUTDIR"

for DN in D N; do
for SZ in "${SIZES[@]}"; do
  BASE="$GMT_USERDIR/aurora_${DN}_${SZ}"
  PNG="${BASE}.png"
  PNG_FIXED="${BASE}_fixed.png"
  BMP="$OUTDIR/map-${DN}-${SZ}-Aurora.bmp"

  W=${SZ%x*}
  H=${SZ#*x}
  MAX_RENDER=7000
  if (( W * 2 > MAX_RENDER )); then
    RENDER_W=$W; RENDER_H=$H
  else
    RENDER_W=$((W * 2)); RENDER_H=$((H * 2))
  fi

  echo "  -> ${DN} ${SZ}"

  if [[ "$DN" == "D" ]]; then
    FILL="74/73/74"
  else
    FILL="0/0/0"
  fi

  PS="${BASE}.ps"
  W_cm=$(awk "BEGIN{printf \"%.4f\", $RENDER_W * 2.54 / 72}")
  H_cm=$(awk "BEGIN{printf \"%.4f\", $RENDER_H * 2.54 / 72}")
  GMT_CONF="$GMT_USERDIR/gmtconf_aurora_${DN}_${SZ}"
  mkdir -p "$GMT_CONF"
  GMT_USERDIR="$GMT_CONF" gmt set \
    PS_MEDIA "${W_cm}cx${H_cm}c" \
    MAP_ORIGIN_X 0c \
    MAP_ORIGIN_Y 0c

  (
    cd "$GMT_USERDIR" || exit 1
    GMT_USERDIR="$GMT_CONF" \
    gmt pscoast -R-180/180/-90/90 -JQ0/${RENDER_W}p \
      -G${FILL} -S${FILL} -A10000 --MAP_FRAME_AXES= -P -K > "$PS"
    GMT_USERDIR="$GMT_CONF" \
    gmt grdimage aurora_clipped.nc -R-180/180/-90/90 -JQ0/${RENDER_W}p \
      -Caurora_${DN}.cpt -Q -n+b --MAP_FRAME_AXES= -O -K >> "$PS"
    GMT_USERDIR="$GMT_CONF" \
    gmt pscoast -R-180/180/-90/90 -JQ0/${RENDER_W}p \
      -W1.25p,white -N1/1.10p,white -A10000 --MAP_FRAME_AXES= -O -K >> "$PS"
    gmt psxy -R -J -T -O >> "$PS"
    gs -dBATCH -dNOPAUSE -dSAFER -dQUIET \
       -sDEVICE=png16m -r72 \
       -dDEVICEWIDTHPOINTS=${RENDER_W} -dDEVICEHEIGHTPOINTS=${RENDER_H} \
       -sOutputFile="$PNG" "$PS"
  ) || { echo "gmt/gs failed for ${DN} $SZ" >&2; continue; }

  im_convert "$PNG" -filter Lanczos -resize "${SZ}!" "$PNG_FIXED" \
    || { echo "resize failed for $SZ"; continue; }

  RAW="$GMT_USERDIR/aurora_${DN}_${SZ}.raw"
  im_convert "$PNG_FIXED" RGB:"$RAW" || { echo "raw extract failed for $SZ"; continue; }
  make_bmp_v4_rgb565_topdown "$RAW" "$BMP" "$W" "$H" \
    || { echo "bmp write failed for $SZ"; continue; }
  rm -f "$RAW" "$PNG" "$PNG_FIXED" "$PS"

  zlib_compress "$BMP" "${BMP}.z"
  chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true

  echo "  -> Done: $BMP"
done
done

rm -f aurora_raw.nc aurora_preclip.nc aurora.nc aurora_clipped.nc \
      aurora_D.cpt aurora_N.cpt ovation.xyz

echo "Done."
