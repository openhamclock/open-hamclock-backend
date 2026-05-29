#!/usr/bin/env python3
# kindex_simple.py
#
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
#
# Build HamClock geomag/kindex.txt (72 lines) from a single SWPC JSON feed:
#   https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json
#
# The feed contains observed, estimated, and predicted 3-hourly Kp bins.
# - Positions  1-56: last 56 observed entries ("now" at position 56)
# - Positions 57-72: first 16 estimated/predicted entries
#
# Output path is atomically written:
# /opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time

import requests

KP_URL  = "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json"
OUTFILE = "/opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt"
TMP_DIR = "/opt/hamclock-backend/tmp"

TIMEOUT = 20
HEADERS = {"User-Agent": "OHB kindex_simple.py"}


def fetch_kp() -> list[dict]:
    for attempt in range(3):
        try:
            r = requests.get(KP_URL, headers=HEADERS, timeout=TIMEOUT)
            r.raise_for_status()
            rows = r.json()

            # SWPC has served two formats over time:
            #   array-of-arrays: [["time_tag","kp",...], ["2026-...", 3.0, ...], ...]
            #   array-of-objects: [{"time_tag":"2026-...","kp":3.0,...}, ...]
            if isinstance(rows[0], dict):
                # Already array-of-objects — use directly
                return rows
            else:
                # Array-of-arrays — first row is the header
                keys = rows[0]
                return [dict(zip(keys, row)) for row in rows[1:]]

        except Exception as e:
            if attempt == 2:
                raise
            print(
                f"WARNING: fetch attempt {attempt + 1}/3 failed: {e} -- retrying in 30s",
                file=sys.stderr,
            )
            time.sleep(30)


def build_output(records: list[dict]) -> list[float]:
    observed = [float(r["kp"]) for r in records if r["observed"] == "observed"]
    forecast = [float(r["kp"]) for r in records if r["observed"] in ("estimated", "predicted")]

    if len(observed) < 56:
        raise RuntimeError(f"Need at least 56 observed Kp bins, got {len(observed)}")
    if len(forecast) < 16:
        raise RuntimeError(f"Need at least 16 forecast Kp bins, got {len(forecast)}")

    return observed[-56:] + forecast[:16]


def atomic_write_lines(path: str, values: list[float]) -> None:
    os.makedirs(TMP_DIR, exist_ok=True)
    payload = "".join(f"{v:.2f}\n" for v in values)

    fd, tmp = tempfile.mkstemp(
        prefix=".kindex.",
        suffix=".tmp",
        dir=TMP_DIR,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.makedirs(os.path.dirname(path), exist_ok=True)
        shutil.move(tmp, path)
        os.chmod(path, 0o644)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main() -> int:
    try:
        records = fetch_kp()
        out = build_output(records)

        if len(out) != 72:
            raise RuntimeError(f"Expected 72 output values, got {len(out)}")

        atomic_write_lines(OUTFILE, out)
        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
