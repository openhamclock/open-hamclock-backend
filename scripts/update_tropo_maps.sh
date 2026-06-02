#!/bin/bash
# ============================================================
#
#   ██████╗ ██╗  ██╗██████╗
#  ██╔═══██╗██║  ██║██╔══██╗
#  ██║   ██║███████║██████╔╝
#  ██║   ██║██╔══██║██╔══██╗
#  ╚██████╔╝██║  ██║██████╔╝
#   ╚═════╝ ╚═╝  ██╝╚═════╝
#
#  Open HamClock Backend
#  update_tropo_maps.sh
#
#  Generates global tropospheric surface refractivity (N-unit) overlay
#  maps for HamClock using NOAA GFS model data.
#
#  N-units (surface refractivity) indicate conditions for VHF/UHF
#  tropospheric propagation enhancement and ducting.  High N values
#  over a region correspond to warm, humid low-level air — the
#  prerequisite for superrefractive and ducting propagation paths.
#
#  Data source: NOAA GFS 0.25° global analysis via NOMADS GRIB filter
#  Update cadence: 4×/day following each GFS run (00/06/12/18 UTC).
#
#  Suggested cron (30 min after each GFS run finalises):
#    30 5,11,17,23 * * * /opt/hamclock-backend/scripts/update_tropo_maps.sh
#
#  Python deps (pip3 install):  cfgrib  numpy
#  System deps:                 libeccodes-dev (or eccodes package)
#                               gmt  python3-pillow
#
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as
#  published by the Free Software Foundation, either version 3 of the
#  License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#
#  You should have received a copy of the GNU Affero General Public
#  License along with this program.  If not, see
#  <https://www.gnu.org/licenses/>.
#
# ============================================================
set -euo pipefail

# Skip generation if we are proxying maps from a central Alpha server
if [[ -n "${PROXY_MAPS:-}" && "${PROXY_MAPS}" != "false" ]]; then
    echo "PROXY_MAPS is set to a hostname (${PROXY_MAPS}) - skipping local map generation."
    exit 0
fi

export GMT_USERDIR=/opt/hamclock-backend/htdocs/tmp
mkdir -p "$GMT_USERDIR"
cd "$GMT_USERDIR"

source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes   # populates SIZES=(...) per OHB conventions

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$OUTDIR"

# ── 1. Determine the most recent available GFS run ──────────────────────────
#
# GFS runs at 00/06/12/18 UTC.  Files appear on NOMADS roughly 4–5 h
# after the run time.  We find the most recent run that should be
# complete and write its date/hour to gfs_run.env, which we source below.

python3 <<'PYEOF'
import datetime, sys

AVAILABILITY_DELAY_H = 5.0   # hours after run time before files are reliably up

now = datetime.datetime.now(datetime.timezone.utc)
candidates = []

# Check today and yesterday to cover the 00Z rollover
for day_offset in range(2):
    date = now - datetime.timedelta(days=day_offset)
    for run_hour in (18, 12, 6, 0):
        run_dt = date.replace(hour=run_hour, minute=0, second=0, microsecond=0)
        age_h = (now - run_dt).total_seconds() / 3600.0
        if age_h >= AVAILABILITY_DELAY_H:
            candidates.append(run_dt)

if not candidates:
    print("ERROR: no GFS run old enough to be available yet", file=sys.stderr)
    sys.exit(1)

best = candidates[0]   # most recent that should be complete
print(f"Using GFS run {best.strftime('%Y%m%d')} {best.hour:02d}Z "
      f"(age {((now - best).total_seconds()/3600):.1f}h)", file=sys.stderr)

with open("gfs_run.env", "w") as f:
    f.write(f"GFS_DATE={best.strftime('%Y%m%d')}\n")
    f.write(f"GFS_HOUR={best.hour:02d}\n")
PYEOF

source gfs_run.env
echo "Fetching GFS surface fields for run ${GFS_DATE} ${GFS_HOUR}Z..."

# ── 2. Download the three surface fields from NOMADS GRIB filter ────────────
#
# The filter returns only the requested variables — ~2 MB instead of the
# full ~500 MB GFS file.  Fields requested:
#   TMP @ 2 m above ground   (temperature, K)
#   RH  @ 2 m above ground   (relative humidity, %)
#   PRES@ surface            (surface pressure, Pa)

GRFILE="gfs_sfc.grb2"
NOMADS_BASE="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
NOMADS_URL="${NOMADS_BASE}?dir=%2Fgfs.${GFS_DATE}%2F${GFS_HOUR}%2Fatmos"
NOMADS_URL+="&file=gfs.t${GFS_HOUR}z.pgrb2.0p25.f000"
NOMADS_URL+="&var_TMP=on&var_RH=on&var_PRES=on"
NOMADS_URL+="&lev_2_m_above_ground=on&lev_surface=on"

curl -fsSL --max-time 120 -A "open-hamclock-backend/1.0" \
    "$NOMADS_URL" -o "$GRFILE"

GRIB_BYTES=$(stat -c '%s' "$GRFILE")
echo "  Downloaded ${GRIB_BYTES} bytes"
if [[ "$GRIB_BYTES" -lt 50000 ]]; then
    echo "ERROR: GRIB file suspiciously small — NOMADS may have returned an error page" >&2
    cat "$GRFILE" >&2
    exit 1
fi

# ── 3. Compute surface refractivity N and write XYZ ─────────────────────────
#
# Smith-Weintraub formula:
#   N = 77.6·P/T  +  3.73×10⁵·e/T²
#
# where P = total pressure (hPa), e = water vapour pressure (hPa), T = K.
# Saturation vapour pressure from the Magnus formula:
#   e_s = 6.1078 · exp(17.2694 · Tc / (Tc + 237.29))    (hPa)
#   e   = (RH/100) · e_s

python3 <<'PYEOF'
import sys
import numpy as np

try:
    import cfgrib
except ImportError:
    print("ERROR: cfgrib is required.  Run: pip3 install cfgrib numpy", file=sys.stderr)
    sys.exit(1)

GRFILE = "gfs_sfc.grb2"

# ── Field extraction ─────────────────────────────────────────────────────────
# open_datasets() (plural) splits the file into per-variable groups and
# returns them all — no filter_by_keys needed.  The diagnostic confirmed this
# works correctly with GFS GRIB2 where open_dataset(filter_by_keys=...) fails.
# We collect every variable then pick by priority: specific 2m names first so
# we never accidentally use skin temperature ('t') instead of 2m temp ('t2m').

all_fields = {}
lats = lons = None

for ds in cfgrib.open_datasets(GRFILE):
    for var in ds.data_vars:
        vals = ds[var].values
        all_fields[var] = vals
        if lats is None:
            lats = ds.coords['latitude'].values   # 90 → -90
            lons = ds.coords['longitude'].values  # 0 → 359.75
        print(f"  {var}: range=[{vals.min():.1f}, {vals.max():.1f}]", file=sys.stderr)

def require(candidates, label):
    for name in candidates:
        if name in all_fields:
            print(f"  Using '{name}' for {label}", file=sys.stderr)
            return all_fields[name]
    raise RuntimeError(f"Could not find {label} in {GRFILE}; available fields: {list(all_fields)}")

T_K  = require(['t2m', '2t'],          '2m temperature')
RH   = require(['r2', '2r', 'r'],      '2m relative humidity')
P_Pa = require(['sp', 'pres', 'PRES'], 'surface pressure')

# ── Refractivity (Smith-Weintraub) ───────────────────────────────────────────
if T_K.max() < 100:
    print("Warning: TMP appears to be Celsius, adding 273.15", file=sys.stderr)
    T_K = T_K + 273.15

P_hPa = P_Pa / 100.0 if P_Pa.max() > 10000 else P_Pa   # Pa → hPa

Tc  = T_K - 273.15
e_s = 6.1078 * np.exp(17.2694 * Tc / (Tc + 237.29))    # sat. vapour pressure, hPa
e   = np.clip(RH, 0, 110) / 100.0 * e_s                # actual vapour pressure, hPa
N   = 77.6 * P_hPa / T_K + 3.73e5 * e / T_K**2         # N-units

print(f"  N range: [{N.min():.1f}, {N.max():.1f}] N-units", file=sys.stderr)

# ── Write XYZ for GMT (lon in −180..180) ─────────────────────────────────────
#
# GFS is gridline-registered at 0.25°, so after wrapping the lon set runs
# -179.75 .. +180.00 — it has a node at +180 but NONE at -180.  In a
# gridline grid spanning -180/180 that leaves the -180 column with no data
# (NaN), which renders as the black NaN colour down the dateline.  Since
# -180 and +180 are the SAME meridian, mirror the +180 column to -180 so the
# grid is gap-free before we resample it to pixel registration in GMT.
lons_adj = np.where(lons > 180.0, lons - 360.0, lons)
LON, LAT = np.meshgrid(lons_adj, lats)
mask = np.isfinite(N.ravel())
with open("tropo.xyz", "w") as f:
    for lo, la, nv in zip(LON.ravel()[mask], LAT.ravel()[mask], N.ravel()[mask]):
        f.write(f"{lo:.3f} {la:.3f} {nv:.2f}\n")

    # Close the dateline: copy the +180 column to -180.
    edge = np.isclose(lons_adj, 180.0)
    N_edge   = N[:, edge].ravel()
    LAT_edge = LAT[:, edge].ravel()
    em = np.isfinite(N_edge)
    for la, nv in zip(LAT_edge[em], N_edge[em]):
        f.write(f"{-180.0:.3f} {la:.3f} {nv:.2f}\n")

print(f"  Wrote {mask.sum() + em.sum()} grid points to tropo.xyz "
      f"({em.sum()} mirrored to -180)", file=sys.stderr)
PYEOF

NPTS=$(wc -l < tropo.xyz)
echo "Grid points written: $NPTS"

# ── 4. GMT: XYZ → NetCDF grid ────────────────────────────────────────────────
#
# GFS data is gridline-registered (samples sit AT 0.25° multiples), so we bin
# it with gridline registration — no -r.  The Python step has already mirrored
# the +180 column to -180, so the grid is gap-free across the dateline with no
# NaN edge column.
#
# We deliberately render this gridline grid straight to the projection, exactly
# as HamClock's built-in maps do.  An earlier attempt to resample onto a
# pixel-registered global grid (grdsample -fg) introduced a dateline
# DISCONTINUITY: the mirror leaves both ±180 nodes present (the same meridian
# twice), which violates grdsample's global-grid assumption that the last
# column is not a duplicate, so the periodic resampler shifted one half of the
# world relative to the other.  Rendering the gridline grid directly avoids
# that entirely; any unpainted edge pixel is handled in the BMP writer.

gmt xyz2grd tropo.xyz -R-180/180/-90/90 -I0.25 -Gtropo_raw.nc
gmt grdfilter tropo_raw.nc -Fg1.5 -D0 -Ni -Gtropo.nc

# ── 5. Colour palette ────────────────────────────────────────────────────────
#
# Scale spans typical global N range (~260 – 450 N-units).
# Cool colours = low N (dry/cold, no ducting).
# Warm colours = high N (warm/humid, ducting likely or probable).
# This mirrors the DRAP colour philosophy: "warmer = more activity".

cat > tropo.cpt <<'CPTEOF'
260   0/0/30        275   0/0/80
275   0/0/80        295   0/30/140
295   0/30/140      310   0/80/200
310   0/80/200      325   0/160/210
325   0/160/210     340   80/210/80
340   80/210/80     355   160/225/50
355   160/225/50    370   240/200/0
370   240/200/0     390   255/130/0
390   255/130/0     415   230/30/0
415   230/30/0      450   180/0/0
B     0/0/0
F     180/0/0
N     0/0/0
CPTEOF

# ── 6. Shared helpers (identical to update_drap_maps.sh) ────────────────────

zlib_compress() {
    local in="$1" out="$2"
    python3 -c "
import zlib, sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(zlib.compress(data, 9))
" "$in" "$out"
}

make_bmp_v4_rgb565_topdown() {
    local inpng="$1" outbmp="$2" W="$3" H="$4" DN="$5"
    python3 - <<'PY' "$inpng" "$outbmp" "$W" "$H" "$DN"
import struct, sys
from PIL import Image

inpng, outbmp, W, H, DN = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]

img = Image.open(inpng).convert("RGB")
if img.size != (W, H):
    img = img.resize((W, H), Image.LANCZOS)

# ── Repair the dateline seam ─────────────────────────────────────────────────
# GMT's equirectangular projection does not cleanly paint the outermost pixel
# columns at ±180.  Two distinct artefacts appear over the black
# `coast -Gblack -Sblack` base:
#   • a fully-unpainted column at the +180 edge (pure 0,0,0), and
#   • a PARTIALLY-painted column at each ±180 edge, where the data is blended
#     ~50% with the black base and so reads systematically dark (e.g. a warm
#     orange cell at the dateline showing up as dark olive).
# The underlying grid is global, gap-free and continuous across the seam (the
# source XYZ and tropo.nc both confirm matching values at ±179.75), so these
# dark/black edge columns are never real data.  When HamClock reprojects the
# texture, a dark edge column meets the live opposite edge and shows as a fine
# line down the dateline.  Fix: (1) copy the nearest fully-painted column over
# any unpainted black band on the right, then (2) overwrite each outermost
# column with its painted neighbour to remove the half-painted artefact.
# Adjacent columns are ~0.25° apart, so the copy is visually exact.  Done
# before the D/N tint so copies inherit the same tint as their neighbours.
px = img.load()
def _black_frac(x):
    blk = sum(1 for y in range(H) if px[x, y] == (0, 0, 0))
    return blk / H
gx = W - 1
while gx > 0 and _black_frac(gx) > 0.5:
    gx -= 1
for x in range(gx + 1, W):
    for y in range(H):
        px[x, y] = px[gx, y]
# Overwrite the partially-painted outermost column on each side.
for y in range(H):
    px[0, y]     = px[1, y]
    px[W - 1, y] = px[W - 2, y]
print(f"  edge repair: rightmost fully-painted column={gx}; "
      f"both outermost columns copied from neighbours", file=sys.stderr)

from PIL import Image, ImageEnhance

if DN == "D":
    overlay = Image.new("RGB", img.size, (205, 220, 205))
    img = Image.blend(img, overlay, alpha=0.20)
elif DN == "N":
    img = ImageEnhance.Brightness(img).enhance(0.15)
pixels = img.tobytes()

pix = bytearray(W * H * 2)
j = 0
for i in range(0, len(pixels), 3):
    r, g, b = pixels[i], pixels[i+1], pixels[i+2]
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    pix[j]   = v & 0xFF
    pix[j+1] = (v >> 8) & 0xFF
    j += 2

bfOffBits = 14 + 108
bfSize    = bfOffBits + len(pix)
filehdr   = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, bfOffBits)
rmask, gmask, bmask, amask = 0xF800, 0x07E0, 0x001F, 0x0000
v4hdr = struct.pack("<IiiHHIIIIII",
    108, W, -H, 1, 16, 3, len(pix), 0, 0, 0, 0)
v4hdr += struct.pack("<IIII", rmask, gmask, bmask, amask)
v4hdr += struct.pack("<I", 0x73524742)
v4hdr += b"\x00" * 48

with open(outbmp, "wb") as f:
    f.write(filehdr)
    f.write(v4hdr)
    f.write(pix)

print(f"  -> Done: {outbmp}")
PY
}

# ── 7. Render one size/DN combination ───────────────────────────────────────

render_one() {
    local DN="$1" SZ="$2"
    local W=${SZ%x*}
    local H=${SZ#*x}
    local BASE="$GMT_USERDIR/tropo_${DN}_${SZ}"
    local PNG="${BASE}.png"

    # Prepare temporary paths on the same filesystem for atomic moves
    local T_BMP="${BASE}.bmp"
    local T_Z="${T_BMP}.z"
    local F_BMP="$OUTDIR/map-${DN}-${SZ}-Tropo.bmp"
    local F_Z="${F_BMP}.z"

    echo "  -> ${DN} ${SZ}"

    gmt begin "$BASE" png E72
        gmt set MAP_FRAME_PEN 0p PS_PAGE_COLOR black
        gmt coast -R-180/180/-90/90 -B0 -X0 -Y-0.5p -JQ0/${W}p -Gblack -Sblack -A10000
        gmt grdimage tropo.nc -Ctropo.cpt -nn -t20
        gmt coast  -R-180/180/-90/90 -B0 -JQ0/${W}p -W0.5p,white -N1/0.4p,white -A10000
    gmt end || { echo "  !! gmt failed for ${DN} ${SZ}"; return 1; }

    make_bmp_v4_rgb565_topdown "$PNG" "$T_BMP" "$W" "$H" "$DN" \
        || { echo "  !! bmp write failed for ${DN} ${SZ}"; return 1; }

    zlib_compress "$T_BMP" "$T_Z"

    # Atomic move into the web-accessible space
    mv "$T_BMP" "$F_BMP"
    mv "$T_Z" "$F_Z"

    rm -f "$PNG"
}

# ── 8. Render all sizes, D and N in parallel ────────────────────────────────

echo "Rendering Tropo maps..."
for DN in D N; do
    (
        for SZ in "${SIZES[@]}"; do
            render_one "$DN" "$SZ"
        done
    ) &
done
wait

# ── 9. Cleanup ───────────────────────────────────────────────────────────────

rm -f tropo.xyz tropo_raw.nc tropo.nc tropo.cpt "$GRFILE" gfs_run.env

echo "OK: Tropo maps updated into $OUTDIR  (GFS run ${GFS_DATE} ${GFS_HOUR}Z)"
