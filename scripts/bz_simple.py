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
#  bz_simple.py
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
#
#  Build Bz.txt from NOAA SWPC rtsw_mag_1m.json.
#
#  Upstream (new):
#    https://services.swpc.noaa.gov/json/rtsw/rtsw_mag_1m.json
#
#  Replaces (deprecated):
#    https://services.swpc.noaa.gov/products/solar-wind/mag-3-day.json
#
#  Output:
#    # UNIX        Bx     By     Bz     Bt
#    <epoch> <bx_gsm> <by_gsm> <bz_gsm> <bt>
#
#  Target path:
#    /opt/hamclock-backend/htdocs/ham/HamClock/Bz/Bz.txt
#
#  Data notes:
#    - The new feed is an array of objects (not header-row + data-rows).
#    - Each timestamp appears twice: once for DSCOVR and once for ACE.
#      Only the record with "active": true is the authoritative source.
#    - Field names: bx_gsm, by_gsm, bz_gsm, bt (bt is unchanged).
#    - Records arrive newest-first; we sort ascending before binning.
#    - If the feed covers less than 25h, leading bins are padded with
#      the oldest available sample so HamClock always gets BZBT_NV rows.
#
# ============================================================

import json
import time
import urllib.request
from datetime import datetime, timezone

URL = "https://services.swpc.noaa.gov/json/rtsw/rtsw_mag_1m.json"
OUT = "/opt/hamclock-backend/htdocs/ham/HamClock/Bz/Bz.txt"

BZBT_NV = 150          # 25 hours @ 10 minutes
STEP = 600             # seconds


def iso_to_epoch(s):
    s = s.strip().replace("T", " ")
    if s.endswith("Z"):
        s = s[:-1].strip()
    fmts = ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S")
    for fmt in fmts:
        try:
            return int(datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).timestamp())
        except ValueError:
            pass
    raise ValueError(f"Unrecognized time_tag format: {s!r}")


def fetch_json(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "OHB-bz/2.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", errors="replace"))


def parse_mag(records):
    if not isinstance(records, list) or len(records) == 0:
        raise ValueError("Unexpected JSON shape (expected non-empty array of objects)")

    first = records[0]
    if not isinstance(first, dict):
        raise ValueError(
            "Expected array of objects; got array of arrays. "
            "Wrong endpoint? (old mag-3-day format)"
        )
    for needed in ("time_tag", "active", "bx_gsm", "by_gsm", "bz_gsm", "bt"):
        if needed not in first:
            raise ValueError(f"Missing expected field {needed!r} in record: {list(first.keys())}")

    samples = []
    for rec in records:
        if not rec.get("active"):
            continue
        if any(rec[f] is None for f in ("bx_gsm", "by_gsm", "bz_gsm", "bt")):
            continue
        try:
            t = iso_to_epoch(str(rec["time_tag"]))
            bx = float(rec["bx_gsm"])
            by = float(rec["by_gsm"])
            bz = float(rec["bz_gsm"])
            bt = float(rec["bt"])
        except Exception:
            continue
        samples.append((t, bx, by, bz, bt))

    if not samples:
        raise ValueError("No valid active samples parsed from upstream JSON")

    # Sort ascending (feed arrives newest-first)
    samples.sort()
    return samples


def main():
    records = fetch_json(URL)
    samples = parse_mag(records)

    # Map by epoch for nearest-sample lookup
    samp = {t: (bx, by, bz, bt) for t, bx, by, bz, bt in samples}
    oldest = samples[0][0]

    now = int(time.time())
    t = (now // STEP) * STEP

    buffer = []
    while len(buffer) < BZBT_NV and t >= oldest:
        keys = [k for k in samp.keys() if k <= t]
        if keys:
            k = max(keys)
            bx, by, bz, bt = samp[k]
            buffer.append((t, bx, by, bz, bt))
        t -= STEP

    # If the feed doesn't reach back far enough, pad leading bins with the
    # oldest available sample so HamClock always gets exactly BZBT_NV rows.
    if len(buffer) < BZBT_NV:
        oldest_row = buffer[-1]  # buffer is still newest->oldest here
        pad_t = oldest_row[0] - STEP  # walk further back in time
        while len(buffer) < BZBT_NV:
            buffer.append((pad_t,) + oldest_row[1:])
            pad_t -= STEP

    # newest->oldest -> oldest->newest
    buffer.reverse()

    with open(OUT, "w") as f:
        f.write("# UNIX        Bx     By     Bz     Bt\n")
        for t, bx, by, bz, bt in buffer:
            f.write(f"{t:10d} {bx:8.2f} {by:8.2f} {bz:8.2f} {bt:8.2f}\n")


if __name__ == "__main__":
    main()
