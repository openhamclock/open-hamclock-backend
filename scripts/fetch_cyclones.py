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
import shutil
import urllib.request
import urllib.error
import datetime
import argparse
import tempfile
import math
import ssl
import re

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

NHC_CURRENT_STORMS_URL = "https://www.nhc.noaa.gov/CurrentStorms.json"

STORMS_OUTPUT_DIR = "/opt/hamclock-backend/htdocs/ham/HamClock/storms"
STORMS_OUTPUT_FILE = os.path.join(STORMS_OUTPUT_DIR, "storms.txt")
TMP_DIR = "/opt/hamclock-backend/tmp"

# ATCF best-track and forecast files -- used for live data and testing
# Active season: ftp.nhc.noaa.gov/atcf/btk/b{id}.dat (best track, updated in-season)
# Active fcst:   ftp.nhc.noaa.gov/atcf/fst/{id}.fst  (forecast, updated every 6h)
# Archive:       ftp.nhc.noaa.gov/atcf/archive/{year}/b{id}.dat.gz
ATCF_BTK_URL  = "https://ftp.nhc.noaa.gov/atcf/btk/b{storm_id}.dat"
ATCF_FST_URL  = "https://ftp.nhc.noaa.gov/atcf/fst/{storm_id}.fst"
ATCF_ARC_URL  = "https://ftp.nhc.noaa.gov/atcf/archive/{year}/b{storm_id}.dat.gz"

# JTWC products (W.Pacific, N.Indian, S.Hemisphere) -- NHC does NOT cover these
# basins. The old nrlmry.navy.mil/atcf_web feed was walled off behind Akamai and
# now returns an access-denied HTML page, so we read JTWC's ATCF data from NHC's
# public mirror instead -- the SAME host this script already uses for NHC data.
# We try a few candidate subdirs and use whichever actually contains JTWC
# b-decks, rather than hard-coding a layout that may shift over time.
JTWC_BTK_DIRS = [
    "https://ftp.nhc.noaa.gov/atcf/jtwc/",   # confirmed: holds bwp/bio/bsh*.dat
    "https://ftp.nhc.noaa.gov/atcf/btk/",    # fallback if JTWC ever merges here
]
JTWC_FST_DIRS = [
    "https://ftp.nhc.noaa.gov/atcf/jtwc/",
    "https://ftp.nhc.noaa.gov/atcf/fst/",
]
JTWC_BASINS = ("WP", "IO", "SH")
# A storm counts as active only if its latest best-track point is this recent.
# The mirror keeps dissipated storms around in-season, so this filter prevents
# plotting every dead system of the year (and keeps a storm visible briefly
# after it goes extratropical and drops from the warning set).
JTWC_RECENCY_HOURS = 24

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
    # W.Pacific / N.Indian / C.Pacific call hurricane-strength storms "typhoons";
    # the Southern Hemisphere calls them "tropical cyclones".
    is_typhoon_basin = basin in ("WP", "IO", "CP")
    is_sh_basin = basin == "SH"
    cat = 0
    stype = "TD"
    for threshold, t, c in CATEGORY_THRESHOLDS:
        if wind_kt >= threshold:
            stype = t
            cat = c
    if stype == "HU":
        if is_typhoon_basin:
            stype = "TY"
        elif is_sh_basin:
            stype = "TC"
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


def fetch_url(url, timeout=15, insecure=False):
    """
    Fetch URL, return text content or None on error.

    Some Navy/JTWC hosts (nrlmry.navy.mil) periodically serve an expired or
    otherwise unvalidated TLS certificate. Pass insecure=True to fall back to
    an unverified SSL context -- use it ONLY for those hosts.
    """
    ctx = ssl._create_unverified_context() if insecure else None
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'HamClock-OHB/1.0'})
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
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
    Returns list of parsed records with tau > 0, one per forecast hour.

    The OFCL forecast lists a separate row per wind-radii threshold (34/50/64
    kt) for the same forecast hour, so we keep one record per tau to avoid
    emitting duplicate track points.
    """
    atcf_id = storm_id.lower()
    url = ATCF_FST_URL.format(storm_id=atcf_id)
    data = fetch_url(url)
    if not data:
        return []
    dedup = {}
    for line in data.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        rec = parse_atcf_line(line)
        if rec and rec['tech'] == 'OFCL' and rec['tau'] > 0:
            dedup[rec['tau']] = rec
    return [dedup[t] for t in sorted(dedup)]


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
# Live JTWC data via NHC's public ATCF mirror
# ---------------------------------------------------------------------------
# JTWC issues for basins NHC does not cover (WP/IO/SH), but NHC mirrors JTWC's
# ATCF files on its public server. Same ATCF format as NHC, so parse_atcf_line()
# is reused. We auto-discover which subdir holds the b-decks and guard against
# HTML error pages being returned in place of data (the failure that silently
# broke the old nrlmry source).

def _is_denied(text):
    """True if text is an explicit access-denied / not-found / forbidden page."""
    head = text[:800].lower()
    return ("don't have permission" in head or 'access denied' in head
            or 'forbidden' in head or '404 not found' in head
            or 'not found' in head and '<html' in head)


def _is_html(text):
    """True if text is an HTML document (a data file should be plain text)."""
    head = text.lstrip()[:200].lower()
    return head.startswith('<!doctype') or head.startswith('<html') or '<html' in head


def fetch_listing(url):
    """
    Fetch a directory listing. Listings ARE html (Apache autoindex), so we only
    reject explicit denial/404 pages -- not html in general. This is the bug
    that previously made every listing look like an error.
    """
    text = fetch_url(url)
    if text is None:
        return None
    if _is_denied(text):
        print(f"# WARNING: {url} access denied / not found "
              f"-- source may have moved or be blocked", file=sys.stderr)
        return None
    return text


def fetch_data_url(url):
    """
    Fetch a data file (b-deck / forecast). These are plain-text ATCF, so any
    html response means a redirect/error page was served instead of data.
    """
    text = fetch_url(url)
    if text is None:
        return None
    if _is_denied(text) or _is_html(text):
        print(f"# WARNING: {url} returned a non-data page (html/denied) "
              f"-- skipping", file=sys.stderr)
        return None
    return text


def _fetch_first(dirs, filename):
    """Try filename under each base dir in turn; return text for the first hit."""
    for base in dirs:
        text = fetch_data_url(base + filename)
        if text:
            return text
    return None


def _dtg_age_hours(dtg):
    """Hours from an ATCF DTG (YYYYMMDDHH) to now (UTC); None if unparseable."""
    try:
        t = datetime.datetime.strptime(str(dtg)[:10], "%Y%m%d%H").replace(tzinfo=datetime.timezone.utc)
    except (ValueError, TypeError):
        return None
    return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 3600.0


def get_active_storm_ids_jtwc():
    """
    Discover JTWC storm IDs (WP/IO/SH) from NHC's public ATCF mirror by scanning
    the directory listing for b-deck filenames. Tries each candidate dir and
    uses the first that actually contains JTWC b-decks. Recency is filtered
    later, when each b-deck is read. Returns IDs like ['WP062026'].
    """
    for base in JTWC_BTK_DIRS:
        listing = fetch_listing(base)
        if not listing:
            continue
        ids, seen = [], set()
        for basin, num, year in re.findall(r'b(wp|io|sh)(\d{2})(\d{4})\.dat',
                                           listing, re.IGNORECASE):
            sid = f"{basin.upper()}{num}{year}"
            if sid not in seen:
                seen.add(sid)
                ids.append(sid)
        if ids:
            return ids
    print("# WARNING: no JTWC b-decks found in any NHC ATCF mirror dir "
          "(check JTWC_BTK_DIRS)", file=sys.stderr)
    return []


def fetch_storm_atcf_jtwc(storm_id):
    """Best-track records (tech=BEST) for a JTWC storm from the NHC mirror."""
    text = _fetch_first(JTWC_BTK_DIRS, f"b{storm_id.lower()}.dat")
    if not text:
        return []
    records = []
    for line in text.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        rec = parse_atcf_line(line)
        if rec and rec['tech'].upper() == 'BEST':
            records.append(rec)
    return records


def fetch_storm_forecast_jtwc(storm_id):
    """
    Official forecast track (tau>0) for a JTWC storm from its .fst file.
    JTWC's .fst may not label the official forecast 'OFCL' the way NHC does,
    so prefer OFCL/JTWC, else fall back to whichever technique has the most
    points. One record per forecast hour. Returns [] if no .fst is mirrored.
    """
    text = _fetch_first(JTWC_FST_DIRS, f"{storm_id.lower()}.fst")
    if not text:
        return []
    by_tech = {}
    for line in text.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        rec = parse_atcf_line(line)
        if rec and rec['tau'] > 0:
            by_tech.setdefault(rec['tech'].upper(), []).append(rec)
    if not by_tech:
        return []
    for pref in ('OFCL', 'JTWC'):
        if pref in by_tech:
            chosen = by_tech[pref]
            break
    else:
        chosen = max(by_tech.values(), key=len)
    dedup = {rec['tau']: rec for rec in chosen}
    return [dedup[t] for t in sorted(dedup)]


def get_jtwc_name(storm_id, btk_text=None):
    """
    Best-effort name. JTWC ATCF b-decks carry the storm name in field 28 once
    named; use it if present, else fall back to the short JTWC designator, e.g.
    WP062026 -> '06W', SH152026 -> '15S'.
    """
    basin, num = storm_id[:2].upper(), storm_id[2:4]
    suffix = {'WP': 'W', 'IO': 'B', 'SH': 'S', 'EP': 'E', 'CP': 'C'}.get(basin, '')
    designator = f"{num}{suffix}"
    if btk_text is None:
        btk_text = _fetch_first(JTWC_BTK_DIRS, f"b{storm_id.lower()}.dat")
    if btk_text:
        for line in reversed(btk_text.splitlines()):
            fields = [f.strip() for f in line.split(',')]
            if len(fields) > 27:
                cand = fields[27].upper()
                if cand.isalpha() and cand not in ('INVEST', 'NONAME', 'UNNAMED'):
                    return cand
    return designator


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
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")
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

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")
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

    # --- JTWC: W.Pacific / N.Indian / S.Hemisphere (not covered by NHC) ---
    jtwc_ids = get_active_storm_ids_jtwc()
    jtwc_active = 0
    for storm_id in jtwc_ids:
        basin = storm_id[:2]

        btk_records = fetch_storm_atcf_jtwc(storm_id)
        if not btk_records:
            print(f"# WARNING: no JTWC best-track for {storm_id}", file=sys.stderr)
            continue

        current = btk_records[-1]
        age = _dtg_age_hours(current['dtg'])
        if age is not None and age > JTWC_RECENCY_HOURS:
            # Dissipated / stale storm still sitting in the mirror -- skip it.
            print(f"# Skipping {storm_id}: last fix {age:.0f}h old", file=sys.stderr)
            continue
        jtwc_active += 1

        name = get_jtwc_name(storm_id)
        advisory = current['dtg']
        stype, cat = wind_to_category(current['vmax'], basin)
        all_storm_lines.append(
            f"{name},{basin},{stype},{cat},"
            f"{current['lat']:.1f},{current['lon']:.1f},"
            f"{current['vmax']},0,{advisory}"
        )

        for rec in fetch_storm_forecast_jtwc(storm_id):
            stype_f, cat_f = wind_to_category(rec['vmax'], basin)
            all_storm_lines.append(
                f"{name},{basin},{stype_f},{cat_f},"
                f"{rec['lat']:.1f},{rec['lon']:.1f},"
                f"{rec['vmax']},{rec['tau']},{advisory}"
            )

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")
    n = len(storm_ids) + jtwc_active
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

    os.makedirs(TMP_DIR, exist_ok=True)
    fd, tmpfile = tempfile.mkstemp(dir=TMP_DIR, prefix="storms", suffix=".tmp")
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(body)
        shutil.move(tmpfile, outfile)
        os.chmod(outfile, 0o644)
    except Exception:
        if os.path.exists(tmpfile):
            os.unlink(tmpfile)
        raise

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
        # Single storm mode -- route JTWC basins to the JTWC fetchers
        storm_id = args.storm.upper()
        basin = storm_id[:2]
        if basin in JTWC_BASINS:
            btk = fetch_storm_atcf_jtwc(storm_id)
            fst = fetch_storm_forecast_jtwc(storm_id)
            disp_name = get_jtwc_name(storm_id)
        else:
            btk = fetch_storm_atcf(storm_id)
            fst = fetch_storm_forecast(storm_id)
            disp_name = storm_id
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")
        lines = [f"# TROPICAL CYCLONES 1 storm ({storm_id}) as of {now} UTC"]
        if btk:
            current = btk[-1]
            advisory = current['dtg']
            stype, cat = wind_to_category(current['vmax'], basin)
            lines.append(
                f"{disp_name},{basin},{stype},{cat},"
                f"{current['lat']:.1f},{current['lon']:.1f},"
                f"{current['vmax']},0,{advisory}"
            )
        for rec in fst:
            stype_f, cat_f = wind_to_category(rec['vmax'], basin)
            lines.append(
                f"{disp_name},{basin},{stype_f},{cat_f},"
                f"{rec['lat']:.1f},{rec['lon']:.1f},"
                f"{rec['vmax']},{rec['tau']},{rec['dtg']}"
            )
    else:
        # Default: live data
        lines = get_live_output()

    write_storms_file(lines)


if __name__ == '__main__':
    main()
