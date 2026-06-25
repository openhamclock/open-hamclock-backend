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
#  fetch_noaaswx.py
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
# fetch_noaaswx.py  --  OHB backend cron script for HamClock "Space Weather" pane.
#
# Queries the NOAA Space Weather Prediction Center for current and forecast
# R/S/G scale values and writes a formatted text file for HamClock to consume.
#
# OUTPUT FILE:
#   <OUTDIR>/noaaswx.txt  (served at <OHB>/ham/HamClock/NOAASpaceWX/noaaswx.txt)
#
# CRON (every 5 minutes):
#   */5 * * * * /opt/hamclock-backend/scripts/fetch_noaaswx.py
#
# FILE FORMAT (3 lines, consumed by noaaswx.cpp):
#   R  <now> <+24h> <+48h> <+72h>
#   S  <now> <+24h> <+48h> <+72h>
#   G  <now> <+24h> <+48h> <+72h>
#
# SCALE INDICES (from NOAA JSON):
#   "0"  = current observed
#   "1"  = 24-hour forecast
#   "2"  = 48-hour forecast
#   "3"  = 72-hour forecast
#   Null Scale values fall back to "0"

import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

URL     = "https://services.swpc.noaa.gov/products/noaa-scales.json"
OUTDIR  = "/opt/hamclock-backend/htdocs/ham/HamClock/NOAASpaceWX"
OUTFILE = os.path.join(OUTDIR, "noaaswx.txt")
TMPDIR  = "/opt/hamclock-backend/htdocs/tmp"
TMPFILE = os.path.join(TMPDIR, "noaaswx.tmp")
TIMEOUT = 15     # HTTP request timeout, seconds

INDICES = ["0", "1", "2", "3"]
SCALES  = ["R", "S", "G"]


def fetch_data() -> dict:
    """Fetch NOAA scales JSON with exponential-backoff retry."""
    req = urllib.request.Request(URL, headers={"User-Agent": "HamClock/fetch_noaaswx.py"})

    max_attempts = 4
    last_exc = None

    for attempt in range(1, max_attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            if not isinstance(data, dict):
                print(f"fetch_noaaswx: unexpected JSON type: {type(data).__name__}", file=sys.stderr)
                sys.exit(1)
            return data

        except json.JSONDecodeError as e:
            # Bad JSON won't be fixed by retrying
            print(f"fetch_noaaswx: JSON decode error: {e}", file=sys.stderr)
            sys.exit(1)

        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < max_attempts:
                delay = 5 * (2 ** (attempt - 1))   # 5s, 10s, 20s
                print(f"fetch_noaaswx: HTTP {e.code} on attempt {attempt}/{max_attempts} — retrying in {delay}s", file=sys.stderr)
                time.sleep(delay)
                last_exc = e
                continue
            print(f"fetch_noaaswx: HTTP error {e.code}: {e.reason}", file=sys.stderr)
            sys.exit(1)

        except (urllib.error.URLError, ConnectionError, TimeoutError, http.client.HTTPException) as e:
            if attempt < max_attempts:
                delay = 5 * (2 ** (attempt - 1))   # 5s, 10s, 20s
                print(f"fetch_noaaswx: network error on attempt {attempt}/{max_attempts}: {e} — retrying in {delay}s", file=sys.stderr)
                time.sleep(delay)
                last_exc = e
                continue
            print(f"fetch_noaaswx: network error after {max_attempts} attempts: {e}", file=sys.stderr)
            sys.exit(1)

    print(f"fetch_noaaswx: all {max_attempts} attempts failed. Last error: {last_exc}", file=sys.stderr)
    sys.exit(1)


def build_lines(data: dict) -> list[str]:
    """
    Build the 3-line output for HamClock.
    Null or missing Scale values fall back to "0".
    """
    lines = []
    for scale in SCALES:
        values = []
        for idx in INDICES:
            entry = (data.get(idx) or {}).get(scale) or {}
            raw   = entry.get("Scale")
            values.append(str(raw) if raw is not None else "0")
        lines.append(f"{scale}  " + " ".join(values))
    return lines


def main() -> None:
    data  = fetch_data()
    lines = build_lines(data)

    # Atomic write: write to TMPFILE, rename into place
    os.makedirs(OUTDIR, exist_ok=True)
    os.makedirs(TMPDIR, exist_ok=True)
    with open(TMPFILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(TMPFILE, OUTFILE)

    ts_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%MZ")
    print(f"fetch_noaaswx: wrote {OUTFILE} at {ts_str}")
    for line in lines:
        print(f"  {line}")


if __name__ == "__main__":
    main()
