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
#  swind_simple.py
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
Build swind-24hr.txt (epoch density speed) from NOAA SWPC rtsw_wind_1m.json.

Upstream (new):
  https://services.swpc.noaa.gov/json/rtsw/rtsw_wind_1m.json

Output (one row per sample):
  <unix_epoch> <density> <speed>

Target path:
  /opt/hamclock-backend/htdocs/ham/HamClock/solar-wind/swind-24hr.txt

Data notes:
  - The new feed is an array of objects (not a header-row + data-rows list).
  - Each timestamp appears twice: once for DSCOVR and once for ACE.
    Only the record with "active": true is the authoritative source.
  - Field names changed: density -> proton_density, speed -> proton_speed.
  - Records arrive newest-first; we sort ascending before windowing.
  - Some active records have null density/speed; these are skipped.

Windowing policy (unchanged from v1):
  - Filter to active records only, skip nulls, sort + de-dup by epoch
  - Optional lag (disabled by default)
  - Keep the last 1440 samples (24h @ ~1-min cadence)
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from typing import List, Tuple

URL = "https://services.swpc.noaa.gov/json/rtsw/rtsw_wind_1m.json"
OUT = "/opt/hamclock-backend/htdocs/ham/HamClock/solar-wind/swind-24hr.txt"

# 24h at ~1-minute cadence
KEEP_N = 1440

# Set to 0 to end at newest available sample (recommended).
# If you need to match a CSI lag, set e.g. 60*60 or 90*60.
LAG_SECONDS = 0


def iso_to_epoch(s: str) -> int:
    """Parse an ISO-8601 time_tag string to a UTC Unix epoch integer."""
    s = s.strip().replace("T", " ")
    if s.endswith("Z"):
        s = s[:-1].strip()

    fmts = ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S")
    for fmt in fmts:
        try:
            dt = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
        except ValueError:
            pass
    raise ValueError(f"Unrecognized time_tag format: {s!r}")


def fetch_json(url: str, timeout: int = 20):
    req = urllib.request.Request(url, headers={"User-Agent": "OHB-swind/2.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", errors="replace"))


def parse_wind(records) -> List[Tuple[int, float, float]]:
    """
    Parse rtsw_wind_1m records into (epoch, density, speed) tuples.

    Filters to active records only and skips any with null proton_density
    or proton_speed values.
    """
    if not isinstance(records, list) or len(records) == 0:
        raise ValueError("Unexpected JSON shape (expected non-empty array of objects)")

    # Validate that this looks like the right feed
    first = records[0]
    if not isinstance(first, dict):
        raise ValueError(
            "Expected array of objects; got array of arrays. "
            "Wrong endpoint? (old plasma-1-day format)"
        )
    for needed in ("time_tag", "active", "proton_density", "proton_speed"):
        if needed not in first:
            raise ValueError(f"Missing expected field {needed!r} in record: {list(first.keys())}")

    out: List[Tuple[int, float, float]] = []

    for rec in records:
        # Only use the authoritative source for each timestamp
        if not rec.get("active"):
            continue

        # Skip records with missing plasma data
        if rec["proton_density"] is None or rec["proton_speed"] is None:
            continue

        try:
            t = iso_to_epoch(str(rec["time_tag"]))
            dens = float(rec["proton_density"])
            spd = float(rec["proton_speed"])
        except Exception:
            continue

        # Sanity bounds (same as v1)
        if t <= 0:
            continue
        if not (0.0 <= dens <= 500.0):
            continue
        if not (0.0 <= spd <= 5000.0):
            continue

        out.append((t, dens, spd))

    if not out:
        raise ValueError("No valid active samples parsed from upstream JSON")

    # Sort ascending by epoch (feed arrives newest-first)
    out.sort(key=lambda x: x[0])

    # De-dup: keep only strictly increasing timestamps
    dedup: List[Tuple[int, float, float]] = []
    last_t = None
    for t, d, v in out:
        if last_t is None or t > last_t:
            dedup.append((t, d, v))
            last_t = t

    return dedup


def apply_window(samples: List[Tuple[int, float, float]]) -> List[Tuple[int, float, float]]:
    s = samples[:]
    if not s:
        return s

    if LAG_SECONDS and LAG_SECONDS > 0:
        newest = s[-1][0]
        lag_cutoff = newest - LAG_SECONDS
        s = [row for row in s if row[0] <= lag_cutoff]

    if len(s) > KEEP_N:
        s = s[-KEEP_N:]

    return s


def atomic_write(path: str, lines: List[str]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".swind-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main() -> int:
    try:
        records = fetch_json(URL)
        samples = parse_wind(records)
        samples = apply_window(samples)

        if not samples:
            raise ValueError("No samples left after windowing; check LAG_SECONDS or upstream feed")

        lines = [f"{t} {dens:.2f} {spd:.1f}\n" for (t, dens, spd) in samples]
        atomic_write(OUT, lines)
        return 0

    except Exception as e:
        print(f"swind build failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
