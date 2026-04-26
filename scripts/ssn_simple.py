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
Build ssn-31.txt (YYYY MM DD SSN) using SWPC observed SSN JSON.
Keep the most recent 31 days.
"""

from __future__ import annotations

import sys
from pathlib import Path

import requests

SWPC_JSON_URL = "https://services.swpc.noaa.gov/json/solar-cycle/swpc_observed_ssn.json"
OUT = Path("/opt/hamclock-backend/htdocs/ham/HamClock/ssn/ssn-31.txt")
N_DAYS = 31


def main() -> int:
    try:
        r = requests.get(SWPC_JSON_URL, timeout=20)
        r.raise_for_status()
        data = r.json()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if not isinstance(data, list):
        print("ERROR: unexpected JSON format", file=sys.stderr)
        return 2

    rows = []
    for obj in data:
        if not isinstance(obj, dict):
            continue
        obsdate = obj.get("Obsdate", "")
        v = obj.get("swpc_ssn")
        if not obsdate or v is None:
            continue
        try:
            date_str = obsdate[:10]  # YYYY-MM-DD
            y, m, d = date_str.split("-")
            ssn = int(v)
            rows.append((int(y), int(m), int(d), ssn))
        except Exception:
            continue

    if not rows:
        print("ERROR: no usable data in SWPC JSON", file=sys.stderr)
        return 2

    rows.sort()
    rows = rows[-N_DAYS:]

    if len(rows) < N_DAYS:
        print(
            f"WARNING: only {len(rows)} days available (need {N_DAYS}).",
            file=sys.stderr,
        )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as f:
        for y, m, d, ssn in rows:
            f.write(f"{y:04d} {m:02d} {d:02d} {ssn}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
