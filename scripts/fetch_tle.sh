#!/usr/bin/env bash
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
#  fetch_tle.sh
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

TLEDIR="/opt/hamclock-backend/tle"
ARCHIVE="$TLEDIR/archive"
TLEFILE="$TLEDIR/tles.txt"
TMPFILE="$TLEDIR/tles.new"
ESATS_OUT="/opt/hamclock-backend/htdocs/ham/HamClock/esats/esats.txt"

FILTER="/opt/hamclock-backend/scripts/filter_amsat_active.pl"

MOONTLE_SCRIPT="${MOONTLE_SCRIPT:-/opt/hamclock-backend/scripts/moontle.py}"
PYTHON_BIN="${PYTHON_BIN-/opt/hamclock-backend/venv/bin/python3}"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="/usr/bin/python3"
fi

mkdir -p "$TLEDIR" "$ARCHIVE" "$(dirname "$ESATS_OUT")"

URLS=(
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle"
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=tle"
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle"
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle"
)

CATNR_IDS=(
    62394   # CROCUBE
    62391   # LASARSAT
    60237   # GRBBETA
    98380   # HADES-SA (temp ID, launched 2026-03-30)
    67683   # KNACKSAT-2
    63235   # OTP-2 (Rogue Space)
    20580   # HST / Hubble Space Telescope
    25338   # NOAA-15 APT
    28654   # NOAA-18 APT
    33591   # NOAA-19 APT
)

# Satellites whose Celestrak name clashes or is absent — fetch by CATNR
# and rewrite the name line so the filter can match them.
declare -A CATNR_RENAME=(
    [67287]="LUCA"  # Luca (Montenegro) — Celestrak returns "LUCA (RS90S)", rename to "LUCA" for filter
)

ts() { date -u +"%Y%m%dT%H%M%SZ"; }

echo "[$(date -u)] Fetching TLEs..."

: > "$TMPFILE"

# Use -z to send If-Modified-Since based on existing tles.txt mtime.
# Celestrak returns 304/empty if unchanged, full data if updated.
# Drop -f so a 403 "not updated" response doesn't abort the script.
for u in "${URLS[@]}"; do
    curl -A "HamClock-Backend/1.0" -sSL \
        ${TLEFILE:+-z "$TLEFILE"} \
        "$u" >> "$TMPFILE" \
        || echo "WARNING: failed to fetch $u" >&2
    echo >> "$TMPFILE"
done

for id in "${CATNR_IDS[@]}"; do
    curl -A "HamClock-Backend/1.0" -sSL \
        "https://celestrak.org/NORAD/elements/gp.php?CATNR=${id}&FORMAT=tle" >> "$TMPFILE" \
        || echo "WARNING: NORAD $id not fetched" >&2
    echo >> "$TMPFILE"
done

# Sanity check — if Celestrak returned nothing new (all If-Modified-Since
# responses were empty), fall back to the existing tles.txt rather than
# wiping it with an empty file.
if ! grep -q '^1 ' "$TMPFILE"; then
    echo "NOTE: No new TLE data from Celestrak (data unchanged) — keeping existing tles.txt"
    rm -f "$TMPFILE"
else
    STAMP="$(ts)"
    cp "$TLEFILE" "$ARCHIVE/tles-${STAMP}-old.txt" 2>/dev/null || true
    mv "$TMPFILE" "$TLEFILE"
    echo "TLEs installed ($STAMP)"

    # Keep last 60 snapshots
    mapfile -t old_archives < <(ls -1t "$ARCHIVE"/tles-* 2>/dev/null | tail -n +61)
    [[ ${#old_archives[@]} -gt 0 ]] && rm -- "${old_archives[@]}"
fi

# Fetch satellites that need name rewriting (name clash or absent in Celestrak).
# Must run after tles.txt is installed so the mv doesn't overwrite our additions.
for id in "${!CATNR_RENAME[@]}"; do
    friendly="${CATNR_RENAME[$id]}"
    raw=$(curl -A "HamClock-Backend/1.0" -sSL \
        "https://celestrak.org/NORAD/elements/gp.php?CATNR=${id}&FORMAT=tle") || true
    if echo "$raw" | grep -q '^1 '; then
        echo "$raw" | awk -v name="$friendly" 'NR==1{print name} NR>1{print}' >> "$TLEFILE"
        echo >> "$TLEFILE"
        echo "  Added NORAD $id as '$friendly'" >&2
    else
        echo "WARNING: NORAD $id ($friendly) not fetched" >&2
    fi
done

# Always run AMSAT filter
echo "[$(ts)] Running AMSAT status filter..."
if env ESATS_TLE_CACHE="$TLEFILE" ESATS_OUT="$ESATS_OUT" perl "$FILTER"; then
    echo "[$(ts)] AMSAT filter complete — esats.txt updated"
else
    echo "WARNING: AMSAT filter failed — esats.txt not updated"
fi

# Append Moon TLE
echo "[$(ts)] Generating Moon TLE..."
if [[ -f "$MOONTLE_SCRIPT" ]]; then
    MOON_TLE=$("$PYTHON_BIN" -W ignore "$MOONTLE_SCRIPT" -q 2>/dev/null) && {
        echo "$MOON_TLE" >> "$ESATS_OUT"
        echo "[$(ts)] Moon TLE appended to esats.txt"
    } || echo "WARNING: moontle.py failed — Moon TLE not added"
else
    echo "WARNING: moontle.py not found at $MOONTLE_SCRIPT — Moon TLE not added"
fi

if ! grep -q '^1 25544U' "$TLEFILE"; then
    echo "WARNING: raw TLE cache is missing ISS NORAD 25544; stations fetch may have failed"
elif ! grep -qx 'ISS' "$ESATS_OUT"; then
    echo "WARNING: raw TLE cache contains ISS NORAD 25544, but esats.txt is missing ISS"
    echo "         filter_amsat_active.pl may be stale or alias matching failed"
fi
