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
update_world_wx.py — Fetch world weather via Open-Meteo and write wx.txt
for HamClock in the exact format produced by the original update_world_wx.pl.

Uses batched multi-coordinate requests with gentle rotation to keep
world map weather data fresh without exhausting API rate limits.

Output grid: lat -90..90 step 4, lon -180..180 step 5 (46×73 = 3,358 points).
Fetch order: cities from cities.txt (snapped to grid) first, then remaining
grid points — so named cities always have the freshest data.

Environment variables:
    OPEN_METEO_API_KEY         Optional. Commercial Open-Meteo API key.
    OPEN_METEO_BATCH_SIZE      Points per batch HTTP request. Default: 50
    OPEN_METEO_BATCHES_PER_RUN Batches per cron invocation. Default: 4 (200 pts/run, ~20 min full refresh)
    OPEN_METEO_SLEEP           Seconds to sleep between batch requests. Default: 1.0
    WORLDWX_OUT                Output wx.txt path.
                               Default: /opt/hamclock-backend/htdocs/ham/HamClock/worldwx/wx.txt
    WORLDWX_TMP                Directory for cache/state files.
                               Default: /opt/hamclock-backend/tmp/worldwx
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
OPEN_METEO_API_KEY = os.environ.get("OPEN_METEO_API_KEY", "")

# If API key not in env, check optional .env file
if not OPEN_METEO_API_KEY and os.path.exists("/opt/hamclock-backend/.env"):
    with open("/opt/hamclock-backend/.env", "r") as f:
        for line in f:
            if line.startswith("OPEN_METEO_API_KEY="):
                OPEN_METEO_API_KEY = line.strip().split("=", 1)[1].strip("'\"")
                break

OUT_TXT = os.environ.get(
    "WORLDWX_OUT",
    "/opt/hamclock-backend/htdocs/ham/HamClock/worldwx/wx.txt",
)
TMP_DIR = os.environ.get(
    "WORLDWX_TMP",
    "/opt/hamclock-backend/tmp/worldwx",
)

CITIES_FILE = os.environ.get("CITIES_FILE", "")
if not CITIES_FILE or not os.path.exists(CITIES_FILE):
    for candidate in (
        "/opt/hamclock-backend/htdocs/ham/HamClock/cities2.txt",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "../ham/HamClock/cities2.txt"),
    ):
        if os.path.exists(candidate):
            CITIES_FILE = candidate
            break

CACHE_JSON = os.path.join(TMP_DIR, "cache.json")
STATE_JSON = os.path.join(TMP_DIR, "state.json")

BATCH_SIZE      = int(os.environ.get("OPEN_METEO_BATCH_SIZE", "50"))
BATCHES_PER_RUN = int(os.environ.get("OPEN_METEO_BATCHES_PER_RUN", os.environ.get("OWM_REQS_PER_RUN", "4")))
SLEEP_BETWEEN   = float(os.environ.get("OPEN_METEO_SLEEP", os.environ.get("OWM_SLEEP", "1.0")))
MAX_TRIES       = int(os.environ.get("OPEN_METEO_RETRIES", "3"))
BACKOFF_START   = float(os.environ.get("OPEN_METEO_BACKOFF_START", "2.0"))
BACKOFF_CAP     = float(os.environ.get("OPEN_METEO_BACKOFF_CAP", "30.0"))

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

# Open-Meteo forecast API endpoint
OPEN_METEO_URL = "https://api.open-metEO.com/v1/forecast".lower()

# ---------------------------------------------------------------------------
# WMO weather code → HamClock wx token
# ---------------------------------------------------------------------------
def wx_from_wmo_code(code):
    if code is None:
        return "Unknown"
    if code == 0:
        return "Clear"
    if 1 <= code <= 3:
        return "Clouds"
    if code in (45, 48):
        return "Fog"
    if (51 <= code <= 67) or (80 <= code <= 82):
        return "Rain"
    if (71 <= code <= 77) or (85 <= code <= 86):
        return "Snow"
    if 95 <= code <= 99:
        return "Thunderstorm"
    return "Clouds"

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
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix="cache", suffix=".tmp")
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
    if not path or not os.path.isfile(path):
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
    for city in cities:
        gp = snap_to_grid(city["lat"], city["lon"])
        if gp not in seen:
            seen.add(gp)
            queue.append({
                "lat": gp[0],
                "lon": gp[1],
                "label": city["label"],
                "fetch_lat": city["lat"],
                "fetch_lon": city["lon"]
            })

    city_slots = len(queue)

    # Stage 2: remaining grid points (lon-major to match wx.txt write order).
    # Skip pure-ocean points that have no city — no useful weather display there.
    skipped = 0
    for lon in LONS:
        for lat in LATS:
            if (lat, lon) not in seen:
                if _HAS_LAND_MASK and not _globe.is_land(lat, lon):
                    skipped += 1
                    continue  # pure ocean, no city — skip
                seen.add((lat, lon))
                queue.append({
                    "lat": lat,
                    "lon": lon,
                    "label": None,
                    "fetch_lat": lat,
                    "fetch_lon": lon
                })

    if skipped:
        print(f"INFO: skipped {skipped} pure-ocean grid points (no city nearby).",
              file=sys.stderr)

    return queue, city_slots

# ---------------------------------------------------------------------------
# Open-Meteo batch fetch with retry / exponential backoff
# ---------------------------------------------------------------------------
def parse_open_meteo_point(point_data):
    """Extract weather fields from an Open-Meteo forecast JSON item."""
    c = point_data.get("current", {})
    prs = c.get("surface_pressure") or 0.0

    return {
        "temp": float(c.get("temperature_2m",       0.0)),
        "hum":  float(c.get("relative_humidity_2m",  0.0)),
        "mps":  float(c.get("wind_speed_10m",        0.0)),
        "dir":  float(c.get("wind_direction_10m",    0.0)),
        "prs":  float(prs),
        "wx":   wx_from_wmo_code(c.get("weather_code")),
        "tz":   int(point_data.get("utc_offset_seconds", 0)),
        "ts":   int(time.time()),
    }


def fetch_open_meteo_batch(session, batch_entries):
    """
    Fetch current weather for a batch of entries from Open-Meteo.
    Returns a list of parsed record dicts, or None to signal caller to stop.
    """
    lat_q = ",".join(f"{e.get('fetch_lat', e['lat']):.4f}" for e in batch_entries)
    lon_q = ",".join(f"{e.get('fetch_lon', e['lon']):.4f}" for e in batch_entries)

    params = {
        "latitude": lat_q,
        "longitude": lon_q,
        "current": (
            "temperature_2m,"
            "relative_humidity_2m,"
            "wind_speed_10m,"
            "wind_direction_10m,"
            "surface_pressure,"
            "weather_code"
        ),
        "wind_speed_unit": "ms",
    }
    if OPEN_METEO_API_KEY:
        params["apikey"] = OPEN_METEO_API_KEY

    backoff = BACKOFF_START

    for attempt in range(1, MAX_TRIES + 1):
        try:
            r = session.get(OPEN_METEO_URL, params=params, timeout=15)
        except requests.RequestException as exc:
            print(f"WARN: network error (attempt {attempt}/{MAX_TRIES}): {exc}",
                  file=sys.stderr)
            time.sleep(min(backoff, BACKOFF_CAP))
            backoff = min(backoff * 2, BACKOFF_CAP)
            continue

        if r.status_code == 200:
            try:
                data = r.json()
                if isinstance(data, dict):
                    data = [data]
                results = []
                for item in data[:len(batch_entries)]:
                    results.append(parse_open_meteo_point(item))
                return results
            except Exception as exc:
                print(f"WARN: JSON parse error: {exc}", file=sys.stderr)
                return None

        elif r.status_code == 429:
            print("WARN: Open-Meteo rate limit (429) — stopping requests this run.",
                  file=sys.stderr)
            return None

        elif r.status_code in (500, 502, 503, 504):
            print(f"WARN: Open-Meteo HTTP {r.status_code} (attempt {attempt}/{MAX_TRIES})",
                  file=sys.stderr)
            time.sleep(min(backoff, BACKOFF_CAP))
            backoff = min(backoff * 2, BACKOFF_CAP)

        else:
            print(f"WARN: Open-Meteo HTTP {r.status_code} (attempt {attempt}/{MAX_TRIES})",
                  file=sys.stderr)
            time.sleep(min(backoff, BACKOFF_CAP))
            backoff = min(backoff * 2, BACKOFF_CAP)

    print(f"WARN: giving up on batch after {MAX_TRIES} attempts.",
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
    os.makedirs(TMP_DIR, exist_ok=True)

    # Load cities and build prioritised fetch queue
    cities = load_cities(CITIES_FILE)
    queue, city_slots = build_fetch_queue(cities)
    total = len(queue)

    if total == 0:
        sys.exit("ERROR: fetch queue is empty.")

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
    session.headers.update({"User-Agent": "hamclock-worldwx-openmeteo/1.0"})

    # Fetch loop with gentle rotation across batches
    total_fetched = 0
    for batch_num in range(BATCHES_PER_RUN):
        batch_entries = []
        for i in range(BATCH_SIZE):
            entry_idx = (idx + i) % total
            batch_entries.append(queue[entry_idx])

        print(f"INFO: fetching batch [{batch_num + 1}/{BATCHES_PER_RUN}] "
              f"({len(batch_entries)} points, starting at queue index {idx + 1}/{total})",
              file=sys.stderr)

        results = fetch_open_meteo_batch(session, batch_entries)
        if results is None or not results:
            break

        for entry, record in zip(batch_entries, results):
            key = f"{entry['lat']},{entry['lon']}"
            cache[key] = record

        write_json_atomic(CACHE_JSON, cache)

        idx = (idx + len(results)) % total
        write_json_atomic(STATE_JSON, {"idx": idx})

        total_fetched += len(results)

        if batch_num + 1 < BATCHES_PER_RUN:
            time.sleep(SLEEP_BETWEEN)

    print(f"INFO: fetched {total_fetched} point(s) this run. Writing wx.txt …", file=sys.stderr)

    # Always rewrite the full output file from cache
    write_wx_txt(OUT_TXT, cache)

    print(f"INFO: wx.txt written → {OUT_TXT}", file=sys.stderr)


if __name__ == "__main__":
    main()
