#!/usr/bin/env python3

# Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
update_world_wx.py — Fetch world weather via OpenWeatherMap and write wx.txt
for HamClock in the exact format produced by the original update_world_wx.pl.

Output grid: lat -90..90 step 4, lon -180..180 step 5 (46×73 = 3,358 points).
Fetch order: cities from cities.txt (snapped to grid) first, then remaining
grid points — so named cities always have the freshest data.

Usage:
    OPEN_WEATHER_API_KEY=your_key python3 update_world_wx.py

Environment variables:
    OPEN_WEATHER_API_KEY Required. OpenWeatherMap API key.
    WORLDWX_OUT          Output wx.txt path.
                         Default: /opt/hamclock-backend/htdocs/ham/HamClock/worldwx/wx.txt
    WORLDWX_TMP          Directory for cache/state files.
                         Default: /opt/hamclock-backend/tmp/worldwx
    OWM_REQS_PER_RUN     Requests to make per invocation. Default: 10
    OWM_SLEEP            Seconds to sleep between requests. Default: 1.1
    OWM_RETRIES          Max retry attempts per request. Default: 3
    OWM_BACKOFF_START    Initial backoff seconds. Default: 5
    OWM_BACKOFF_CAP      Max backoff seconds. Default: 60

Cron example (10 req every 2 min → all ~1,700 cities fresh in ~5 hrs):
    */2 * * * * OPEN_WEATHER_API_KEY=YOUR_KEY python3 /opt/hamclock-backend/update_world_wx.py
"""

import json
import os
import re
import sys
import shutil
import tempfile
import time
import warnings

try:
    import requests
except ImportError:
    sys.exit("ERROR: 'requests' library not found. Run: pip3 install requests")

try:
    from global_land_mask import globe as _globe
    _HAS_LAND_MASK = True
except ImportError:
    _HAS_LAND_MASK = False
    print("WARN: global-land-mask not installed; ocean skipping disabled. "
          "Run: pip3 install global-land-mask", file=sys.stderr)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
OPEN_WEATHER_API_KEY   = os.environ.get("OPEN_WEATHER_API_KEY", "")

# If API key not in env, try reading from .env file
if not OPEN_WEATHER_API_KEY and os.path.exists("/opt/hamclock-backend/.env"):
    with open("/opt/hamclock-backend/.env", "r") as f:
        for line in f:
            if line.startswith("OPEN_WEATHER_API_KEY="):
                OPEN_WEATHER_API_KEY = line.strip().split("=", 1)[1].strip("'\"")
                break

OUT_TXT       = os.environ.get(
    "WORLDWX_OUT",
    "/opt/hamclock-backend/htdocs/ham/HamClock/worldwx/wx.txt",
)
TMP_DIR       = os.environ.get(
    "WORLDWX_TMP",
    "/opt/hamclock-backend/tmp/worldwx",
)
CITIES_FILE   = "/opt/hamclock-backend/htdocs/ham/HamClock/cities2.txt"
CACHE_JSON    = os.path.join(TMP_DIR, "cache.json")
STATE_JSON    = os.path.join(TMP_DIR, "state.json")

REQS_PER_RUN  = int(os.environ.get("OWM_REQS_PER_RUN",   "10"))
SLEEP_BETWEEN = float(os.environ.get("OWM_SLEEP",         "1.1"))
MAX_TRIES     = int(os.environ.get("OWM_RETRIES",         "3"))
BACKOFF_START = float(os.environ.get("OWM_BACKOFF_START", "5"))
BACKOFF_CAP   = float(os.environ.get("OWM_BACKOFF_CAP",   "60"))

# ---------------------------------------------------------------------------
# Fixed output grid — must match wx.txt exactly
# ---------------------------------------------------------------------------
LATS = list(range(-90, 91, 4))   # -90 .. 90  step 4 → 46 values
LONS = list(range(-180, 181, 5)) # -180 .. 180 step 5 → 73 values

# Fallback record for grid points not yet fetched
FALLBACK = {
    "temp": 0.0, "hum": 0.0, "mps": 0.0,
    "dir":  0.0, "prs": 0.0, "wx": "Unknown", "tz": 0,
}

# OWM API endpoint
OWM_URL = "https://api.openweathermap.org/data/2.5/weather"

# ---------------------------------------------------------------------------
# OWM weather ID → HamClock wx token
# ---------------------------------------------------------------------------
def wx_from_owm_id(owm_id):
    if owm_id is None:
        return "Unknown"
    if owm_id == 800:
        return "Clear"
    if 801 <= owm_id <= 804:
        return "Clouds"
    if 700 <= owm_id <= 799:
        return "Fog"
    if 300 <= owm_id <= 321:
        return "Rain"       # drizzle
    if owm_id in (500, 501, 502, 503, 504):
        return "Rain"
    if 520 <= owm_id <= 531:
        return "Rain"       # showers
    if owm_id == 511:
        return "Snow"       # freezing rain
    if 600 <= owm_id <= 622:
        return "Snow"
    if 200 <= owm_id <= 232:
        return "Thunderstorm"
    return "Unknown"

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
def read_json(path, default=None):
    """Read a JSON file, returning default on any error."""
    if default is None:
        default = {}
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:
        print(f"WARN: could not read {path}: {exc}", file=sys.stderr)
        return default


def write_json_atomic(path, obj):
    """Write obj as JSON to path atomically (tmp file + os.replace)."""
    os.makedirs(TMP_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=TMP_DIR, prefix="cache", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh)
        shutil.move(tmp, path)
        os.chmod(path, 0o644)
    except Exception as exc:
        print(f"WARN: could not write {path}: {exc}", file=sys.stderr)
        try:
            os.unlink(tmp)
        except OSError:
            pass

# ---------------------------------------------------------------------------
# City list
# ---------------------------------------------------------------------------
_CITY_RE = re.compile(r'^(-?\d+\.?\d*),\s*(-?\d+\.?\d*),\s*"(.+)"')

def load_cities(path):
    """
    Parse cities.txt into a list of dicts: {lat, lon, label}.
    Returns empty list with a warning if the file is missing or unreadable.
    """
    if not os.path.isfile(path):
        print(f"WARN: cities file not found: {path} — fetching grid in default order",
              file=sys.stderr)
        return []
    cities = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = _CITY_RE.match(line.strip())
                if m:
                    cities.append({
                        "lat":   float(m.group(1)),
                        "lon":   float(m.group(2)),
                        "label": m.group(3),
                    })
    except Exception as exc:
        print(f"WARN: error reading {path}: {exc}", file=sys.stderr)
    return cities

# ---------------------------------------------------------------------------
# Grid helpers
# ---------------------------------------------------------------------------
def snap_to_grid(lat, lon):
    """Snap a float lat/lon to the nearest point that exists in LATS/LONS.

    Simple rounding to nearest multiple of 4/5 does NOT work because the
    lat grid steps from -90 by 4 and skips 0 (goes -2, 2). We must find
    the nearest value actually present in the grid arrays.
    """
    best_lat = min(LATS, key=lambda x: abs(x - lat))
    best_lon = min(LONS, key=lambda x: abs(x - lon))
    return (best_lat, best_lon)


def build_fetch_queue(cities):
    """
    Build ordered fetch queue:
      1. Cities from cities.txt snapped to grid (highest priority).
      2. Remaining grid points not covered by any city.
    Returns (queue, city_slots) where city_slots is the number of
    city-derived entries at the front of the queue.
    """
    seen  = set()
    queue = []

    # Stage 1: named cities — snap each to nearest grid point, deduplicate.
    # snap_to_grid always clamps to valid range so no GRID_SET filter needed.
    for city in cities:
        gp = snap_to_grid(city["lat"], city["lon"])
        if gp not in seen:
            seen.add(gp)
            queue.append({"lat": gp[0], "lon": gp[1], "label": city["label"], "fetch_lat": city["lat"], "fetch_lon": city["lon"]})

    city_slots = len(queue)

    # Stage 2: remaining grid points (lon-major to match wx.txt write order).
    # Skip pure-ocean points that have no city — no useful weather display there.
    # If global_land_mask is unavailable, fall back to fetching all points.
    skipped = 0
    for lon in LONS:
        for lat in LATS:
            if (lat, lon) not in seen:
                if _HAS_LAND_MASK and not _globe.is_land(lat, lon):
                    skipped += 1
                    continue  # pure ocean, no city — skip
                seen.add((lat, lon))
                queue.append({"lat": lat, "lon": lon, "label": None, "fetch_lat": lat, "fetch_lon": lon})

    if skipped:
        print(f"INFO: skipped {skipped} pure-ocean grid points (no city nearby).",
              file=sys.stderr)

    return queue, city_slots

# ---------------------------------------------------------------------------
# OWM fetch with retry / exponential backoff
# ---------------------------------------------------------------------------
def parse_owm(data):
    """Extract weather fields from an OWM /weather JSON response."""
    main    = data.get("main", {})
    wind    = data.get("wind", {})
    weather = data.get("weather", [{}])
    owm_id  = weather[0].get("id") if weather else None

    # Prefer sea-level pressure; fall back to station pressure
    prs = main.get("sea_level") or main.get("pressure") or 0.0

    return {
        "temp": float(main.get("temp",     0.0)),
        "hum":  float(main.get("humidity", 0.0)),
        "mps":  float(wind.get("speed",    0.0)),
        "dir":  float(wind.get("deg",      0.0)),
        "prs":  float(prs),
        "wx":   wx_from_owm_id(owm_id),
        "tz":   int(data.get("timezone",   0)),
        "ts":   int(time.time()),
    }


def fetch_owm(session, lat, lon):
    """
    Fetch current weather for (lat, lon) from OWM.
    Returns a parsed record dict on success, or None to signal the caller
    to stop making requests this run (rate-limit or repeated failure).
    """
    params  = {"lat": lat, "lon": lon, "appid": OPEN_WEATHER_API_KEY, "units": "metric"}
    backoff = BACKOFF_START

    for attempt in range(1, MAX_TRIES + 1):
        try:
            r = session.get(OWM_URL, params=params, timeout=10)
        except requests.RequestException as exc:
            print(f"WARN: network error (attempt {attempt}/{MAX_TRIES}): {exc}",
                  file=sys.stderr)
            time.sleep(min(backoff, BACKOFF_CAP))
            backoff = min(backoff * 2, BACKOFF_CAP)
            continue

        if r.status_code == 200:
            try:
                return parse_owm(r.json())
            except Exception as exc:
                print(f"WARN: JSON parse error at ({lat},{lon}): {exc}",
                      file=sys.stderr)
                return None

        elif r.status_code == 401:
            sys.exit("ERROR: OWM API key rejected (401). Check OPEN_WEATHER_API_KEY.")

        elif r.status_code == 429:
            print("WARN: OWM rate limit (429) — stopping requests this run.",
                  file=sys.stderr)
            return None  # caller breaks the loop

        elif r.status_code in (500, 502, 503, 504):
            print(f"WARN: OWM HTTP {r.status_code} (attempt {attempt}/{MAX_TRIES})",
                  file=sys.stderr)
            time.sleep(min(backoff, BACKOFF_CAP))
            backoff = min(backoff * 2, BACKOFF_CAP)

        else:
            print(f"WARN: OWM HTTP {r.status_code} at ({lat},{lon}) "
                  f"(attempt {attempt}/{MAX_TRIES})", file=sys.stderr)
            time.sleep(min(backoff, BACKOFF_CAP))
            backoff = min(backoff * 2, BACKOFF_CAP)

    print(f"WARN: giving up on ({lat},{lon}) after {MAX_TRIES} attempts.",
          file=sys.stderr)
    return None

# ---------------------------------------------------------------------------
# wx.txt output
# ---------------------------------------------------------------------------
def fmt_line(lat, lon, r):
    """
    Format one data row to match the exact column layout of wx.txt:
      %7d %7d %7.1f %7.1f %7.1f %7.1f %7.1f %-16s%d
    The wx token is left-justified in a 16-char field with no separator
    before the TZ integer, which matches the reference file exactly.
    """
    return (
        f"{lat:7d} {lon:7d} "
        f"{r['temp']:7.1f} {r['hum']:7.1f} "
        f"{r['mps']:7.1f} {r['dir']:7.1f} "
        f"{r['prs']:7.1f} {r['wx']:<16s}"
        f"{r['tz']:d}\n"
    )


def write_wx_txt(out_path, cache):
    """
    Write the full wx.txt grid atomically.
    Iterates lon-major (outer LONS, inner LATS) with a blank line between
    lon groups — identical structure to the original Perl output.
    """
    os.makedirs(TMP_DIR, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=TMP_DIR, prefix="wx", suffix=".tmp")

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("#   lat     lng  temp,C     %hum    mps     dir    mmHg    Wx           TZ\n")
            for lon in LONS:
                for lat in LATS:
                    key = f"{lat},{lon}"
                    r   = cache.get(key, FALLBACK)
                    fh.write(fmt_line(lat, lon, r))
                fh.write("\n")  # blank line between lon groups
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        shutil.move(tmp_path, out_path)
        os.chmod(out_path, 0o644)
    except Exception as exc:
        print(f"ERROR: could not write {out_path}: {exc}", file=sys.stderr)
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    # Validate API key before doing anything else
    if not OPEN_WEATHER_API_KEY:
        sys.exit(
            "ERROR: OPEN_WEATHER_API_KEY is not set.\n"
            "Export it, put OPEN_WEATHER_API_KEY in /opt/hamclock-backend/.env, or prefix: OPEN_WEATHER_API_KEY=your_key python3 update_world_wx.py"
        )

    os.makedirs(TMP_DIR, exist_ok=True)

    # Load cities and build prioritised fetch queue
    cities = load_cities(CITIES_FILE)
    queue, city_slots = build_fetch_queue(cities)
    total  = len(queue)

    print(f"INFO: queue has {total} points "
          f"({city_slots} city grid points first, "
          f"{total - city_slots} remaining grid points).",
          file=sys.stderr)

    # Load persistent state
    cache = read_json(CACHE_JSON, {})
    state = read_json(STATE_JSON, {"idx": 0})

    idx = int(state.get("idx", 0)) % total   # safe wrap if queue changed size

    # HTTP session (connection pooling + shared headers)
    session = requests.Session()
    session.headers.update({"User-Agent": "hamclock-worldwx-py/1.0"})

    # Fetch loop
    fetched = 0
    for _ in range(REQS_PER_RUN):
        entry = queue[idx]
        lat, lon = entry["lat"], entry["lon"]           # grid key coords
        fetch_lat = entry.get("fetch_lat", lat)         # actual fetch coords
        fetch_lon = entry.get("fetch_lon", lon)
        label = entry["label"] or f"grid({lat},{lon})"

        # Show both if city coords differ significantly from grid coords
        if abs(fetch_lat - lat) > 0.01 or abs(fetch_lon - lon) > 0.01:
            print(f"INFO: fetching [{idx+1}/{total}] {label} @ ({fetch_lat:.2f},{fetch_lon:.2f}) → grid ({lat},{lon})", file=sys.stderr)
        else:
            print(f"INFO: fetching [{idx+1}/{total}] {label} ({lat},{lon})", file=sys.stderr)

        result = fetch_owm(session, fetch_lat, fetch_lon)
        if result is None:
            # Rate-limited or repeated failure — stop now but still write output
            break

        key = f"{lat},{lon}"
        cache[key] = result
        write_json_atomic(CACHE_JSON, cache)

        idx = (idx + 1) % total
        write_json_atomic(STATE_JSON, {"idx": idx})

        fetched += 1
        if fetched < REQS_PER_RUN:
            time.sleep(SLEEP_BETWEEN)

    print(f"INFO: fetched {fetched} point(s) this run. Writing wx.txt …", file=sys.stderr)

    # Always rewrite the full output file from cache
    write_wx_txt(OUT_TXT, cache)

    print(f"INFO: wx.txt written → {OUT_TXT}", file=sys.stderr)


if __name__ == "__main__":
    main()
