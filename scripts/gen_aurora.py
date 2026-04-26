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
#  gen_aurora.py
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

import json
import logging
import os
import sys
import tempfile
import time
from pathlib import Path
from urllib.request import Request, urlopen

URL = "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json"
OUT = Path("/opt/hamclock-backend/htdocs/ham/HamClock/aurora/aurora.txt")

RESEED_GAP = 12 * 3600
RESEED_POINTS = 48
RESEED_STEP = 1800
WINDOW_SECONDS = 24 * 3600

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("gen_aurora")


def load_max_value() -> int:
    log.info("Fetching NOAA OVATION JSON: %s", URL)
    req = Request(URL, headers={"User-Agent": "open-hamclock-backend/aurora"})
    with urlopen(req, timeout=30) as resp:
        payload = json.load(resp)

    coords = payload.get("coordinates")
    if not isinstance(coords, list) or not coords:
        raise ValueError("missing or empty coordinates array")

    vals = []
    for row in coords:
        if not isinstance(row, list) or len(row) < 3:
            continue
        try:
            vals.append(int(row[2]))
        except (TypeError, ValueError):
            continue

    if not vals:
        raise ValueError("no valid aurora values found")

    value = max(vals)
    log.info("NOAA OVATION max aurora=%d", value)
    return value


def atomic_write_lines(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=str(path.parent),
        delete=False,
    ) as tmp:
        tmp.writelines(lines)
        tmp_name = tmp.name
    os.replace(tmp_name, path)


def reseed(bucket_ts: int, value: int) -> None:
    start = bucket_ts - (RESEED_POINTS - 1) * RESEED_STEP
    lines = [f"{start + i * RESEED_STEP} {value}\n" for i in range(RESEED_POINTS)]
    atomic_write_lines(OUT, lines)
    log.info("Reseeded %d rows to %s", RESEED_POINTS, OUT)


def read_existing() -> list[tuple[int, int]]:
    rows = []
    if not OUT.exists():
        return rows

    with OUT.open("r", encoding="utf-8") as f:
        for raw in f:
            parts = raw.strip().split()
            if len(parts) != 2:
                continue
            try:
                rows.append((int(parts[0]), int(parts[1])))
            except ValueError:
                continue
    return rows


def write_rows(rows: list[tuple[int, int]]) -> None:
    atomic_write_lines(OUT, [f"{ts} {val}\n" for ts, val in rows])
    log.info("Wrote %d rows to %s", len(rows), OUT)


def main() -> int:
    try:
        value = load_max_value()
    except Exception as e:
        log.error("Aurora fetch/parse failed: %s", e)
        return 1

    now_ts = int(time.time())
    bucket_ts = (now_ts // 1800) * 1800

    if not OUT.exists():
        log.info("aurora.txt missing; reseeding")
        reseed(bucket_ts, value)
        return 0

    rows = read_existing()
    if not rows:
        log.info("aurora.txt empty; reseeding")
        reseed(bucket_ts, value)
        return 0

    last_ts, last_val = rows[-1]
    delta = now_ts - last_ts

    if delta <= 0 or delta > RESEED_GAP:
        log.info("History stale; reseeding")
        reseed(bucket_ts, value)
        return 0

    if last_ts == bucket_ts:
        if last_val == value:
            OUT.touch()
            log.info("Touched %s (same bucket, same value)", OUT)
            return 0
        rows[-1] = (bucket_ts, value)
        log.info("Updated current bucket: %d -> %d", last_val, value)
    else:
        rows.append((bucket_ts, value))
        log.info("Appended bucket %d value %d", bucket_ts, value)

    cutoff = now_ts - WINDOW_SECONDS
    before = len(rows)
    rows = [(ts, val) for ts, val in rows if ts >= cutoff]
    if len(rows) != before:
        log.info("Pruned %d old rows", before - len(rows))

    write_rows(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
