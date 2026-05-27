#!/usr/bin/env bash
# update_wx_maps.sh
#
# Generates HamClock weather maps in multiple sizes:
#   Wx-mB  — pressure in millibars  (map-D/N-WxH-Wx-mB.bmp[.z])
#   Wx-in  — pressure in inches Hg  (map-D/N-WxH-Wx-in.bmp[.z])
#
# GMT base is built with the classic pscoast/psconvert pipeline (compatible
# with GMT 6.5.0 and pixel-exact for all sizes including very large ones).
# ImageMagick pixel/memory limits are raised so 7920x3960 etc. succeed.
#
# Composition order:
#   1) Build neutral GMT base (black land+sea, same geometry for D/N)
#   2) Render weather (temp/isobars/wind) on top
#   3) Boost brightness for Day variant
#   4) Overlay black coastlines/borders on top of weather colours

set -euo pipefail

# Skip generation if we are proxying maps from a central Alpha server
if [[ -n "${ALPHA_INSTALL:-}" && "${ALPHA_INSTALL}" != "true" ]]; then
    echo "ALPHA_INSTALL is set to a hostname (${ALPHA_INSTALL}) - skipping local map generation."
    exit 0
fi

export LC_ALL=C

export GMT_USERDIR=/opt/hamclock-backend/tmp
cd "$GMT_USERDIR"

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
TMPROOT="/opt/hamclock-backend/tmp"
export MPLCONFIGDIR="$TMPROOT/mpl"

RENDER_PY="/opt/hamclock-backend/scripts/render_wx_mb_map.py"
RAW2BMP_PY="/opt/hamclock-backend/scripts/hc_raw_to_bmp565.py"
PYTHON_BIN="/opt/hamclock-backend/venv/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="/usr/bin/python3"
fi

# Load unified size list
# shellcheck source=/dev/null
source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes

NOMADS_FILTER="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
export PYTHONPATH="/opt/hamclock-backend/scripts${PYTHONPATH:+:$PYTHONPATH}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }

need curl
need gmt
need convert

[[ -x "$PYTHON_BIN" ]] || { echo "ERROR: missing executable $PYTHON_BIN" >&2; exit 1; }
[[ -f "$RENDER_PY" ]]  || { echo "ERROR: missing $RENDER_PY" >&2; exit 1; }
[[ -f "$RAW2BMP_PY" ]] || { echo "ERROR: missing $RAW2BMP_PY" >&2; exit 1; }

mkdir -p "$OUTDIR" "$TMPROOT" "$MPLCONFIGDIR"

TMPDIR="$(mktemp -d -p "$TMPROOT" wxmb.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# ImageMagick 6: raise resource limits so very large maps (7920x3960 etc.)
# succeed without "cache resources exhausted" errors.
#
# Valid IM6 -limit resource names: width height area memory map disk
# ("pixels" does NOT exist in IM6; use "area" for pixel-count cap instead).
# IM6 accepts plain MB/GB — NOT GiB/MiB.
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
# make_wx_base_bmp  tag W H out_bmp_z
#
# Builds a solid-black equirectangular world map (land + sea both black).
# Uses the classic pscoast/psconvert pipeline so the pixel dimensions are
# exact for all sizes and results are identical to make_wx_line_overlay_png.
# This also avoids the gmt begin/end PNG-size mismatch seen in GMT 6.5.0.
# ---------------------------------------------------------------------------
make_wx_base_bmp() {
  local tag="$1" W="$2" H="$3" out_bmp_z="$4"

  local stem_base="wxbase_${tag}_${W}x${H}"
  local ps="$TMPDIR/${stem_base}.ps"
  local png="$TMPDIR/${stem_base}.png"
  local raw="$TMPDIR/${stem_base}.raw"
  local bmp="$TMPDIR/${stem_base}.bmp"

  # Classic PostScript pipeline — pixel-exact, works in GMT 6.5.0.
  # "gmt set PS_MEDIA" in a private GMT_USERDIR sub-dir ensures the page is
  # sized to exactly the map so pscoast never warns and psconvert -A is clean.
  # (GMT 6 classic mode ignores the GMT_PS_MEDIA env var; gmt.conf wins.)
  (
    cd "$TMPDIR" || exit 1
    rm -f "$ps" "$png"

    local W_cm H_cm
    W_cm=$(awk "BEGIN{printf \"%.4f\", $W * 2.54 / 72}")
    H_cm=$(awk "BEGIN{printf \"%.4f\", $H * 2.54 / 72}")

    local gmt_conf_dir="$TMPDIR/gmtconf_base_${W}x${H}"
    mkdir -p "$gmt_conf_dir"
    GMT_USERDIR="$gmt_conf_dir" gmt set \
      PS_MEDIA "${W_cm}cx${H_cm}c" \
      MAP_ORIGIN_X 0c \
      MAP_ORIGIN_Y 0c

    GMT_USERDIR="$gmt_conf_dir" \
    gmt pscoast \
      -R-180/180/-90/90 \
      -JX${W}p/${H}p \
      -X0 -Y0 \
      -Gblack -Sblack -A10000 \
      -P -K > "$ps" && \
    gmt psxy -R -J -T -O >> "$ps" && \
    GMT_USERDIR="$gmt_conf_dir" \
    gmt psconvert "$ps" -Tg -E72 -A -F"$stem_base"
  ) || { echo "gmt failed for Wx base $tag ${W}x${H}" >&2; return 1; }

  [[ -f "$png" ]] || {
    echo "Wx base PNG not found: $png" >&2
    ls -l "$TMPDIR" >&2 || true
    return 1
  }

  # psconvert -E72 gives near-exact output; resize to guarantee exact WxH
  # (psconvert -A may add/remove 1px due to stroke half-width at edges)
  im_convert "$png" -resize "${W}x${H}!" RGB:"$raw" || {
    echo "raw extract failed for Wx base $tag ${W}x${H}" >&2; return 1; }

  "$PYTHON_BIN" "$RAW2BMP_PY" --in "$raw" --out "$bmp" --width "$W" --height "$H" || {
    echo "bmp write failed for Wx base $tag ${W}x${H}" >&2; return 1; }

  "$PYTHON_BIN" - <<'PY' "$bmp" "$out_bmp_z"
from hc_zlib import zcompress_file
import sys
zcompress_file(sys.argv[1], sys.argv[2], level=9)
PY
  [[ -f "$out_bmp_z" ]] || { echo "zlib failed for Wx base $tag ${W}x${H}" >&2; return 1; }

  rm -f "$png" "$ps" "$raw" "$bmp"
}

# ---------------------------------------------------------------------------
# make_wx_line_overlay_png  W H out_png
#
# Transparent PNG with only black coastlines + country borders.
# Composited AFTER weather rendering so geographic lines stay crisp.
# ---------------------------------------------------------------------------
make_wx_line_overlay_png() {
  local W="$1" H="$2" out_png="$3"

  local stem_base="wxlines_src_${W}x${H}"
  local ps="$TMPDIR/${stem_base}.ps"
  local png="$TMPDIR/${stem_base}.png"

  rm -f "$ps" "$png" "$out_png"

  (
    cd "$TMPDIR" || exit 1

    local W_cm H_cm
    W_cm=$(awk "BEGIN{printf \"%.4f\", $W * 2.54 / 72}")
    H_cm=$(awk "BEGIN{printf \"%.4f\", $H * 2.54 / 72}")

    local gmt_conf_dir="$TMPDIR/gmtconf_lines_${W}x${H}"
    mkdir -p "$gmt_conf_dir"
    GMT_USERDIR="$gmt_conf_dir" gmt set \
      PS_MEDIA "${W_cm}cx${H_cm}c" \
      MAP_ORIGIN_X 0c \
      MAP_ORIGIN_Y 0c

    GMT_USERDIR="$gmt_conf_dir" \
    gmt pscoast \
      -R-180/180/-90/90 \
      -JX${W}p/${H}p \
      -X0 -Y0 \
      -W0.6p,black -N1/0.45p,black -A10000 \
      -P -K > "$ps" && \
    gmt psxy -R -J -T -O >> "$ps" && \
    GMT_USERDIR="$gmt_conf_dir" \
    gmt psconvert "$ps" -Tg -E72 -A -F"$stem_base"
  ) || { echo "gmt failed for Wx line overlay ${W}x${H}" >&2; return 1; }

  [[ -f "$png" ]] || {
    echo "line overlay PNG not found: $png" >&2
    ls -l "$TMPDIR" >&2 || true
    return 1
  }

  # Convert white background to transparent; preserve black lines
  im_convert "$png" \
    -fuzz 8% -transparent white \
    -resize "${W}x${H}!" \
    "$out_png" || {
      echo "line overlay convert failed for ${W}x${H}" >&2
      return 1
    }

  [[ -f "$out_png" ]] || {
    echo "line overlay output missing after convert: $out_png" >&2
    return 1
  }

  rm -f "$png" "$ps" "$TMPDIR/${stem_base}.eps"
}

# ---------------------------------------------------------------------------
# boost_day_wx_brightness  W H map_type
#
# Applies brightness/saturation boost to the Day map in-place.
# map_type is e.g. "Wx-mB" or "Wx-in".
# ---------------------------------------------------------------------------
boost_day_wx_brightness() {
  local W="$1" H="$2" map_type="$3"

  local in_bmp="$OUTDIR/map-D-${W}x${H}-${map_type}.bmp"
  local out_z="$OUTDIR/map-D-${W}x${H}-${map_type}.bmp.z"
  local stem="$TMPDIR/wxbright_D_${W}x${H}_${map_type}"
  local png="${stem}.png"
  local png_out="${stem}_out.png"
  local raw="${stem}.raw"

  [[ -f "$in_bmp" ]] || { echo "ERROR: missing Day Wx map $in_bmp" >&2; return 1; }

  im_convert "$in_bmp" "$png" || {
    echo "convert bmp->png failed for Day Wx ${map_type} ${W}x${H}" >&2; return 1; }

  # Modest brightness + saturation boost; tune if needed
  im_convert "$png" \
    -modulate 148,132,100 \
    -gamma 1.08 \
    "$png_out" || { echo "brightness boost failed for Day Wx ${map_type} ${W}x${H}" >&2; return 1; }

  im_convert "$png_out" -resize "${W}x${H}!" RGB:"$raw" || {
    echo "png->raw failed for brightened Day Wx ${map_type} ${W}x${H}" >&2; return 1; }

  "$PYTHON_BIN" "$RAW2BMP_PY" --in "$raw" --out "$in_bmp" --width "$W" --height "$H" || {
    echo "bmp rewrite failed for brightened Day Wx ${map_type} ${W}x${H}" >&2; return 1; }

  "$PYTHON_BIN" - <<'PY' "$in_bmp" "$out_z"
from hc_zlib import zcompress_file
import sys
zcompress_file(sys.argv[1], sys.argv[2], level=9)
PY

  rm -f "$png" "$png_out" "$raw"
}

# ---------------------------------------------------------------------------
# overlay_black_borders_on_wx_output  tag W H map_type
#
# Composites black coastlines/borders OVER the final rendered Wx map.
# map_type is e.g. "Wx-mB" or "Wx-in".
# The line overlay PNG is built once per size and reused across map types.
# ---------------------------------------------------------------------------
overlay_black_borders_on_wx_output() {
  local tag="$1" W="$2" H="$3" map_type="$4"

  local in_bmp="$OUTDIR/map-${tag}-${W}x${H}-${map_type}.bmp"
  local out_z="$OUTDIR/map-${tag}-${W}x${H}-${map_type}.bmp.z"
  # Shared line overlay per size (built once, reused for both Wx-mB and Wx-in)
  local line_png="$TMPDIR/wxlines_${W}x${H}.png"

  [[ -f "$in_bmp" ]] || { echo "ERROR: missing Wx map $in_bmp" >&2; return 1; }

  # Build the line overlay only if not already cached for this size
  if [[ ! -f "$line_png" ]]; then
    make_wx_line_overlay_png "$W" "$H" "$line_png"
  fi

  local stem="$TMPDIR/wxlines_comp_${tag}_${W}x${H}_${map_type}"
  local png="${stem}.png"
  local png_out="${stem}_out.png"
  local raw="${stem}.raw"

  im_convert "$in_bmp" "$png" || {
    echo "convert bmp->png failed for Wx ${tag} ${map_type} ${W}x${H}" >&2; return 1; }

  # Composite line overlay last so borders stay crisp on top of temp shading
  im_convert "$png" "$line_png" -compose over -composite "$png_out" || {
    echo "border overlay composite failed for Wx ${tag} ${map_type} ${W}x${H}" >&2; return 1; }

  im_convert "$png_out" -resize "${W}x${H}!" RGB:"$raw" || {
    echo "png->raw failed after border overlay for Wx ${tag} ${map_type} ${W}x${H}" >&2; return 1; }

  "$PYTHON_BIN" "$RAW2BMP_PY" --in "$raw" --out "$in_bmp" --width "$W" --height "$H" || {
    echo "bmp rewrite failed after border overlay for Wx ${tag} ${map_type} ${W}x${H}" >&2; return 1; }

  "$PYTHON_BIN" - <<'PY' "$in_bmp" "$out_z"
from hc_zlib import zcompress_file
import sys
zcompress_file(sys.argv[1], sys.argv[2], level=9)
PY
  [[ -f "$out_z" ]] || {
    echo "zlib rewrite failed after border overlay for Wx ${tag} ${map_type} ${W}x${H}" >&2; return 1; }

  rm -f "$png" "$png_out" "$raw"
}

# ---------------------------------------------------------------------------
# GFS download
# ---------------------------------------------------------------------------
pick_and_download() {
  local ymd="$1" hh="$2"
  local file="gfs.t${hh}z.pgrb2.0p25.f000"
  local dir="%2Fgfs.${ymd}%2F${hh}%2Fatmos"

  local url="${NOMADS_FILTER}?file=${file}"\
"&lev_mean_sea_level=on&lev_10_m_above_ground=on&lev_2_m_above_ground=on"\
"&var_PRMSL=on&var_UGRD=on&var_VGRD=on&var_TMP=on"\
"&leftlon=0&rightlon=359.75&toplat=90&bottomlat=-90"\
"&dir=${dir}"

  echo "Trying GFS ${ymd} ${hh}Z ..."
  curl -fs -A "open-hamclock-backend/1.0" --retry 2 --retry-delay 2 "$url" -o "$TMPDIR/gfs.grb2"
  local RETVAL=$?
  if [[ $RETVAL -eq 0 ]]; then
    echo "Downloaded: ${file} (${ymd} ${hh}Z)"
    echo "${ymd} ${hh}" > "$TMPDIR/gfs_cycle.txt"
  else
    echo "Curl error '$RETVAL' on GFS ${ymd} ${hh}Z"
  fi
  return $RETVAL
}

MAP_INTERVAL=6
MAP_READY=2

NOW=$(date -u -d "$MAP_READY hours ago" +%s)
HOUR_NOW=$(date -u -d "@$NOW" +%H)
HOUR_NOW=$((10#$HOUR_NOW))
START_TIME=$(( NOW - ((HOUR_NOW % MAP_INTERVAL) * 3600) ))

NUM_TRYS=8
downloaded=0
for ((try=0; try<NUM_TRYS; try++)); do
  check_time=$(( START_TIME - MAP_INTERVAL*3600*try ))
  d=$(date -u -d "@${check_time}" +%Y%m%d)
  hh=$(date -u -d "@${check_time}" +%H)
  if pick_and_download "$d" "$hh"; then
    downloaded=1
    break
  fi
done

if [[ "$downloaded" -ne 1 ]]; then
  echo "ERROR: could not download a recent GFS subset from NOMADS." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# render_one  tag W H base map_type log_inventory
#
# Calls the Python renderer.  map_type controls both the output filename
# suffix and the pressure unit:
#   Wx-mB  → millibars  (no extra flag, existing renderer default)
#   Wx-in  → inches Hg  (--units inches --map-type Wx-in)
# ---------------------------------------------------------------------------
render_one() {
  local tag="$1" W="$2" H="$3" base="$4" map_type="$5" log_inventory="${6:-0}"

  local inv_flag=()
  [[ "$log_inventory" -eq 1 ]] && inv_flag=(--log-inventory)

  local unit_flags=()
  if [[ "$map_type" == "Wx-in" ]]; then
    unit_flags=(--units inches --map-type Wx-in)
  fi

  "$PYTHON_BIN" "$RENDER_PY" \
    --grib    "$TMPDIR/gfs.grb2" \
    --base    "$base" \
    --outdir  "$OUTDIR" \
    --tag     "$tag" \
    --width   "$W" \
    --height  "$H" \
    "${unit_flags[@]}" \
    "${inv_flag[@]}"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
logged_inventory=0

for wh in "${SIZES[@]}"; do
  W="${wh%x*}"
  H="${wh#*x}"

  # One base image is shared between the two pressure-unit variants —
  # the base is solid black (no colour), so units don't affect it.
  WX_BASE="$TMPDIR/map-WxBase-${W}x${H}.bmp.z"

  echo "=== Building GMT base ${W}x${H} ==="
  make_wx_base_bmp "base" "$W" "$H" "$WX_BASE"

  for map_type in Wx-mB Wx-in; do
    echo "--- ${map_type} Day ${W}x${H} ---"

    echo "Rendering ${map_type} Day ${W}x${H}"
    if [[ "$logged_inventory" -eq 0 ]]; then
      render_one "D" "$W" "$H" "$WX_BASE" "$map_type" 1
      logged_inventory=1
    else
      render_one "D" "$W" "$H" "$WX_BASE" "$map_type" 0
    fi

    echo "Boosting Day brightness for ${map_type} ${W}x${H}"
    boost_day_wx_brightness "$W" "$H" "$map_type"

    echo "Overlaying black borders on ${map_type} Day ${W}x${H}"
    overlay_black_borders_on_wx_output "D" "$W" "$H" "$map_type"

    echo "--- ${map_type} Night ${W}x${H} ---"

    echo "Rendering ${map_type} Night ${W}x${H}"
    render_one "N" "$W" "$H" "$WX_BASE" "$map_type" 0

    echo "Overlaying black borders on ${map_type} Night ${W}x${H}"
    overlay_black_borders_on_wx_output "N" "$W" "$H" "$map_type"

    # Set permissions
    chmod 0644 \
      "$OUTDIR/map-D-${W}x${H}-${map_type}.bmp" \
      "$OUTDIR/map-D-${W}x${H}-${map_type}.bmp.z" \
      2>/dev/null || true

    if [[ -f "$OUTDIR/map-N-${W}x${H}-${map_type}.bmp" ]]; then
      chmod 0644 \
        "$OUTDIR/map-N-${W}x${H}-${map_type}.bmp" \
        "$OUTDIR/map-N-${W}x${H}-${map_type}.bmp.z"
    fi

    echo "OK: ${map_type} maps ${W}x${H} complete"
  done
done

echo ""
echo "OK: All Wx maps (Wx-mB + Wx-in) updated in $OUTDIR"
