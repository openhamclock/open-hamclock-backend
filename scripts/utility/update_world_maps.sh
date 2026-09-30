#!/bin/bash
# update_world_maps.sh
# Generates three map types for HamClock-compatible use:
#   1. Countries map  (political borders, day/night variants)
#   2. Terrain relief map (ETOPO/SRTM shaded relief, day/night variants)
#   3. Physical map   (Natural Earth land cover & NASA city lights, day/night variants)
#
# Output: BMP (RGB565, V4 header, top-down) + zlib-compressed .bmp.z
# Sizes: 660x330 1320x660 1980x990 2640x1320 3960x1980 5280x2640 5940x2970 7920x3960

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

if [[ -z "$GMT_USERDIR" ]]; then
  if [[ -w "/opt/hamclock-backend" ]]; then
    GMT_USERDIR="/opt/hamclock-backend/tmp"
  else
    GMT_USERDIR="${SCRIPT_DIR}/../../tmp/gmt"
  fi
fi
if [[ -z "$OUTDIR" ]]; then
  if [[ -d "/opt/hamclock-backend/htdocs/ham/HamClock/maps" && -w "/opt/hamclock-backend/htdocs/ham/HamClock/maps" ]]; then
    OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
  elif [[ -w "/opt/hamclock-backend" ]]; then
    OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
  else
    OUTDIR="${SCRIPT_DIR}/../../htdocs/ham/HamClock/maps"
  fi
fi

mkdir -p "$GMT_USERDIR" "$OUTDIR"
cd "$GMT_USERDIR"

ALL_SIZES=(
  "660x330"
  "1320x660"
  "1980x990"
  "2640x1320"
  "3960x1980"
  "5280x2640"
  "5940x2970"
  "7920x3960"
)

# Allow sizes and map types to be filtered via arguments:
#   ./update_world_maps.sh [size ...] [--type Countries|Terrain|Physical] [--day] [--night] [--force]
#
# Examples:
#   ./update_world_maps.sh                          # all sizes, all 3 types, D+N
#   ./update_world_maps.sh 660x330                  # one size only
#   ./update_world_maps.sh --type Physical 2640x1320 # physical only, one size
#   ./update_world_maps.sh --type Terrain 1320x660  # terrain only, one size
#   ./update_world_maps.sh --day 660x330            # day variant only
#   ./update_world_maps.sh --type Countries --night # countries night, all sizes
#   ./update_world_maps.sh --force                  # bypass preservation and force regenerate

SIZES=()
FILTER_TYPES=()
FILTER_DN=()
FORCE=false
RECOMPUTE=false
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --type)
      i=$(( i+1 ))
      FILTER_TYPES+=("${!i}") ;;
    --day)   FILTER_DN+=("D") ;;
    --night) FILTER_DN+=("N") ;;
    --force) FORCE=true ;;
    --recompute) RECOMPUTE=true ;;
    --cpt)
      i=$(( i+1 ))
      TERRAIN_CPT_DAY="${!i}"
      RECOMPUTE=true ;;
    --phys-night-dim)
      i=$(( i+1 ))
      PHYSICAL_NIGHT_BRIGHTNESS="${!i}"
      RECOMPUTE=true ;;
    *x*)     SIZES+=("$arg") ;;
    *)       echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
  i=$(( i+1 ))
done

[[ ${#SIZES[@]}        -eq 0 ]] && SIZES=("${ALL_SIZES[@]}")
[[ ${#FILTER_TYPES[@]} -eq 0 ]] && FILTER_TYPES=("Countries" "Terrain" "Physical")
[[ ${#FILTER_DN[@]}    -eq 0 ]] && FILTER_DN=("D" "N")

# Terrain CPT defaults (day uses geo)
# Override with --cpt <name>, e.g.: --cpt srtm
# Available GMT built-ins worth trying: geo srtm dem1 dem2 etopo1 relief globe
TERRAIN_CPT_DAY="${TERRAIN_CPT_DAY:-geo}"

# Physical Night land cover brightness factor (default 0.20 for subtle nighttime terrain visibility)
# Override with --phys-night-dim <factor> (e.g. 0.18, 0.20, 0.22)
PHYSICAL_NIGHT_BRIGHTNESS="${PHYSICAL_NIGHT_BRIGHTNESS:-0.20}"

echo "Sizes   : ${SIZES[*]}"
echo "Types   : ${FILTER_TYPES[*]}"
echo "Variants: ${FILTER_DN[*]}"
echo "Force   : ${FORCE}"
echo "CPT day : ${TERRAIN_CPT_DAY}"
echo "Phys dim: ${PHYSICAL_NIGHT_BRIGHTNESS}"
echo "Outdir  : ${OUTDIR}"

# ---------------------------------------------------------------------------
# ImageMagick resource limits
# ---------------------------------------------------------------------------
export MAGICK_LIMIT_WIDTH=65536
export MAGICK_LIMIT_HEIGHT=65536
export MAGICK_LIMIT_AREA=4096MB
export MAGICK_LIMIT_MEMORY=2048MB
export MAGICK_LIMIT_MAP=4096MB
export MAGICK_LIMIT_DISK=8192MB

im_convert() {
  convert \
    -limit width    65536  \
    -limit height   65536  \
    -limit area     4096MB \
    -limit memory   2048MB \
    -limit map      4096MB \
    -limit disk     8192MB \
    "$@"
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

make_bmp_v4_rgb565_topdown() {
  local inpng="$1" outbmp="$2" W="$3" H="$4"
  python3 - <<'PY' "$inpng" "$outbmp" "$W" "$H"
import struct, sys
from PIL import Image
inpng, outbmp, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

img = Image.open(inpng).convert("RGB")
if img.size != (W, H):
    img = img.resize((W, H), Image.LANCZOS)

raw = img.tobytes()
row_bytes = W * 2
pad = (4 - (row_bytes % 4)) % 4
image_size = (row_bytes + pad) * H
bfSize = 14 + 108 + image_size
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, 14 + 108)
v4hdr = struct.pack(
    "<IiiHHIIIIII",
    108, W, -H, 1, 16, 3, image_size, 0, 0, 0, 0
) + struct.pack("<IIII", 0xF800, 0x07E0, 0x001F, 0x0000) \
  + struct.pack("<I", 0x73524742) + (b"\x00" * 36) + (b"\x00" * 12)

pix = bytearray(image_size)
di, oi = 0, 0
for y in range(H):
    for x in range(W):
        r = raw[di]; g = raw[di+1]; b = raw[di+2]; di += 3
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        pix[oi] = v & 0xFF
        pix[oi+1] = (v >> 8) & 0xFF
        oi += 2
    oi += pad

bmp_data = filehdr + v4hdr + bytes(pix)
with open(outbmp, "wb") as f:
    f.write(bmp_data)
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

# Rasterize a PostScript file to PNG via Ghostscript, then resize + convert to BMP
render_ps_to_bmp() {
  local PS="$1" PNG="$2" PNG_FIXED="$3" BMP="$4" RENDER_W="$5" RENDER_H="$6" W="$7" H="$8" SZ="$9"

  gs -dBATCH -dNOPAUSE -dSAFER -dQUIET \
     -sDEVICE=png16m \
     -r72 \
     -dDEVICEWIDTHPOINTS=${RENDER_W} \
     -dDEVICEHEIGHTPOINTS=${RENDER_H} \
     -sOutputFile="$PNG" \
     "$PS" || { echo "  gs failed for $SZ" >&2; return 1; }

  im_convert "$PNG" -filter Lanczos -resize "${SZ}!" "$PNG_FIXED" \
    || { echo "  resize failed for $SZ" >&2; return 1; }

  make_bmp_v4_rgb565_topdown "$PNG_FIXED" "$BMP" "$W" "$H" \
    || { echo "  bmp write failed for $SZ" >&2; return 1; }

  rm -f "$PNG" "$PNG_FIXED" "$PS"

  zlib_compress "$BMP" "${BMP}.z"
  chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Lazy GMT DEM & Hillshade Initialization (only run if Terrain Day is rendered)
# ---------------------------------------------------------------------------
ETOPO_NC="$GMT_USERDIR/etopo_world.nc"
SHADE_NC="$GMT_USERDIR/hillshade.nc"

init_terrain_gmt() {
  if [[ -f "$GMT_USERDIR/terrain_D.cpt" && -f "$SHADE_NC" && -f "$ETOPO_NC" ]]; then
    return 0
  fi
  echo "Initializing GMT DEM and hillshade data for Terrain Day..."
  gmt makecpt -C"${TERRAIN_CPT_DAY}" -T-8000/8000 -Z > "$GMT_USERDIR/terrain_D.cpt"

  if [[ ! -f "$ETOPO_NC" ]]; then
    echo "Fetching ETOPO terrain grid from GMT server..."
    # GMT's @earth_relief_10m is the 10 arc-minute global relief model (~17 MB).
    gmt grdcut @earth_relief_10m -R-180/180/-90/90 -G"$ETOPO_NC" \
      || { echo "gmt earth_relief download failed — check internet / GMT data server" >&2; exit 1; }
    echo "  Terrain grid saved: $ETOPO_NC"
  fi

  SHADE_RAW="$GMT_USERDIR/hillshade_raw.nc"
  if [[ ! -f "$SHADE_NC" ]]; then
    echo "Computing hillshade (dual-azimuth + histogram equalisation)..."
    gmt grdgradient "$ETOPO_NC" -A315/45 -Ne0.6 -G"$SHADE_RAW"
    gmt grdhisteq "$SHADE_RAW" -G"$SHADE_NC" -N
    MAXVAL=$(gmt grdinfo "$SHADE_NC" -C | awk '{print $7}')
    gmt grdmath "$SHADE_NC" "$MAXVAL" DIV = "$SHADE_NC"
    rm -f "$SHADE_RAW"
    echo "  Hillshade precomputed: $SHADE_NC"
  fi
}

# ---------------------------------------------------------------------------
# Raw NASA City Lights Retrieval & Local Cache
# ---------------------------------------------------------------------------
ensure_raw_city_lights() {
  local sz="$1"
  local target="$GMT_USERDIR/city_lights_${sz}.bmp"
  if [[ -f "$target" && -s "$target" ]]; then
    return 0
  fi
  local tc_candidates=(
    "docker/ohb-maps.tar.zst"
    "/opt/hamclock-backend/docker/ohb-maps.tar.zst"
    "${SCRIPT_DIR}/../../docker/ohb-maps.tar.zst"
  )
  for tc in "${tc_candidates[@]}"; do
    if [[ -f "$tc" ]]; then
      tar --zstd -xOf "$tc" "maps/map-N-${sz}-Physical.bmp" > "$target" 2>/dev/null || true
      if [[ -s "$target" ]]; then
        return 0
      fi
      tar --zstd -xOf "$tc" "maps/map-N-2640x1320-Physical.bmp" > "$target" 2>/dev/null || true
      if [[ -s "$target" ]]; then
        return 0
      fi
    fi
  done
  echo "  -> Fetching source NASA city lights for ${sz} from GitHub release..."
  python3 - <<PY "$sz" "$target"
import sys, urllib.request, zstandard, tarfile
sz, target = sys.argv[1], sys.argv[2]
url = "https://github.com/openhamclock/open-hamclock-backend/releases/download/maps-v3/ohb-maps.tar.zst"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
resp = urllib.request.urlopen(req, timeout=60)
dctx = zstandard.ZstdDecompressor()
with dctx.stream_reader(resp) as reader:
    with tarfile.open(fileobj=reader, mode="r|") as tar:
        for member in tar:
            if member.name in (f"maps/map-N-{sz}-Physical.bmp", "maps/map-N-2640x1320-Physical.bmp"):
                with open(target, "wb") as f:
                    f.write(tar.extractfile(member).read())
                break
PY
  [[ -s "$target" ]] && return 0
  echo "  Warning: could not locate source NASA city lights for ${sz}" >&2
  return 1
}

# ===========================================================================
#  LOOP: map types x day/night x sizes
# ===========================================================================

for MAPTYPE in "${FILTER_TYPES[@]}"; do
for DN in "${FILTER_DN[@]}"; do
  echo ""
  echo "=== ${MAPTYPE} / ${DN} ==="

  for SZ in "${SIZES[@]}"; do
    W=${SZ%x*}
    H=${SZ#*x}

    BMP="$OUTDIR/map-${DN}-${SZ}-${MAPTYPE}.bmp"
    BMP_Z="${BMP}.z"

    # 1. Preservation check
    if [[ -f "$BMP" && -f "$BMP_Z" && "$FORCE" != "true" ]]; then
      echo "  -> Preserving existing ${MAPTYPE} ${DN} map: $BMP"
      continue
    fi

    echo "  -> Generating ${MAPTYPE} ${DN} ${SZ}..."

    # 2. Extract exact pre-built artifact from release archive if available
    # Note: map-N-*-Physical in older archives is the raw uncomposited NASA lights source,
    # so we do not extract it directly as the final Physical Night map.
    if [[ "$RECOMPUTE" != "true" && "$FORCE" != "true" ]]; then
      if [[ "$MAPTYPE" != "Physical" || "$DN" != "N" ]]; then
        TAR_CANDIDATES=(
          "docker/ohb-maps.tar.zst"
          "/opt/hamclock-backend/docker/ohb-maps.tar.zst"
          "${SCRIPT_DIR}/../../docker/ohb-maps.tar.zst"
        )
        EXTRACTED=false
        for tc in "${TAR_CANDIDATES[@]}"; do
          if [[ -f "$tc" ]]; then
            if tar --zstd -xOf "$tc" "maps/map-${DN}-${SZ}-${MAPTYPE}.bmp" > "$BMP" 2>/dev/null; then
              if [[ -s "$BMP" ]]; then
                tar --zstd -xOf "$tc" "maps/map-${DN}-${SZ}-${MAPTYPE}.bmp.z" > "$BMP_Z" 2>/dev/null || zlib_compress "$BMP" "$BMP_Z"
                chmod 0644 "$BMP" "$BMP_Z" 2>/dev/null || true
                echo "  -> Extracted exact match from $tc: $BMP (+${BMP_Z})"
                EXTRACTED=true
                break
              fi
            fi
          fi
        done
        if [[ "$EXTRACTED" == "true" ]]; then
          continue
        fi
      fi
    fi

    # -----------------------------------------------------------------
    # 3a. PHYSICAL DAY (Natural Earth land cover)
    # -----------------------------------------------------------------
    if [[ "$MAPTYPE" == "Physical" && "$DN" == "D" ]]; then
      python3 - <<'PY' "$DN" "$SZ" "$BMP" "$BMP_Z" "$OUTDIR"
import os, sys, zlib, struct, subprocess
from io import BytesIO
from PIL import Image
import numpy as np

DN, SZ, out_bmp, out_z, outdir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
W, H = map(int, SZ.split("x"))

def write_bmp(img, bmp_path, z_path):
    raw = img.tobytes()
    row_bytes = W * 2
    pad = (4 - (row_bytes % 4)) % 4
    image_size = (row_bytes + pad) * H
    bfSize = 14 + 108 + image_size
    filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, 14 + 108)
    v4hdr = struct.pack(
        "<IiiHHIIIIII",
        108, W, -H, 1, 16, 3, image_size, 0, 0, 0, 0
    ) + struct.pack("<IIII", 0xF800, 0x07E0, 0x001F, 0x0000) \
      + struct.pack("<I", 0x73524742) + (b"\x00" * 36) + (b"\x00" * 12)

    pix = bytearray(image_size)
    di, oi = 0, 0
    for y in range(H):
        for x in range(W):
            r = raw[di]; g = raw[di+1]; b = raw[di+2]; di += 3
            v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            pix[oi] = v & 0xFF
            pix[oi+1] = (v >> 8) & 0xFF
            oi += 2
        oi += pad

    bmp_data = filehdr + v4hdr + bytes(pix)
    with open(bmp_path, "wb") as f:
        f.write(bmp_data)
    with open(z_path, "wb") as f:
        f.write(zlib.compress(bmp_data, 9))

# 1. Search in outdir or standard locations for a master physical map to downscale from
src_img = None
ALL_SIZES_REV = ["7920x3960", "5940x2970", "5280x2640", "3960x1980", "2640x1320", "1980x990", "1320x660", "660x330"]
search_dirs = [outdir, "/opt/hamclock-backend/htdocs/ham/HamClock/maps", "/var/www/html/ham/HamClock/maps", os.path.expanduser("~/devel/open-hamclock-backend/htdocs/ham/HamClock/maps")]
for sdir in search_dirs:
    if not os.path.isdir(sdir):
        continue
    for msz in ALL_SIZES_REV:
        mW, mH = map(int, msz.split("x"))
        if mW < W or mH < H:
            continue
        mbmp = os.path.join(sdir, f"map-{DN}-{msz}-Physical.bmp")
        mz = os.path.join(sdir, f"map-{DN}-{msz}-Physical.bmp.z")
        if os.path.isfile(mbmp):
            src_img = Image.open(mbmp).convert("RGB")
            break
        if os.path.isfile(mz):
            src_img = Image.open(BytesIO(zlib.decompress(open(mz, "rb").read()))).convert("RGB")
            break
    if src_img is not None:
        break

# 2. Check local tarballs if not found in outdir
if src_img is None:
    tar_candidates = [
        "docker/ohb-maps.tar.zst",
        "/opt/hamclock-backend/docker/ohb-maps.tar.zst",
        os.path.expanduser("~/devel/open-hamclock-backend/docker/ohb-maps.tar.zst"),
    ]
    for tc in tar_candidates:
        if os.path.isfile(tc):
            try:
                raw = subprocess.check_output(["tar", "--zstd", "-xOf", tc, f"maps/map-{DN}-{SZ}-Physical.bmp"], stderr=subprocess.DEVNULL)
                src_img = Image.open(BytesIO(raw)).convert("RGB")
                break
            except Exception:
                try:
                    raw = subprocess.check_output(["tar", "--zstd", "-xOf", tc, f"maps/map-{DN}-2640x1320-Physical.bmp"], stderr=subprocess.DEVNULL)
                    src_img = Image.open(BytesIO(raw)).convert("RGB")
                    break
                except Exception:
                    pass

# 3. Fallback: download from maps-v3 GitHub release
if src_img is None:
    import urllib.request, zstandard, tarfile
    url = "https://github.com/openhamclock/open-hamclock-backend/releases/download/maps-v3/ohb-maps.tar.zst"
    print(f"Fetching source Physical map from {url}...")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    resp = urllib.request.urlopen(req, timeout=60)
    dctx = zstandard.ZstdDecompressor()
    with dctx.stream_reader(resp) as reader:
        with tarfile.open(fileobj=reader, mode="r|") as tar:
            for member in tar:
                if member.name == f"maps/map-{DN}-{SZ}-Physical.bmp" or member.name == f"maps/map-{DN}-2640x1320-Physical.bmp":
                    src_img = Image.open(BytesIO(tar.extractfile(member).read())).convert("RGB")
                    break

if src_img is None:
    raise RuntimeError(f"Could not locate or download source Physical map for {DN} {SZ}")

if src_img.size != (W, H):
    src_img = src_img.resize((W, H), Image.LANCZOS)

# Clean any residual watermark in East Antarctica
x1, x2 = int(W * 0.740), int(W * 0.825)
y1, y2 = int(H * 0.910), int(H * 0.975)
arr = np.array(src_img)
box = arr[y1:y2, x1:x2]
mask = (box[:,:,0] < 250) | (box[:,:,1] < 250) | (box[:,:,2] < 250)
if np.any(mask):
    box[mask] = [255, 255, 255]
    arr[y1:y2, x1:x2] = box
    src_img = Image.fromarray(arr)

write_bmp(src_img, out_bmp, out_z)
PY
      chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
      echo "  -> Done: $BMP  (+${BMP}.z)"
      continue
    fi

    # -----------------------------------------------------------------
    # 3b. PHYSICAL NIGHT (calibrated land cover + city lights)
    # -----------------------------------------------------------------
    if [[ "$MAPTYPE" == "Physical" && "$DN" == "N" ]]; then
      DAY_BMP="$OUTDIR/map-D-${SZ}-Physical.bmp"
      DAY_Z="$OUTDIR/map-D-${SZ}-Physical.bmp.z"
      LIGHTS_BMP="$GMT_USERDIR/city_lights_${SZ}.bmp"

      if [[ ! -f "$DAY_BMP" && ! -f "$DAY_Z" ]]; then
        for _d in "/opt/hamclock-backend/htdocs/ham/HamClock/maps" "/var/www/html/ham/HamClock/maps" "${SCRIPT_DIR}/../../htdocs/ham/HamClock/maps"; do
          if [[ -f "$_d/map-D-${SZ}-Physical.bmp" || -f "$_d/map-D-${SZ}-Physical.bmp.z" ]]; then
            cp "$_d/map-D-${SZ}-Physical.bmp"* "$OUTDIR/" 2>/dev/null || true
            break
          fi
        done
      fi
      if [[ ! -f "$DAY_BMP" && ! -f "$DAY_Z" ]]; then
        echo "  -> Generating prerequisite Physical Day map: $DAY_BMP"
        "$SCRIPT_PATH" "$SZ" --type Physical --day
      fi

      ensure_raw_city_lights "$SZ"

      echo "  -> Compositing Physical Night (calibrated land cover + city lights)..."
      python3 - <<'PY' "$DAY_BMP" "$DAY_Z" "$LIGHTS_BMP" "$BMP" "${BMP}.z" "$W" "$H" "$PHYSICAL_NIGHT_BRIGHTNESS"
import sys, os, zlib, struct
from io import BytesIO
from PIL import Image, ImageFilter
import numpy as np

day_bmp, day_z, lights_bmp, out_bmp, out_z, W, H, dim_factor_str = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]), int(sys.argv[7]), sys.argv[8]
)
dim_factor = float(dim_factor_str)

def load_img(b, z):
    candidates = [b, z]
    fname_b = os.path.basename(b)
    fname_z = os.path.basename(z)
    for d in ["/opt/hamclock-backend/htdocs/ham/HamClock/maps", "/var/www/html/ham/HamClock/maps", os.path.expanduser("~/devel/open-hamclock-backend/htdocs/ham/HamClock/maps")]:
        candidates.append(os.path.join(d, fname_b))
        candidates.append(os.path.join(d, fname_z))
    for c in candidates:
        if os.path.isfile(c):
            try:
                if c.endswith(".z"):
                    return Image.open(BytesIO(zlib.decompress(open(c, "rb").read()))).convert("RGB")
                else:
                    return Image.open(c).convert("RGB")
            except Exception:
                pass
    return None

day_img = load_img(day_bmp, day_z)
if day_img is None:
    raise RuntimeError(f"Could not load prerequisite Physical Day map: {day_bmp}")
if not os.path.isfile(lights_bmp):
    raise RuntimeError(f"Could not load source NASA city lights: {lights_bmp}")

lights_img = Image.open(lights_bmp).convert("RGB")

if day_img.size != (W, H):
    day_img = day_img.resize((W, H), Image.LANCZOS)
if lights_img.size != (W, H):
    lights_img = lights_img.resize((W, H), Image.LANCZOS)

day_arr = np.array(day_img, dtype=float)
lights_arr = np.array(lights_img, dtype=float)

# Ocean mask: where NASA city lights source is pure black (0,0,0)
ocean_mask = (lights_arr[:,:,0] == 0) & (lights_arr[:,:,1] == 0) & (lights_arr[:,:,2] == 0)

# Calibrated physical land cover: dim_factor brightness, pure black oceans
phys_land = day_arr * dim_factor
phys_land[ocean_mask] = 0.0

# Isolate city lights above background noise
native_lights = np.clip((lights_arr - 25) * 1.8, 0, 255).astype(np.uint8)

if W >= 1980:
    dilated = np.array(Image.fromarray(native_lights).filter(ImageFilter.MaxFilter(3)), dtype=float)
    glow = np.array(Image.fromarray(native_lights).resize((660, 330), Image.BILINEAR).resize((W, H), Image.BICUBIC), dtype=float)
    city_lights = np.clip(dilated * 0.7 + glow * 0.8, 0, 255)
else:
    city_lights = np.array(native_lights, dtype=float)

city_lights[ocean_mask] = 0.0

# Zero out any spurious lights/watermark artifacts in East Antarctica interior
x1, x2 = int(W * 0.740), int(W * 0.825)
y1, y2 = int(H * 0.910), int(H * 0.975)
city_lights[y1:y2, x1:x2] = 0.0

final_arr = np.clip(phys_land + city_lights, 0, 255).astype(np.uint8)
final_img = Image.fromarray(final_arr)

# Write BMP v4 RGB565 top-down + .bmp.z
raw = final_img.tobytes()
row_bytes = W * 2
pad = (4 - (row_bytes % 4)) % 4
image_size = (row_bytes + pad) * H
bfSize = 14 + 108 + image_size
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, 14 + 108)
v4hdr = struct.pack(
    "<IiiHHIIIIII",
    108, W, -H, 1, 16, 3, image_size, 0, 0, 0, 0
) + struct.pack("<IIII", 0xF800, 0x07E0, 0x001F, 0x0000) \
  + struct.pack("<I", 0x73524742) + (b"\x00" * 36) + (b"\x00" * 12)

pix = bytearray(image_size)
di, oi = 0, 0
for y in range(H):
    for x in range(W):
        r = raw[di]; g = raw[di+1]; b = raw[di+2]; di += 3
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        pix[oi] = v & 0xFF
        pix[oi+1] = (v >> 8) & 0xFF
        oi += 2
    oi += pad

bmp_data = filehdr + v4hdr + bytes(pix)
with open(out_bmp, "wb") as f:
    f.write(bmp_data)
with open(out_z, "wb") as f:
    f.write(zlib.compress(bmp_data, 9))
PY
      chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
      echo "  -> Done: $BMP  (+${BMP}.z)"
      continue
    fi

    # -----------------------------------------------------------------
    # 3. COUNTRIES NIGHT (calibrated from Countries Day)
    # -----------------------------------------------------------------
    if [[ "$MAPTYPE" == "Countries" && "$DN" == "N" ]]; then
      DAY_BMP="$OUTDIR/map-D-${SZ}-Countries.bmp"
      DAY_Z="$OUTDIR/map-D-${SZ}-Countries.bmp.z"

      if [[ ! -f "$DAY_BMP" && ! -f "$DAY_Z" ]]; then
        for _d in "/opt/hamclock-backend/htdocs/ham/HamClock/maps" "/var/www/html/ham/HamClock/maps" "${SCRIPT_DIR}/../../htdocs/ham/HamClock/maps"; do
          if [[ -f "$_d/map-D-${SZ}-Countries.bmp" || -f "$_d/map-D-${SZ}-Countries.bmp.z" ]]; then
            cp "$_d/map-D-${SZ}-Countries.bmp"* "$OUTDIR/" 2>/dev/null || true
            break
          fi
        done
      fi
      if [[ ! -f "$DAY_BMP" && ! -f "$DAY_Z" ]]; then
        echo "  -> Generating prerequisite Countries Day map: $DAY_BMP"
        "$SCRIPT_PATH" "$SZ" --type Countries --day
      fi

      echo "  -> Deriving calibrated Countries Night from $DAY_BMP"
      python3 - <<'PY' "$DAY_BMP" "$DAY_Z" "$BMP" "${BMP}.z" "$W" "$H"
import sys, os, zlib, struct
from io import BytesIO
from PIL import Image, ImageEnhance

day_bmp, day_z, out_bmp, out_z, W, H = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])

def load_img(b, z):
    candidates = [b, z]
    fname_b = os.path.basename(b)
    fname_z = os.path.basename(z)
    for d in ["/opt/hamclock-backend/htdocs/ham/HamClock/maps", "/var/www/html/ham/HamClock/maps", os.path.expanduser("~/devel/open-hamclock-backend/htdocs/ham/HamClock/maps")]:
        candidates.append(os.path.join(d, fname_b))
        candidates.append(os.path.join(d, fname_z))
    for c in candidates:
        if os.path.isfile(c):
            try:
                if c.endswith(".z"):
                    return Image.open(BytesIO(zlib.decompress(open(c, "rb").read()))).convert("RGB")
                else:
                    return Image.open(c).convert("RGB")
            except Exception:
                pass
    return None

img = load_img(day_bmp, day_z)
if img is None:
    raise RuntimeError(f"Could not load prerequisite Countries Day map: {day_bmp}")
if img.size != (W, H):
    img = img.resize((W, H), Image.LANCZOS)

night = ImageEnhance.Brightness(img).enhance(0.25)
night_color = ImageEnhance.Color(night).enhance(1.25)

raw = night_color.tobytes()
row_bytes = W * 2
pad = (4 - (row_bytes % 4)) % 4
image_size = (row_bytes + pad) * H
bfSize = 14 + 108 + image_size
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, 14 + 108)
v4hdr = struct.pack(
    "<IiiHHIIIIII",
    108, W, -H, 1, 16, 3, image_size, 0, 0, 0, 0
) + struct.pack("<IIII", 0xF800, 0x07E0, 0x001F, 0x0000) \
  + struct.pack("<I", 0x73524742) + (b"\x00" * 36) + (b"\x00" * 12)

pix = bytearray(image_size)
di, oi = 0, 0
for y in range(H):
    for x in range(W):
        r = raw[di]; g = raw[di+1]; b = raw[di+2]; di += 3
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        pix[oi] = v & 0xFF
        pix[oi+1] = (v >> 8) & 0xFF
        oi += 2
    oi += pad

bmp_data = filehdr + v4hdr + bytes(pix)
with open(out_bmp, "wb") as f:
    f.write(bmp_data)
with open(out_z, "wb") as f:
    f.write(zlib.compress(bmp_data, 9))
PY
      chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
      echo "  -> Done: $BMP  (+${BMP}.z)"
      continue
    fi

    # -----------------------------------------------------------------
    # 4. TERRAIN NIGHT (calibrated relief + city lights)
    # -----------------------------------------------------------------
    if [[ "$MAPTYPE" == "Terrain" && "$DN" == "N" ]]; then
      DAY_BMP="$OUTDIR/map-D-${SZ}-Terrain.bmp"
      DAY_Z="$OUTDIR/map-D-${SZ}-Terrain.bmp.z"
      LIGHTS_BMP="$GMT_USERDIR/city_lights_${SZ}.bmp"

      if [[ ! -f "$DAY_BMP" && ! -f "$DAY_Z" ]]; then
        for _d in "/opt/hamclock-backend/htdocs/ham/HamClock/maps" "/var/www/html/ham/HamClock/maps" "${SCRIPT_DIR}/../../htdocs/ham/HamClock/maps"; do
          if [[ -f "$_d/map-D-${SZ}-Terrain.bmp" || -f "$_d/map-D-${SZ}-Terrain.bmp.z" ]]; then
            cp "$_d/map-D-${SZ}-Terrain.bmp"* "$OUTDIR/" 2>/dev/null || true
            break
          fi
        done
      fi
      if [[ ! -f "$DAY_BMP" && ! -f "$DAY_Z" ]]; then
        echo "  -> Generating prerequisite Terrain Day map: $DAY_BMP"
        "$SCRIPT_PATH" "$SZ" --type Terrain --day
      fi

      ensure_raw_city_lights "$SZ"

      echo "  -> Compositing Terrain Night (calibrated topography relief + city lights)..."
      python3 - <<'PY' "$DAY_BMP" "$DAY_Z" "$LIGHTS_BMP" "$BMP" "${BMP}.z" "$W" "$H"
import sys, os, zlib, struct
from io import BytesIO
from PIL import Image, ImageFilter
import numpy as np

day_bmp, day_z, lights_bmp, out_bmp, out_z, W, H = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]), int(sys.argv[7])
)

def load_img(b, z):
    candidates = [b, z]
    fname_b = os.path.basename(b)
    fname_z = os.path.basename(z)
    for d in ["/opt/hamclock-backend/htdocs/ham/HamClock/maps", "/var/www/html/ham/HamClock/maps", os.path.expanduser("~/devel/open-hamclock-backend/htdocs/ham/HamClock/maps")]:
        candidates.append(os.path.join(d, fname_b))
        candidates.append(os.path.join(d, fname_z))
    for c in candidates:
        if os.path.isfile(c):
            try:
                if c.endswith(".z"):
                    return Image.open(BytesIO(zlib.decompress(open(c, "rb").read()))).convert("RGB")
                else:
                    return Image.open(c).convert("RGB")
            except Exception:
                pass
    return None

day_img = load_img(day_bmp, day_z)
if day_img is None:
    raise RuntimeError(f"Could not load prerequisite Terrain Day map: {day_bmp}")
if not os.path.isfile(lights_bmp):
    raise RuntimeError(f"Could not load source NASA city lights: {lights_bmp}")

lights_img = Image.open(lights_bmp).convert("RGB")

if day_img.size != (W, H):
    day_img = day_img.resize((W, H), Image.LANCZOS)
if lights_img.size != (W, H):
    lights_img = lights_img.resize((W, H), Image.LANCZOS)

day_arr = np.array(day_img, dtype=float)
lights_arr = np.array(lights_img, dtype=float)

# Ocean mask: where lights are pure black (0,0,0)
ocean_mask = (lights_arr[:,:,0] == 0) & (lights_arr[:,:,1] == 0) & (lights_arr[:,:,2] == 0)

# Calibrated topography relief: 0.22 brightness, pure black oceans
terrain_22 = day_arr * 0.22
terrain_22[ocean_mask] = 0.0

# Isolate city lights above background noise
native_lights = np.clip((lights_arr - 25) * 1.8, 0, 255).astype(np.uint8)

if W >= 1980:
    dilated = np.array(Image.fromarray(native_lights).filter(ImageFilter.MaxFilter(3)), dtype=float)
    glow = np.array(Image.fromarray(native_lights).resize((660, 330), Image.BILINEAR).resize((W, H), Image.BICUBIC), dtype=float)
    city_lights = np.clip(dilated * 0.7 + glow * 0.8, 0, 255)
else:
    city_lights = np.array(native_lights, dtype=float)

city_lights[ocean_mask] = 0.0

# Zero out any spurious lights/watermark artifacts in East Antarctica interior
x1, x2 = int(W * 0.740), int(W * 0.825)
y1, y2 = int(H * 0.910), int(H * 0.975)
city_lights[y1:y2, x1:x2] = 0.0

final_arr = np.clip(terrain_22 + city_lights, 0, 255).astype(np.uint8)
final_img = Image.fromarray(final_arr)

# Write BMP v4 RGB565 top-down + .bmp.z
raw = final_img.tobytes()
row_bytes = W * 2
pad = (4 - (row_bytes % 4)) % 4
image_size = (row_bytes + pad) * H
bfSize = 14 + 108 + image_size
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, 14 + 108)
v4hdr = struct.pack(
    "<IiiHHIIIIII",
    108, W, -H, 1, 16, 3, image_size, 0, 0, 0, 0
) + struct.pack("<IIII", 0xF800, 0x07E0, 0x001F, 0x0000) \
  + struct.pack("<I", 0x73524742) + (b"\x00" * 36) + (b"\x00" * 12)

pix = bytearray(image_size)
di, oi = 0, 0
for y in range(H):
    for x in range(W):
        r = raw[di]; g = raw[di+1]; b = raw[di+2]; di += 3
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        pix[oi] = v & 0xFF
        pix[oi+1] = (v >> 8) & 0xFF
        oi += 2
    oi += pad

bmp_data = filehdr + v4hdr + bytes(pix)
with open(out_bmp, "wb") as f:
    f.write(bmp_data)
with open(out_z, "wb") as f:
    f.write(zlib.compress(bmp_data, 9))
PY
      chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
      echo "  -> Done: $BMP  (+${BMP}.z)"
      continue
    fi

    # -----------------------------------------------------------------
    # 5. COUNTRIES DAY (Downscale master political map or render GMT)
    # -----------------------------------------------------------------
    if [[ "$MAPTYPE" == "Countries" && "$DN" == "D" ]]; then
      # Check if master political map exists to downscale
      MASTER_FOUND=false
      ALL_SIZES_REV=("7920x3960" "5940x2970" "5280x2640" "3960x1980" "2640x1320" "1980x990" "1320x660")
      for MSZ in "${ALL_SIZES_REV[@]}"; do
        if [[ -f "$OUTDIR/map-D-${MSZ}-Countries.bmp" || -f "$OUTDIR/map-D-${MSZ}-Countries.bmp.z" ]]; then
          python3 - <<'PY' "$OUTDIR/map-D-${MSZ}-Countries.bmp" "$OUTDIR/map-D-${MSZ}-Countries.bmp.z" "$BMP" "$BMP_Z" "$W" "$H"
import sys, os, zlib, struct
from io import BytesIO
from PIL import Image

src_bmp, src_z, out_bmp, out_z, W, H = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
if os.path.isfile(src_bmp):
    img = Image.open(src_bmp).convert("RGB")
else:
    img = Image.open(BytesIO(zlib.decompress(open(src_z, "rb").read()))).convert("RGB")

if img.size != (W, H):
    img = img.resize((W, H), Image.LANCZOS)

raw = img.tobytes()
row_bytes = W * 2
pad = (4 - (row_bytes % 4)) % 4
image_size = (row_bytes + pad) * H
bfSize = 14 + 108 + image_size
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, 14 + 108)
v4hdr = struct.pack(
    "<IiiHHIIIIII",
    108, W, -H, 1, 16, 3, image_size, 0, 0, 0, 0
) + struct.pack("<IIII", 0xF800, 0x07E0, 0x001F, 0x0000) \
  + struct.pack("<I", 0x73524742) + (b"\x00" * 36) + (b"\x00" * 12)

pix = bytearray(image_size)
di, oi = 0, 0
for y in range(H):
    for x in range(W):
        r = raw[di]; g = raw[di+1]; b = raw[di+2]; di += 3
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        pix[oi] = v & 0xFF
        pix[oi+1] = (v >> 8) & 0xFF
        oi += 2
    oi += pad

bmp_data = filehdr + v4hdr + bytes(pix)
with open(out_bmp, "wb") as f:
    f.write(bmp_data)
with open(out_z, "wb") as f:
    f.write(zlib.compress(bmp_data, 9))
PY
          chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
          echo "  -> Done (downscaled from ${MSZ}): $BMP  (+${BMP}.z)"
          MASTER_FOUND=true
          break
        fi
      done
      if [[ "$MASTER_FOUND" == "false" ]]; then
        # Check tarball for Countries Day
        tar_candidates=(
          "docker/ohb-maps.tar.zst"
          "/opt/hamclock-backend/docker/ohb-maps.tar.zst"
          "${SCRIPT_DIR}/../../docker/ohb-maps.tar.zst"
        )
        for tc in "${tar_candidates[@]}"; do
          if [[ -f "$tc" ]]; then
            tar --zstd -xOf "$tc" "maps/map-D-${SZ}-Countries.bmp" > "$BMP" 2>/dev/null || true
            if [[ -s "$BMP" ]]; then
              zlib_compress "$BMP" "$BMP_Z"
              chmod 0644 "$BMP" "$BMP_Z" 2>/dev/null || true
              echo "  -> Done (extracted from $tc): $BMP  (+${BMP_Z})"
              MASTER_FOUND=true
              break
            fi
          fi
        done
      fi
      if [[ "$MASTER_FOUND" == "true" ]]; then
        continue
      fi
    fi

    # -----------------------------------------------------------------
    # 5b. TERRAIN DAY (Downscale master relief map if GMT not available or master found)
    # -----------------------------------------------------------------
    if [[ "$MAPTYPE" == "Terrain" && "$DN" == "D" ]]; then
      if ! which gmt >/dev/null 2>&1; then
        echo "  -> GMT not installed; searching for master Terrain Day map or release archive..."
        MASTER_FOUND=false
        ALL_SIZES_REV=("7920x3960" "5940x2970" "5280x2640" "3960x1980" "2640x1320" "1980x990" "1320x660")
        for MSZ in "${ALL_SIZES_REV[@]}"; do
          if [[ -f "$OUTDIR/map-D-${MSZ}-Terrain.bmp" || -f "$OUTDIR/map-D-${MSZ}-Terrain.bmp.z" ]]; then
            python3 - <<'PY' "$OUTDIR/map-D-${MSZ}-Terrain.bmp" "$OUTDIR/map-D-${MSZ}-Terrain.bmp.z" "$BMP" "$BMP_Z" "$W" "$H"
import sys, os, zlib, struct
from io import BytesIO
from PIL import Image

src_bmp, src_z, out_bmp, out_z, W, H = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
if os.path.isfile(src_bmp):
    img = Image.open(src_bmp).convert("RGB")
else:
    img = Image.open(BytesIO(zlib.decompress(open(src_z, "rb").read()))).convert("RGB")

if img.size != (W, H):
    img = img.resize((W, H), Image.LANCZOS)

raw = img.tobytes()
row_bytes = W * 2
pad = (4 - (row_bytes % 4)) % 4
image_size = (row_bytes + pad) * H
bfSize = 14 + 108 + image_size
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, 14 + 108)
v4hdr = struct.pack(
    "<IiiHHIIIIII",
    108, W, -H, 1, 16, 3, image_size, 0, 0, 0, 0
) + struct.pack("<IIII", 0xF800, 0x07E0, 0x001F, 0x0000) \
  + struct.pack("<I", 0x73524742) + (b"\x00" * 36) + (b"\x00" * 12)

pix = bytearray(image_size)
di, oi = 0, 0
for y in range(H):
    for x in range(W):
        r = raw[di]; g = raw[di+1]; b = raw[di+2]; di += 3
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        pix[oi] = v & 0xFF
        pix[oi+1] = (v >> 8) & 0xFF
        oi += 2
    oi += pad

bmp_data = filehdr + v4hdr + bytes(pix)
with open(out_bmp, "wb") as f:
    f.write(bmp_data)
with open(out_z, "wb") as f:
    f.write(zlib.compress(bmp_data, 9))
PY
            chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
            echo "  -> Done (downscaled from ${MSZ}): $BMP  (+${BMP}.z)"
            MASTER_FOUND=true
            break
          fi
        done
        if [[ "$MASTER_FOUND" == "false" ]]; then
          tar_candidates=(
            "docker/ohb-maps.tar.zst"
            "/opt/hamclock-backend/docker/ohb-maps.tar.zst"
            "${SCRIPT_DIR}/../../docker/ohb-maps.tar.zst"
          )
          for tc in "${tar_candidates[@]}"; do
            if [[ -f "$tc" ]]; then
              tar --zstd -xOf "$tc" "maps/map-D-${SZ}-Terrain.bmp" > "$BMP" 2>/dev/null || true
              if [[ -s "$BMP" ]]; then
                zlib_compress "$BMP" "$BMP_Z"
                chmod 0644 "$BMP" "$BMP_Z" 2>/dev/null || true
                echo "  -> Done (extracted from $tc): $BMP  (+${BMP_Z})"
                MASTER_FOUND=true
                break
              fi
            fi
          done
        fi
        if [[ "$MASTER_FOUND" == "true" ]]; then
          continue
        fi
      fi
    fi

    # -----------------------------------------------------------------
    # 6. GMT VECTOR / DEM RENDERING (Terrain Day & fallback Countries Day)
    # -----------------------------------------------------------------
    MAX_RENDER=7000
    if (( W * 2 > MAX_RENDER )); then
      RENDER_W=$W
      RENDER_H=$H
    else
      RENDER_W=$((W * 2))
      RENDER_H=$((H * 2))
    fi

    BASE="$GMT_USERDIR/${MAPTYPE}_${DN}_${SZ}"
    PS="${BASE}.ps"
    PNG="${BASE}.png"
    PNG_FIXED="${BASE}_fixed.png"

    GMT_CONF="$GMT_USERDIR/gmtconf_${MAPTYPE}_${DN}_${SZ}"
    mkdir -p "$GMT_CONF"
    GMT_USERDIR="$GMT_CONF" gmt set \
      PS_MEDIA "${RENDER_W}px${RENDER_H}p" \
      MAP_ORIGIN_X 0c \
      MAP_ORIGIN_Y 0c

    (
      cd "$GMT_USERDIR" || exit 1

      if [[ "$MAPTYPE" == "Countries" ]]; then
        OCEAN="30/100/200"           # medium blue
        LAND="100/140/70"            # muted green
        BORDER_W="1.0p,white"        # coastlines
        CBORDER="0.4p,200/200/200"   # country borders

        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -G${LAND} -S${OCEAN} \
            -A500 \
            --MAP_FRAME_AXES=WSne \
            -P -K > "$PS"

        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -N1/${CBORDER} \
            -W${BORDER_W} \
            -A500 \
            --MAP_FRAME_AXES= \
            -O -K >> "$PS"

        gmt psxy -R -J -T -O >> "$PS"

      else
        # Terrain Day: ETOPO hypsometric relief + hillshade + borders
        init_terrain_gmt

        CPT="$GMT_USERDIR/terrain_D.cpt"
        INTENSITY="-I${SHADE_NC}"
        COAST_W="0.8p,white"
        BORDER_C="0.4p,200/200/200"

        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -G128/128/128 -S128/128/128 \
            -A500 \
            --MAP_FRAME_AXES=WSne \
            -P -K > "$PS"

        GMT_USERDIR="$GMT_CONF" \
          gmt grdimage "$ETOPO_NC" \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -C${CPT} \
            ${INTENSITY} \
            -n+b \
            --MAP_FRAME_AXES= \
            -O -K >> "$PS"

        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -W${COAST_W} \
            -N1/${BORDER_C} \
            -A500 \
            --MAP_FRAME_AXES= \
            -O -K >> "$PS"

        gmt psxy -R -J -T -O >> "$PS"
      fi
    ) || { echo "  GMT failed for ${MAPTYPE} ${DN} $SZ" >&2; continue; }

    render_ps_to_bmp \
      "$PS" "$PNG" "$PNG_FIXED" "$BMP" \
      "$RENDER_W" "$RENDER_H" "$W" "$H" "$SZ" \
      || continue

    echo "  -> Done: $BMP  (+${BMP}.z)"

  done   # sizes
done     # D/N
done     # MAPTYPE

echo ""
echo "All maps complete. Output in: $OUTDIR"
