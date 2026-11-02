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

import os
import time
import pandas as pd
import requests
from pathlib import Path

URL = "https://services.swpc.noaa.gov/json/goes/primary/xrays-3-day.json"
OUT = Path("/opt/hamclock-backend/htdocs/ham/HamClock/xray/xray.txt")

# Upstream-health sidecar read by generate_status_json.sh.  Kept outside the xray/
# data dir so it is not listed as a data product itself.
META = Path(os.environ.get("XRAY_META", "/opt/hamclock-backend/cache/xray-upstream.meta"))

# SWPC keeps publishing new time_tags during a GOES outage but zero-fills the flux,
# so "fresh timestamp" is not enough: judge by the newest sample with real (>0) flux.
UPSTREAM_MAX_AGE_SEC = 30 * 60

def write_upstream_meta(last_good, satellite=None) -> None:
    """Record whether SWPC is delivering real data. Never raises: status reporting
    must not break the data product."""
    now = pd.Timestamp.now(tz="UTC")
    ok = last_good is not None and (now - last_good).total_seconds() <= UPSTREAM_MAX_AGE_SEC
    lines = [
        f"upstream_ok={1 if ok else 0}",
        f"checked_epoch={int(now.timestamp())}",
    ]
    if last_good is not None:
        lines.append(f"last_good_epoch={int(last_good.timestamp())}")
    if satellite is not None:
        lines.append(f"satellite={satellite}")
    try:
        META.parent.mkdir(parents=True, exist_ok=True)
        tmp = META.with_suffix(".tmp")
        tmp.write_text("\n".join(lines) + "\n")
        tmp.replace(META)
    except OSError as e:
        print(f"warning: could not write {META}: {e}")

# CSI appears to lag the very newest bins; keep a safety margin so we don't
# emit bins they haven't emitted yet. Tune if needed.
CSI_LAG_MINUTES = 21

def main() -> None:
    # Retry up to 3 times with backoff in case of transient SWPC issues
    for attempt in range(3):
        headers = {'User-Agent': 'OHB-XRay-Fetcher/1.0'}
        r = requests.get(URL, headers=headers, timeout=(10, 60))
        r.raise_for_status()

        content_type = r.headers.get('Content-Type', '')
        if 'json' not in content_type:
            raise RuntimeError(
                f"Expected JSON from SWPC but got Content-Type: {content_type!r}\n"
                f"Response start: {r.text[:500]!r}"
            )

        try:
            data = r.json()
            break  # success
        except requests.exceptions.JSONDecodeError as e:
            snippet_start = r.text[:500]
            snippet_end = r.text[-500:]
            if attempt < 2:
                print(f"Attempt {attempt + 1}: JSON parse failed at pos {e.pos}, retrying in 5s...")
                time.sleep(5)
                continue
            raise RuntimeError(
                f"SWPC returned invalid JSON after 3 attempts (pos {e.pos})\n"
                f"START: {snippet_start!r}\n"
                f"END:   {snippet_end!r}"
            ) from e

    df = pd.DataFrame(data)
    required = {"time_tag", "energy", "flux"}
    if not required.issubset(df.columns):
        raise RuntimeError("Unexpected SWPC JSON schema (missing required keys)")

    # Parse timestamps as UTC
    df["time_tag"] = pd.to_datetime(df["time_tag"], utc=True)

    # Keep only the two GOES X-ray bands used by HamClock/CSI
    df = df[df["energy"].isin(["0.05-0.4nm", "0.1-0.8nm"])]

    # Which GOES satellite SWPC is currently serving as "primary" (for the status page)
    satellite = None
    if "satellite" in df.columns and not df.empty:
        try:
            satellite = int(df.loc[df["time_tag"].idxmax(), "satellite"])
        except (TypeError, ValueError):
            satellite = None

    # One row per timestamp with both flux columns
    df = df.pivot(index="time_tag", columns="energy", values="flux").dropna()
    df = df.rename(columns={"0.05-0.4nm": "short", "0.1-0.8nm": "long"}).sort_index()

    # Upstream health (report only; the data below is intentionally left untouched)
    good = df[(df["short"] > 0) & (df["long"] > 0)]
    write_upstream_meta(good.index.max() if not good.empty else None, satellite)

    # --- CSI-like 10-minute binning (fixed bins, UTC aligned) ---
    # Floor to 10-minute boundaries
    binned = df.copy()
    binned["bin"] = binned.index.floor("10min")

    # CSI values look like per-bin MAX, not mean (MAX >= MEAN; your values were low)
    binned = binned.groupby("bin", sort=True)[["short", "long"]].max()

    # Stamp the bin at end-of-bin minute 9 (e.g., 12:50 bin -> 12:59)
    binned.index = binned.index + pd.Timedelta(minutes=9)

    # Drop newest bins with a safety lag so output ends where CSI tends to end
    now = pd.Timestamp.now(tz="UTC")
    last_allowed = now - pd.Timedelta(minutes=CSI_LAG_MINUTES)
    # Ensure last_allowed is an end-of-bin time (:..:x9)
    last_allowed = last_allowed.floor("10min") + pd.Timedelta(minutes=9)
    binned = binned[binned.index <= last_allowed]

    # Keep ~30 hours of history after binning
    #if not binned.empty:
    #   binned = binned[binned.index >= binned.index.max() - pd.Timedelta(hours=30)]

    # Keep last 150 samples only (CSI behavior)
    if len(binned) > 150:
       binned = binned.iloc[-150:]

    # Write output (CSI fixed columns)
    OUT.parent.mkdir(parents=True, exist_ok=True)

    with open(OUT, "w") as f:
        for t, row in binned.iterrows():
            # Column starts (1-based) matching CSI:
            # year 1, month 7, day 9, hhmm 13, zero1 20, zero2 27, short 37, long 49
            hhmm = t.strftime("%H%M")
            f.write(
                f"{t.year:4d}  {t.month:1d} {t.day:2d}  {hhmm:>4}   "
                f"00000  00000     "
                f"{row.short:8.2e}    {row.long:8.2e}\n"
            )

if __name__ == "__main__":
    main()
