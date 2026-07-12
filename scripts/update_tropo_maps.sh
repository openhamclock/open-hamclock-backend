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
#  Generates global tropospheric ducting-gradient (dN/dz) overlay
#  maps for HamClock using NOAA GFS model data.
#
#  Ducting needs more than warm, humid surface air: it needs a strong
#  NEGATIVE vertical gradient of refractivity (dN/dz) in the lowest
#  ~1.5 km — a temperature inversion or moisture step that traps the
#  radio wave.  This script computes that gradient from GFS fields at
#  the surface, 925 mb and 850 mb (Smith-Weintraub N at each level,
#  divided by the model's own geopotential-height separation between
#  levels) and colours the MORE NEGATIVE of the two layer gradients:
#
#     dN/dz  >  -39 N/km   : standard atmosphere (world average, no effect)
#     -157 < dN/dz < -39   : super-refraction (enhanced range)
#     dN/dz  < -157 N/km   : trapping / ducting (ray curvature matches
#                             the curvature of the Earth at -157 N/km)
#
#  This replaces the previous approach of colouring raw surface N-units,
#  which flags "warm and humid" without checking whether a trapping
#  layer actually exists above it.
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

# ── 2. Download surface + 925/850 mb fields from NOMADS GRIB filter ─────────
#
# The filter returns only the requested variables — still a few MB instead
# of the full ~500 MB GFS file.  Fields requested:
#   TMP, RH  @ 2 m above ground, 925 mb, 850 mb   (temperature K, humidity %)
#   PRES     @ surface                             (surface pressure, Pa)
#   HGT      @ surface, 925 mb, 850 mb             (terrain elevation /
#                                                    geopotential height, m —
#                                                    needed for the TRUE
#                                                    height separation between
#                                                    levels at each grid
#                                                    point, since terrain
#                                                    varies)
#   HPBL     @ surface                             (boundary-layer height, m
#                                                    — a light qualitative
#                                                    check, see step 3)

GRFILE="gfs_sfc.grb2"
NOMADS_BASE="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
NOMADS_URL="${NOMADS_BASE}?dir=%2Fgfs.${GFS_DATE}%2F${GFS_HOUR}%2Fatmos"
NOMADS_URL+="&file=gfs.t${GFS_HOUR}z.pgrb2.0p25.f000"
NOMADS_URL+="&var_TMP=on&var_RH=on&var_PRES=on&var_HGT=on&var_HPBL=on"
NOMADS_URL+="&lev_2_m_above_ground=on&lev_surface=on"
NOMADS_URL+="&lev_925_mb=on&lev_850_mb=on"

curl -fsSL --max-time 120 -A "open-hamclock-backend/1.0" \
    "$NOMADS_URL" -o "$GRFILE"

GRIB_BYTES=$(stat -c '%s' "$GRFILE")
echo "  Downloaded ${GRIB_BYTES} bytes"
if [[ "$GRIB_BYTES" -lt 50000 ]]; then
    echo "ERROR: GRIB file suspiciously small — NOMADS may have returned an error page" >&2
    cat "$GRFILE" >&2
    exit 1
fi

# ── 3. Compute N at 3 levels, take dN/dz, and write XYZ ──────────────────────
#
# Smith-Weintraub formula (applied at surface, 925 mb, 850 mb):
#   N = 77.6·P/T  +  3.73×10⁵·e/T²
#
# where P = total pressure (hPa), e = water vapour pressure (hPa), T = K.
# Saturation vapour pressure from the Magnus formula:
#   e_s = 6.1078 · exp(17.2694 · Tc / (Tc + 237.29))    (hPa)
#   e   = (RH/100) · e_s
#
# The GRADIENT dN/dz between adjacent levels — not the absolute N value —
# is what determines ducting.  See the header comment for thresholds.

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
# open_datasets() (plural) splits the file into per-hypercube groups and
# returns them all — no filter_by_keys needed.  The diagnostic confirmed this
# works correctly with GFS GRIB2 where open_dataset(filter_by_keys=...) fails.
# Flat (surface-type) fields go in all_fields; anything with an isobaricInhPa
# dimension goes in level_fields, keyed by variable name then level in mb, so
# a single request covering 925+850mb is handled whether cfgrib bundles both
# levels into one hypercube or splits them into separate ones.  We pick by
# priority: specific 2m names first so we never accidentally use skin
# temperature ('t') instead of 2m temp ('t2m').

all_fields = {}     # flat (surface-type) fields:  name -> 2D array
level_fields = {}   # pressure-level fields:       name -> {level_mb: 2D array}
lats = lons = None

for ds in cfgrib.open_datasets(GRFILE):
    is_plevel = 'isobaricInhPa' in ds.coords
    for var in ds.data_vars:
        da = ds[var]
        if lats is None:
            lats = ds.coords['latitude'].values   # 90 → -90
            lons = ds.coords['longitude'].values  # 0 → 359.75
        if is_plevel:
            levels = np.atleast_1d(ds.coords['isobaricInhPa'].values).astype(int)
            for lv in levels:
                vals = da.sel(isobaricInhPa=lv).values if levels.size > 1 else da.values
                level_fields.setdefault(var, {})[int(lv)] = vals
                print(f"  {var}@{int(lv)}mb: range=[{vals.min():.1f}, {vals.max():.1f}]", file=sys.stderr)
        else:
            vals = da.values
            all_fields[var] = vals
            print(f"  {var}: range=[{vals.min():.1f}, {vals.max():.1f}]", file=sys.stderr)

def require(candidates, label):
    for name in candidates:
        if name in all_fields:
            print(f"  Using '{name}' for {label}", file=sys.stderr)
            return all_fields[name]
    raise RuntimeError(f"Could not find {label} in {GRFILE}; available fields: {list(all_fields)}")

def require_level(candidates, level_mb, label):
    for name in candidates:
        if name in level_fields and level_mb in level_fields[name]:
            print(f"  Using '{name}'@{level_mb}mb for {label}", file=sys.stderr)
            return level_fields[name][level_mb]
    have = {k: sorted(v) for k, v in level_fields.items()}
    raise RuntimeError(f"Could not find {label} at {level_mb}mb; available level fields: {have}")

T_K     = require(['t2m', '2t'],           '2m temperature')
RH      = require(['r2', '2r', 'r'],       '2m relative humidity')
P_Pa    = require(['sp', 'pres', 'PRES'],  'surface pressure')
HGT_sfc = require(['orog', 'HGT', 'gh', 'z'], 'surface elevation')

T_925 = require_level(['t'],               925, '925mb temperature')
RH_925 = require_level(['r'],              925, '925mb relative humidity')
Z_925 = require_level(['gh', 'z', 'HGT'],  925, '925mb geopotential height')

T_850 = require_level(['t'],               850, '850mb temperature')
RH_850 = require_level(['r'],              850, '850mb relative humidity')
Z_850 = require_level(['gh', 'z', 'HGT'],  850, '850mb geopotential height')

# ── Refractivity (Smith-Weintraub), reusable across all 3 levels ────────────
def refractivity(T_K, RH, P_hPa):
    T_K = np.asarray(T_K, dtype=float)
    if T_K.max() < 100:
        print("Warning: a TMP field appears to be Celsius, adding 273.15", file=sys.stderr)
        T_K = T_K + 273.15
    Tc  = T_K - 273.15
    e_s = 6.1078 * np.exp(17.2694 * Tc / (Tc + 237.29))   # sat. vapour pressure, hPa
    e   = np.clip(RH, 0, 110) / 100.0 * e_s                # actual vapour pressure, hPa
    return 77.6 * P_hPa / T_K + 3.73e5 * e / T_K**2        # N-units

P_hPa_sfc = P_Pa / 100.0 if P_Pa.max() > 10000 else P_Pa   # Pa → hPa

N_sfc = refractivity(T_K, RH, P_hPa_sfc)
N_925 = refractivity(T_925, RH_925, 925.0)
N_850 = refractivity(T_850, RH_850, 850.0)

for label, arr in (('sfc', N_sfc), ('925mb', N_925), ('850mb', N_850)):
    print(f"  N[{label}] range: [{arr.min():.1f}, {arr.max():.1f}] N-units", file=sys.stderr)

# ── Vertical gradient of N (dN/dz) ───────────────────────────────────────────
#
# Ducting needs a strong NEGATIVE dN/dz, not just high absolute N.  We use
# the model's own geopotential height at each level (not a fixed nominal
# height) so the layer thickness is correct at every grid point, including
# over high terrain.  A minimum 50 m separation guards against divide-by-~0
# blow-ups where a pressure level sits at/below the local terrain.
MIN_LAYER_M = 50.0

dz_sfc925 = Z_925 - HGT_sfc
above925 = dz_sfc925 > MIN_LAYER_M   # is the 925mb level actually above local terrain?
grad_sfc925 = np.where(above925,
                        (N_925 - N_sfc) / (dz_sfc925 / 1000.0), np.nan)

# If 925mb is at/below local terrain it isn't a real measurement (GFS
# extrapolates below-ground pressure levels), so gate BOTH layers on
# above925 -- a bad 925mb value would otherwise corrupt the 925-850mb
# gradient too, even though that layer doesn't touch HGT_sfc directly.
dz_925850 = Z_850 - Z_925
grad_925850 = np.where(above925 & (dz_925850 > MIN_LAYER_M),
                        (N_850 - N_925) / (dz_925850 / 1000.0), np.nan)

# Take whichever layer shows the stronger (more negative) trapping signal —
# this catches both surface-based ducts (sfc-925mb) and elevated subsidence
# inversions (925-850mb, e.g. the marine-layer ducts common off west coasts).
# np.fmin ignores NaN unless BOTH layers are NaN (e.g. high terrain).
G = np.fmin(grad_sfc925, grad_925850)

print(f"  dN/dz range: [{np.nanmin(G):.1f}, {np.nanmax(G):.1f}] N-units/km  "
      f"(standard atm. ~ -39, trapping threshold = -157)", file=sys.stderr)

# Best-effort qualitative check: a real duct is a SHARP, thin trapping layer.
# If the model's own diagnosed boundary-layer depth is deep, our gradient is
# more likely smearing a deep well-mixed layer than showing a genuine duct,
# so we discount it.  This is a heuristic, not a physical correction — tune
# or remove HPBL_DISCOUNT_ABOVE_M as you like.  A live run showed cfgrib
# doesn't resolve HPBL's short_name against this GFS file at all -- it comes
# back as a generic 'unknown' variable (visible in the field-extraction log
# as `unknown: range=[7.4, 5890.6]`, an unmistakably HPBL-shaped range).
# 'unknown' is therefore included as a last-resort candidate, gated by a
# plausibility check on the value range so a future GFS/cfgrib change that
# leaves some OTHER field unnamed can't get silently mistaken for HPBL.
#
# TEMPORARILY DISABLED so we can see how much of the washed-out look the
# percentile palette (below) fixes on its own, without this also in the mix.
# Flip back to True once we've seen a real run with it off.
APPLY_HPBL_DISCOUNT = False
HPBL_DISCOUNT_ABOVE_M = 1500.0
if APPLY_HPBL_DISCOUNT:
    try:
        HPBL = require(['hpbl', 'HPBL', 'blh', 'pblh', 'unknown'], 'boundary-layer height')
        lo, hi = float(np.nanmin(HPBL)), float(np.nanmax(HPBL))
        if not (0 <= lo and hi < 10000):
            raise RuntimeError(f"boundary-layer height candidate has an implausible "
                                f"range [{lo:.0f}, {hi:.0f}] m -- likely the wrong field")
        deep = HPBL > HPBL_DISCOUNT_ABOVE_M
        G = np.where(deep & (G < 0), G * 0.5, G)
        print(f"  HPBL discount applied at {int(np.nansum(deep))} pts "
              f"(PBL > {HPBL_DISCOUNT_ABOVE_M:.0f} m)", file=sys.stderr)
    except RuntimeError as ex:
        print(f"  Note: {ex} -- skipping HPBL discount", file=sys.stderr)
else:
    print("  HPBL discount disabled (APPLY_HPBL_DISCOUNT=False) — isolating the "
          "percentile-palette fix", file=sys.stderr)

# Fixed absolute N/km thresholds (the first version of this script) rarely
# get reached by a 0.25 deg global model: real ducts are often narrower than
# a ~28 km GFS cell, so their true intensity is diluted before it ever reaches
# this calculation.  Tested directly: a realistic 15 km coastal duct that
# reads -131.8 N/km at 1 km resolution reads as only -84.9 N/km once averaged
# onto a 25 km grid -- 36% of the signal is gone before we even start.  Fixed
# thresholds anchored to textbook physics (-39, -157) then leave nearly the
# whole map sitting in the bottom 2-3 bands.
#
# A PURE global-percentile fix solved that but created a
# different problem: it ranks every point against the WHOLE PLANET, so a
# merely warm/humid/well-mixed region with no cap at all -- Florida in July
# is the textbook case -- can still land in the globe's own most-negative
# tail on a globally calm day, purely by comparison, and get painted
# "intense" with no real duct present.  Confirmed against a live run: a
# synthetic no-duct, well-mixed profile that computes -72.5 N/km landed as
# band 6 (VERY STRONG) under that day's actual edges, because the *whole
# world* only reached -119.9 at the 99.3rd percentile.
#
# A FIXED floor for band 0/1, so a merely humid non-ducting profile
# reads as unremarkable no matter how calm the rest of the planet is that
# day -- then percentile-spread bands 1..10+ only among points that already
# cleared the floor, so the upper bands are relative severity among places
# with a genuine signal, not a rescaling of the planet's overall mood.
BAND_COLOURS = [
    (68, 68, 68), (134, 3, 241), (1, 180, 239), (2, 208, 131), (165, 235, 1),
    (239, 222, 5), (233, 177, 12), (255, 128, 0), (255, 0, 0), (255, 128, 192), (255, 180, 220),
]  # bands 0 .. 10+, indices match the legend

# BAND0_FLOOR is fixed, not recomputed per run.  Swept several candidate
# values against the no-duct "hot, humid, well-mixed, no cap" test case
# (computes -72.5 N/km) and the real-duct case (-175.2 N/km):
#
#   floor  % of globe "elevated"   no-cap case lands at   real duct lands at
#   -55    49.8%                   band 4 (too high)      band 9
#   -65    32.5%                   band 2                 band 9
#   -70    26.4%                   band 1                 band 9
#   -75    21.5%                   band 0 (too low?)      band 9
#   -80    17.5%                   band 0                 band 8
#
# -70 is the sweet spot
BAND0_FLOOR = -70.0

# Cumulative % of ELEVATED (already past the floor) pixels, counted from the
# mildest end, that fall at/below each of the 9 upper boundaries -- band 1 is
# the mildest 15% of today's elevated points, band 10+ is the most severe 2%.
CUM_PCT_FROM_MILD_ELEVATED = [15, 30, 45, 58, 70, 80, 88, 94, 98]
valid_G = G[np.isfinite(G)]
elevated = valid_G[valid_G < BAND0_FLOOR]
if elevated.size > 100:
    pct_of_elev = [100 - p for p in CUM_PCT_FROM_MILD_ELEVATED]
    inner_edges = np.percentile(elevated, pct_of_elev)
else:
    # Degenerate case (e.g. a tiny test grid): space edges evenly below the
    # floor instead of crashing on a near-empty percentile call.
    print(f"  Note: only {elevated.size} points past BAND0_FLOOR -- "
          f"using evenly-spaced fallback edges instead of percentiles", file=sys.stderr)
    inner_edges = np.linspace(BAND0_FLOOR - 90, BAND0_FLOOR - 10, len(CUM_PCT_FROM_MILD_ELEVATED))
edges = np.sort(np.append(inner_edges, BAND0_FLOOR))  # ascending: GMT needs z0 < z1 per row

print(f"  Band edges (N/km, ascending, floor={BAND0_FLOOR:.0f}): "
      f"{', '.join(f'{e:.1f}' for e in edges)}  "
      f"[{elevated.size} of {valid_G.size} pts past the floor]", file=sys.stderr)

cpt_lines = []
for i in range(len(edges) - 1):        # 9 rows: bands 9 down to 1
    z0, z1 = edges[i], edges[i + 1]
    r, gc, b = BAND_COLOURS[9 - i]
    cpt_lines.append(f"{z0:.2f}  {r}/{gc}/{b}   {z1:.2f}  {r}/{gc}/{b}")
r, gc, b = BAND_COLOURS[0]              # band 0: everything milder than the floor
cpt_lines.append(f"{edges[-1]:.2f}  {r}/{gc}/{b}   {edges[-1] + 50:.2f}  {r}/{gc}/{b}")

r10, g10, b10 = BAND_COLOURS[10]
r0, g0b, b0 = BAND_COLOURS[0]
with open("tropo.cpt", "w") as f:
    f.write("\n".join(cpt_lines) + "\n")
    f.write(f"B      {r10}/{g10}/{b10}\n")   # below the lowest edge: band 10+
    f.write(f"F      {r0}/{g0b}/{b0}\n")     # above the highest edge: band 0
    f.write("N      0/0/0\n")

print("  Wrote percentile-based tropo.cpt (11 bands)", file=sys.stderr)

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
mask = np.isfinite(G.ravel())
with open("tropo.xyz", "w") as f:
    for lo, la, gv in zip(LON.ravel()[mask], LAT.ravel()[mask], G.ravel()[mask]):
        f.write(f"{lo:.3f} {la:.3f} {gv:.2f}\n")

    # Close the dateline: copy the +180 column to -180.
    edge = np.isclose(lons_adj, 180.0)
    G_edge   = G[:, edge].ravel()
    LAT_edge = LAT[:, edge].ravel()
    em = np.isfinite(G_edge)
    for la, gv in zip(LAT_edge[em], G_edge[em]):
        f.write(f"{-180.0:.3f} {la:.3f} {gv:.2f}\n")

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
# tropo.cpt is now written directly by the Python step above (percentile
# band edges depend on this run's own G array, so it has to happen there,
# not here as a static heredoc).  Nothing to do in this step any more --
# left as a numbered placeholder so the step numbering in later comments
# ("step 3", etc.) still lines up with a human reading top to bottom.

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
    img = ImageEnhance.Brightness(img).enhance(0.46)
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
