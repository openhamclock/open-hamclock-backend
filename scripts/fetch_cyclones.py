#!/usr/bin/env python3
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
#  fetch_cyclones.py
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
"""
fetch_cyclones.py -- OHB backend for HamClock tropical cyclone overlay

Fetches active storm data from NOAA NHC (Atlantic/E.Pacific) and JTWC
(W.Pacific/Indian Ocean) and outputs a plain-text CSV file for HamClock
to consume via openCachedFile().

Output format (one line per forecast point):
  STORMNAME,BASIN,TYPE,CATEGORY,LAT,LON,WIND_KT,FCST_HOUR,ADVISORY

Where:
  STORMNAME  = storm name e.g. HELENE, or INVEST92L if unnamed
  BASIN      = AL (Atlantic), EP (E.Pacific), CP (C.Pacific), WP (W.Pacific), IO (Indian)
  TYPE       = TD|TS|HU|TY|TC|DB|EX  (Tropical Depression/Storm/Hurricane/Typhoon/etc)
  CATEGORY   = 0-5  (0 = TD or TS, 1-5 = Saffir-Simpson)
  LAT        = decimal degrees, positive=N negative=S
  LON        = decimal degrees, positive=E negative=W
  WIND_KT    = maximum sustained winds in knots
  FCST_HOUR  = 0=current position, 12,24,36,48,72,96,120 = forecast hours
  ADVISORY   = advisory number string e.g. "24" or "24A"

First line is always a comment with metadata:
  # TROPICAL CYCLONES N storms as of YYYY-MM-DD HH:MM UTC

HamClock uses FCST_HOUR=0 as the current position (drawn as bullseye)
and FCST_HOUR>0 as the forecast track (drawn as line + circles).

Update interval: every 6 hours matching NHC/JTWC advisory cadence.

--- TESTING WITHOUT ACTIVE STORMS ---
Run with --test to use built-in synthetic test data simulating two storms.
Run with --archive YYYY to pull a historical ATCF season file for testing.
Run with --storm AL052026 to pull a specific storm's live/archive ATCF data.

Usage:
  Production cron job:
    ./fetch_cyclones.py                      # writes storms.txt to HamClock web root

  Command line testing:
    ./fetch_cyclones.py --test               # synthetic test data
    ./fetch_cyclones.py --archive 2024       # 2024 season best tracks
    ./fetch_cyclones.py --storm AL092024     # specific storm ATCF

Output is always written to:
  /opt/hamclock-backend/htdocs/ham/HamClock/storms/storms.txt

The storms subdirectory is created automatically if it does not exist.
"""

import sys
import os
import json
import urllib.request
import urllib.error
import datetime
import argparse
import math

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

NHC_CURRENT_STORMS_URL = "https://www.nhc.noaa.gov/CurrentStorms.json"

STORMS_OUTPUT_DIR = "/opt/hamclock-backend/htdocs/ham/HamClock/storms"
STORMS_OUTPUT_FILE = os.path.join(STORMS_OUTPUT_DIR, "storms.txt")

# ATCF best-track and forecast files -- used for live data and testing
# Active season: ftp.nhc.noaa.gov/atcf/btk/b{id}.dat (best track, updated in-season)
# Active fcst:   ftp.nhc.noaa.gov/atcf/fst/{id}.fst  (forecast, updated every 6h)
# Archive:       ftp.nhc.noaa.gov/atcf/archive/{year}/b{id}.dat.gz
ATCF_BTK_URL  = "https://ftp.nhc.noaa.gov/atcf/btk/b{storm_id}.dat"
ATCF_FST_URL  = "https://ftp.nhc.noaa.gov/atcf/fst/{storm_id}.fst"
ATCF_ARC_URL  = "https://ftp.nhc.noaa.gov/atcf/archive/{year}/b{storm_id}.dat.gz"

# HURDAT2 -- contains storm names for all historical storms
# Format: header line "AL012024, ALBERTO, 13, ..." followed by track lines
HURDAT2_ATL_URL = "https://www.nhc.noaa.gov/data/hurdat/hurdat2-1851-{year}-052024.txt"
HURDAT2_ATL_LATEST = "https://www.nhc.noaa.gov/data/hurdat/hurdat2-atl-02052024.txt"

# Fallback: hardcoded 2024 Atlantic names by storm number
# (AL01=Alberto through AL19=unnamed TD, from NHC season summary)
KNOWN_NAMES = {
    'AL012024': 'ALBERTO',
    'AL022024': 'BERYL',
    'AL032024': 'CHRIS',
    'AL042024': 'DEBBY',
    'AL052024': 'ERNESTO',
    'AL062024': 'FRANCINE',
    'AL072024': 'GORDON',
    'AL082024': 'HAROLD',
    'AL092024': 'HELENE',
    'AL102024': 'ISAAC',
    'AL112024': 'JOYCE',
    'AL122024': 'KIRK',
    'AL132024': 'LESLIE',
    'AL142024': 'MILTON',
    'AL152024': 'NADINE',
    'AL162024': 'OSCAR',
    'AL172024': 'PATTY',
    'AL182024': 'RAFAEL',
    'AL192024': 'SARA',
}

# Category thresholds in knots (Saffir-Simpson + extensions)
CATEGORY_THRESHOLDS = [
    (0,   "TD",  0),   # < 34kt = TD
    (34,  "TS",  0),   # 34-63kt = TS
    (64,  "HU",  1),   # 64-82kt = Cat 1
    (83,  "HU",  2),   # 83-95kt = Cat 2
    (96,  "HU",  3),   # 96-112kt = Cat 3
    (113, "HU",  4),   # 113-136kt = Cat 4
    (137, "HU",  5),   # >= 137kt = Cat 5
]

def wind_to_category(wind_kt, basin="AL"):
    """Convert wind speed in knots to storm type and Saffir-Simpson category."""
    # W.Pacific uses Typhoon designations
    is_pacific = basin in ("WP", "IO", "CP")
    cat = 0
    stype = "TD"
    for threshold, t, c in CATEGORY_THRESHOLDS:
        if wind_kt >= threshold:
            stype = t
            cat = c
    if is_pacific and stype == "HU":
        stype = "TY"
    return stype, cat

# ---------------------------------------------------------------------------
# ATCF format parser
# ---------------------------------------------------------------------------
# ATCF best-track format: fixed-width CSV
# Fields: BASIN,CY,YYYYMMDDHH,TECHNUM,TECH,TAU,LAT,LON,VMAX,MSLP,TY,...
# See: https://www.nrlmry.navy.mil/atcf_web/docs/database/new/abrdeck.html

def parse_atcf_line(line):
    """Parse one line of ATCF format. Returns dict or None."""
    fields = [f.strip() for f in line.split(",")]
    if len(fields) < 12:
        return None
    try:
        basin    = fields[0].strip()
        cy       = fields[1].strip()        # cyclone number e.g. "05"
        dtg      = fields[2].strip()        # YYYYMMDDHH
        tech     = fields[4].strip()        # technique e.g. BEST, OFCL
        tau      = int(fields[5].strip())   # forecast hour (0 = analysis)
        lat_str  = fields[6].strip()        # e.g. "253N" = 25.3N
        lon_str  = fields[7].strip()        # e.g. "0801W" = 80.1W
        vmax     = int(fields[8].strip()) if fields[8].strip().lstrip('-').isdigit() else 0
        storm_type = fields[11].strip() if len(fields) > 11 else "XX"

        # parse lat/lon
        if lat_str.endswith('N'):
            lat = float(lat_str[:-1]) / 10.0
        elif lat_str.endswith('S'):
            lat = -float(lat_str[:-1]) / 10.0
        else:
            return None

        if lon_str.endswith('E'):
            lon = float(lon_str[:-1]) / 10.0
        elif lon_str.endswith('W'):
            lon = -float(lon_str[:-1]) / 10.0
        else:
            return None

        return {
            'basin':   basin,
            'cy':      cy,
            'dtg':     dtg,
            'tech':    tech,
            'tau':     tau,
            'lat':     lat,
            'lon':     lon,
            'vmax':    vmax,
            'type':    storm_type,
        }
    except (ValueError, IndexError):
        return None


def fetch_url(url, timeout=15):
    """Fetch URL, return text content or None on error."""
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'HamClock-OHB/1.0'})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode('utf-8', errors='replace')
    except Exception as e:
        print(f"# WARNING: fetch failed {url}: {e}", file=sys.stderr)
        return None


def build_hurdat2_name_map(year):
    """
    Fetch HURDAT2 for the given year and return a dict mapping
    storm ID (e.g. 'AL012024') to name (e.g. 'ALBERTO').

    HURDAT2 header line format:
      AL012024, ALBERTO,  13, ...
    """
    # HURDAT2 filename changes with each update -- scrape the directory index
    # to find the current Atlantic (atl) filename dynamically
    HURDAT2_INDEX = "https://www.nhc.noaa.gov/data/hurdat/"
    index_data = fetch_url(HURDAT2_INDEX, timeout=15)
    urls = []
    if index_data:
        # Look for Atlantic HURDAT2 links -- pattern: hurdat2-1851-YYYY-MMDDYY.txt
        import re
        matches = re.findall(r'hurdat2-1851-\d{4}-\d{6}\.txt', index_data)
        for m in sorted(set(matches), reverse=True):   # newest first
            urls.append(HURDAT2_INDEX + m)
    if not urls:
        # hardcoded fallback if index scrape fails
        urls = [
            "https://www.nhc.noaa.gov/data/hurdat/hurdat2-1851-2025-052024.txt",
        ]
    data = None
    for url in urls:
        data = fetch_url(url, timeout=20)
        if data:
            break

    name_map = {}
    if data:
        for line in data.splitlines():
            # Header lines start with basin+number+year e.g. "AL, 01, 2024,"
            # or compact format "AL012024, ALBERTO,"
            parts = [p.strip() for p in line.split(',')]
            if len(parts) >= 2:
                # Compact format: AL012024, ALBERTO, ...
                if len(parts[0]) == 8 and parts[0][:2].isalpha() and parts[0][2:].isdigit():
                    storm_id = parts[0].upper()
                    name = parts[1].strip().upper()
                    if name and name != 'UNNAMED':
                        name_map[storm_id] = name
                # Space-separated format: AL, 01, 2024, ALBERTO, ...
                elif parts[0] in ('AL','EP','CP','WP','IO') and len(parts) >= 4:
                    try:
                        basin = parts[0]
                        num   = parts[1].zfill(2)
                        yr    = parts[2]
                        name  = parts[3].strip().upper()
                        storm_id = f"{basin}{num}{yr}"
                        if name and name != 'UNNAMED':
                            name_map[storm_id] = name
                    except Exception:
                        pass

    # Merge with known names as fallback
    for sid, name in KNOWN_NAMES.items():
        if sid not in name_map:
            name_map[sid] = name

    return name_map


# ---------------------------------------------------------------------------
# Live NHC data via CurrentStorms.json + ATCF
# ---------------------------------------------------------------------------

def get_active_storm_ids_nhc():
    """
    Fetch NHC CurrentStorms.json and extract active storm wallet IDs.
    Returns list of storm IDs like ['AL052026', 'EP022026'].
    """
    data = fetch_url(NHC_CURRENT_STORMS_URL)
    if not data:
        return []
    try:
        storms_json = json.loads(data)
        ids = []
        # Structure: {"activeStorms": [{"id": "AL052026", "name": "HELENE", ...}, ...]}
        active = storms_json.get("activeStorms", [])
        for storm in active:
            storm_id = storm.get("id", "")
            if storm_id:
                ids.append(storm_id.upper())
        return ids
    except json.JSONDecodeError as e:
        print(f"# WARNING: JSON parse error: {e}", file=sys.stderr)
        return []


def fetch_storm_atcf(storm_id):
    """
    Fetch ATCF best-track for a storm ID like 'AL052026'.
    Returns list of parsed ATCF records (dicts).
    """
    # Convert wallet ID to ATCF filename: AL052026 -> al052026
    atcf_id = storm_id.lower()
    url = ATCF_BTK_URL.format(storm_id=atcf_id)
    data = fetch_url(url)
    if not data:
        return []
    records = []
    for line in data.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        rec = parse_atcf_line(line)
        if rec and rec['tech'] in ('BEST', 'best'):
            records.append(rec)
    return records


def fetch_storm_forecast(storm_id):
    """
    Fetch ATCF official forecast track for a storm ID.
    Returns list of parsed records with tau > 0.
    """
    atcf_id = storm_id.lower()
    url = ATCF_FST_URL.format(storm_id=atcf_id)
    data = fetch_url(url)
    if not data:
        return []
    records = []
    for line in data.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        rec = parse_atcf_line(line)
        if rec and rec['tech'] == 'OFCL' and rec['tau'] > 0:
            records.append(rec)
    return records


# ---------------------------------------------------------------------------
# Storm name lookup
# ---------------------------------------------------------------------------

def get_storm_name_from_json(storm_id):
    """Try to get human-readable storm name from CurrentStorms.json cache."""
    # We re-fetch here; in production OHB would cache this
    data = fetch_url(NHC_CURRENT_STORMS_URL)
    if not data:
        return storm_id
    try:
        storms_json = json.loads(data)
        for storm in storms_json.get("activeStorms", []):
            if storm.get("id", "").upper() == storm_id.upper():
                name = storm.get("name", storm_id)
                return name.upper()
    except Exception:
        pass
    return storm_id


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def format_storm_records(name, basin, records, advisory="0"):
    """
    Convert list of ATCF records to HamClock CSV output lines.
    Uses most recent BEST track position as tau=0 (current position)
    and forecast records as tau>0.
    """
    lines = []
    for rec in records:
        stype, cat = wind_to_category(rec['vmax'], basin)
        lat  = rec['lat']
        lon  = rec['lon']
        wind = rec['vmax']
        tau  = rec['tau']
        lines.append(f"{name},{basin},{stype},{cat},{lat:.1f},{lon:.1f},{wind},{tau},{advisory}")
    return lines


# ---------------------------------------------------------------------------
# Test data -- synthetic storms for development/testing
# ---------------------------------------------------------------------------

TEST_STORMS = [
    # Simulated Hurricane HELENE (Atlantic Cat 4, making Florida landfall)
    {
        'name': 'HELENE', 'basin': 'AL', 'advisory': '24',
        'records': [
            # current position
            {'lat': 25.3, 'lon': -80.1, 'vmax': 120, 'tau': 0,   'type': 'HU'},
            # forecast track
            {'lat': 26.5, 'lon': -81.5, 'vmax': 115, 'tau': 12,  'type': 'HU'},
            {'lat': 27.8, 'lon': -82.4, 'vmax': 110, 'tau': 24,  'type': 'HU'},
            {'lat': 29.2, 'lon': -82.8, 'vmax': 90,  'tau': 36,  'type': 'HU'},
            {'lat': 30.8, 'lon': -83.1, 'vmax': 70,  'tau': 48,  'type': 'TS'},
            {'lat': 32.5, 'lon': -83.4, 'vmax': 50,  'tau': 72,  'type': 'TS'},
            {'lat': 34.8, 'lon': -82.9, 'vmax': 35,  'tau': 96,  'type': 'TS'},
            {'lat': 37.2, 'lon': -81.5, 'vmax': 25,  'tau': 120, 'type': 'TD'},
        ]
    },
    # Simulated Typhoon KONG-REY (W.Pacific Cat 3)
    {
        'name': 'KONG-REY', 'basin': 'WP', 'advisory': '12',
        'records': [
            {'lat': 18.4, 'lon': 135.2, 'vmax': 100, 'tau': 0,   'type': 'TY'},
            {'lat': 19.8, 'lon': 132.5, 'vmax': 105, 'tau': 12,  'type': 'TY'},
            {'lat': 21.3, 'lon': 130.1, 'vmax': 110, 'tau': 24,  'type': 'TY'},
            {'lat': 23.0, 'lon': 127.8, 'vmax': 105, 'tau': 36,  'type': 'TY'},
            {'lat': 24.8, 'lon': 125.2, 'vmax': 95,  'tau': 48,  'type': 'TY'},
            {'lat': 26.5, 'lon': 122.9, 'vmax': 80,  'tau': 72,  'type': 'TY'},
            {'lat': 28.2, 'lon': 121.0, 'vmax': 60,  'tau': 96,  'type': 'TS'},
        ]
    },
]


def get_test_output():
    """Generate output from synthetic test data."""
    lines = []
    now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M")
    lines.append(f"# TROPICAL CYCLONES {len(TEST_STORMS)} storms (TEST DATA) as of {now} UTC")
    for storm in TEST_STORMS:
        name   = storm['name']
        basin  = storm['basin']
        adv    = storm['advisory']
        for rec in storm['records']:
            stype, cat = wind_to_category(rec['vmax'], basin)
            lines.append(
                f"{name},{basin},{stype},{cat},"
                f"{rec['lat']:.1f},{rec['lon']:.1f},"
                f"{rec['vmax']},{rec['tau']},{adv}"
            )
    return lines


# ---------------------------------------------------------------------------
# Archive data -- pull a past season for testing
# ---------------------------------------------------------------------------

def get_archive_output(year):
    """
    Pull ATCF best-track archive for a given year.
    Returns output lines showing all storms from that season.
    """
    import gzip
    import io

    lines = []
    # Atlantic archive index: all storms named bal{nn}{year}.dat.gz
    # We try al01 through al30
    storms_found = []
    for num in range(1, 31):
        storm_id = f"al{num:02d}{year}"
        url = ATCF_ARC_URL.format(year=year, storm_id=storm_id)
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'HamClock-OHB/1.0'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                raw = resp.read()
            # decompress gzip
            with gzip.open(io.BytesIO(raw)) as gz:
                data = gz.read().decode('utf-8', errors='replace')
            records = []
            name = f"AL{num:02d}"
            for line in data.splitlines():
                rec = parse_atcf_line(line)
                if rec:
                    if rec['tech'] in ('BEST', 'best'):
                        records.append(rec)
                        # try to get name from type field
                        if rec.get('type') not in ('', 'XX') and not name.startswith('AL'):
                            name = rec.get('type', name)
            if records:
                storms_found.append((f"AL{num:02d}{year}", records))
                print(f"# Found storm AL{num:02d}{year} with {len(records)} track points",
                      file=sys.stderr)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                pass  # storm doesn't exist for this number
            else:
                print(f"# HTTP {e.code} for {url}", file=sys.stderr)
        except Exception as e:
            print(f"# Error fetching {url}: {e}", file=sys.stderr)

    now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M")
    lines.append(f"# TROPICAL CYCLONES {len(storms_found)} storms ({year} archive) as of {now} UTC")

    # Build name lookup
    print(f"# Looking up storm names from HURDAT2...", file=sys.stderr)
    name_map = build_hurdat2_name_map(year)

    for storm_id, records in storms_found:
        # Use most recent track point as "current" (tau=0 output)
        # For archive data, all are best-track (tau=0) -- show full track
        basin = storm_id[:2]
        name = name_map.get(storm_id, storm_id)   # use name or fall back to ID
        print(f"# {storm_id} = {name}", file=sys.stderr)

        # For archive/display purposes, output every 6th track point
        for i, rec in enumerate(records):
            if i % 4 != 0 and i != len(records)-1:
                continue  # thin out to every 24h
            stype, cat = wind_to_category(rec['vmax'], basin)
            lines.append(
                f"{name},{basin},{stype},{cat},"
                f"{rec['lat']:.1f},{rec['lon']:.1f},"
                f"{rec['vmax']},0,ARCHIVE"
            )
    return lines


# ---------------------------------------------------------------------------
# Live mode -- fetch current active storms
# ---------------------------------------------------------------------------

def get_live_output():
    """Fetch all currently active NHC storms and return output lines."""
    lines = []
    storm_ids = get_active_storm_ids_nhc()

    all_storm_lines = []
    for storm_id in storm_ids:
        basin = storm_id[:2]
        name  = get_storm_name_from_json(storm_id)
        # fall back to known names table if JSON lookup failed
        if name == storm_id:
            name = KNOWN_NAMES.get(storm_id, storm_id)

        # Get current position from best track
        btk_records = fetch_storm_atcf(storm_id)
        if not btk_records:
            print(f"# WARNING: no ATCF data for {storm_id}", file=sys.stderr)
            continue

        # Most recent BEST track entry = current position
        current = btk_records[-1]
        advisory = current['dtg']  # use DTG as advisory reference
        stype, cat = wind_to_category(current['vmax'], basin)

        # Emit current position as tau=0
        all_storm_lines.append(
            f"{name},{basin},{stype},{cat},"
            f"{current['lat']:.1f},{current['lon']:.1f},"
            f"{current['vmax']},0,{advisory}"
        )

        # Get official forecast track
        fst_records = fetch_storm_forecast(storm_id)
        for rec in fst_records:
            stype_f, cat_f = wind_to_category(rec['vmax'], basin)
            all_storm_lines.append(
                f"{name},{basin},{stype_f},{cat_f},"
                f"{rec['lat']:.1f},{rec['lon']:.1f},"
                f"{rec['vmax']},{rec['tau']},{advisory}"
            )

    now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M")
    n = len(storm_ids)
    lines.append(f"# TROPICAL CYCLONES {n} storms as of {now} UTC")
    lines.extend(all_storm_lines)
    return lines


# ---------------------------------------------------------------------------
# Output helper
# ---------------------------------------------------------------------------

def write_storms_file(lines, outfile=STORMS_OUTPUT_FILE):
    """Create the storms output directory and atomically write storms.txt."""
    body = "\n".join(lines) + "\n"

    outdir = os.path.dirname(outfile)
    os.makedirs(outdir, mode=0o755, exist_ok=True)

    tmpfile = f"{outfile}.tmp"
    with open(tmpfile, 'w') as f:
        f.write(body)

    os.chmod(tmpfile, 0o644)
    os.replace(tmpfile, outfile)

    print(f"Written {len(lines)} lines to {outfile}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    # Command line mode only. This script is intended to run from cron.
    parser = argparse.ArgumentParser(description="Fetch tropical cyclone data for HamClock OHB")
    parser.add_argument('--test',    action='store_true',
                        help='Use synthetic test data (no network required)')
    parser.add_argument('--archive', metavar='YEAR',
                        help='Pull ATCF archive for a past year e.g. 2024')
    parser.add_argument('--storm',   metavar='ID',
                        help='Fetch specific storm ATCF e.g. AL052024')
    args = parser.parse_args()

    if args.test:
        lines = get_test_output()
    elif args.archive:
        lines = get_archive_output(args.archive)
    elif args.storm:
        # Single storm mode
        storm_id = args.storm.upper()
        basin = storm_id[:2]
        btk = fetch_storm_atcf(storm_id)
        fst = fetch_storm_forecast(storm_id)
        now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M")
        lines = [f"# TROPICAL CYCLONES 1 storm ({storm_id}) as of {now} UTC"]
        if btk:
            current = btk[-1]
            advisory = current['dtg']
            stype, cat = wind_to_category(current['vmax'], basin)
            lines.append(
                f"{storm_id},{basin},{stype},{cat},"
                f"{current['lat']:.1f},{current['lon']:.1f},"
                f"{current['vmax']},0,{advisory}"
            )
        for rec in fst:
            stype_f, cat_f = wind_to_category(rec['vmax'], basin)
            lines.append(
                f"{storm_id},{basin},{stype_f},{cat_f},"
                f"{rec['lat']:.1f},{rec['lon']:.1f},"
                f"{rec['vmax']},{rec['tau']},{rec['dtg']}"
            )
    else:
        # Default: live data
        lines = get_live_output()

    write_storms_file(lines)


if __name__ == '__main__':
    main()
