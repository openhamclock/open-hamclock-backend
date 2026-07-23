#!/usr/bin/env python3
# fetch_proton.py
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
# Build HamClock proton/protons.txt (150 lines) from a single SWPC JSON feed:
#   https://services.swpc.noaa.gov/json/goes/primary/integral-protons-3-day.json
#
# This is the >=10 MeV GOES integral proton flux (particle flux units, pfu) --
# the same quantity NOAA's S-scale (solar radiation storm) is based on. The feed
# carries several energy thresholds (>=1, >=5, >=10, >=30, ... MeV); we keep only
# the >=10 MeV channel.
#
# Output format matches xray_simple.py's timing convention: 150 lines, oldest
# first, one 10-minute bin per line covering the trailing 25 hours -- but unlike
# xray.txt's fixed-width CSI columns, HamClock's proton reader just wants a
# single plain pfu value per line (see HamClock's retrieveProtonFlux()).
#
# Output path is atomically written:
# /opt/hamclock-backend/htdocs/ham/HamClock/proton/protons.txt

from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

import pandas as pd
import requests

URL     = "https://services.swpc.noaa.gov/json/goes/primary/integral-protons-3-day.json"
OUTFILE = Path("/opt/hamclock-backend/htdocs/ham/HamClock/proton/protons.txt")
TMP_DIR = Path("/opt/hamclock-backend/tmp")

TIMEOUT = (10, 60)
HEADERS = {"User-Agent": "OHB fetch_proton.py"}

N_SAMPLES = 150          # must match HamClock's PROTON_NV (== XRAY_NV)
BIN_MINUTES = 10         # must match xray.txt's cadence (6 bins/hour)

# SWPC appears to lag emitting its very newest bins; keep a small safety
# margin so we don't try to emit a bin they haven't published yet. Same
# idea as xray_simple.py's CSI_LAG_MINUTES.
SWPC_LAG_MINUTES = 15

# energy threshold we want, in MeV -- matched numerically so eg "10 MeV"
# doesn't accidentally match on "100 MeV"
TARGET_MEV = 10


def fetch_records() -> list[dict]:
    last_err: Exception | None = None
    for attempt in range(3):
        try:
            r = requests.get(URL, headers=HEADERS, timeout=TIMEOUT)
            r.raise_for_status()

            content_type = r.headers.get("Content-Type", "")
            if "json" not in content_type:
                raise RuntimeError(
                    f"Expected JSON from SWPC but got Content-Type: {content_type!r}\n"
                    f"Response start: {r.text[:500]!r}"
                )

            return r.json()

        except Exception as e:
            last_err = e
            if attempt < 2:
                print(
                    f"WARNING: fetch attempt {attempt + 1}/3 failed: {e} -- retrying in 15s",
                    file=sys.stderr,
                )
                time.sleep(15)

    raise RuntimeError(f"SWPC fetch failed after 3 attempts: {last_err}") from last_err


def energy_mev(energy_str: str) -> float | None:
    """pull the leading number out of an energy label like '10 MeV' or '>=10 MeV'."""
    m = re.search(r"[\d.]+", str(energy_str))
    return float(m.group()) if m else None


def build_series(records: list[dict]) -> pd.Series:
    df = pd.DataFrame(records)
    required = {"time_tag", "energy", "flux"}
    if not required.issubset(df.columns):
        raise RuntimeError("Unexpected SWPC JSON schema (missing required keys)")

    df["energy_mev"] = df["energy"].map(energy_mev)
    df = df[df["energy_mev"] == TARGET_MEV]
    if df.empty:
        raise RuntimeError(f"No >= {TARGET_MEV} MeV rows found in SWPC response")

    df["time_tag"] = pd.to_datetime(df["time_tag"], utc=True)
    df = df.dropna(subset=["flux"]).sort_values("time_tag")

    # some negative/sentinel "no data" values show up occasionally -- drop them
    # rather than let a bogus reading distort the file (real pfu is >= 0)
    df = df[df["flux"] >= 0]

    # --- 10-minute binning (fixed bins, UTC aligned), same approach as xray_simple.py ---
    s = df.set_index("time_tag")["flux"]
    binned = s.groupby(s.index.floor(f"{BIN_MINUTES}min")).max()

    # stamp each bin at its last minute, eg the 12:50 bin -> 12:59
    binned.index = binned.index + pd.Timedelta(minutes=BIN_MINUTES - 1)

    # drop the newest bins SWPC may not have finished publishing yet
    now = pd.Timestamp.now(tz="UTC")
    last_allowed = now - pd.Timedelta(minutes=SWPC_LAG_MINUTES)
    last_allowed = last_allowed.floor(f"{BIN_MINUTES}min") + pd.Timedelta(minutes=BIN_MINUTES - 1)
    binned = binned[binned.index <= last_allowed]

    return binned


def atomic_write_lines(path: Path, values: list[float]) -> None:
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    payload = "".join(f"{v:.3e}\n" for v in values)

    fd, tmp = tempfile.mkstemp(prefix=".protons.", suffix=".tmp", dir=TMP_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        path.parent.mkdir(parents=True, exist_ok=True)
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
        records = fetch_records()
        binned = build_series(records)

        if len(binned) < N_SAMPLES:
            raise RuntimeError(
                f"Only {len(binned)} usable {BIN_MINUTES}-minute bins available, "
                f"need {N_SAMPLES} -- refusing to write a short file"
            )

        # keep the most recent N_SAMPLES bins, oldest first
        out = binned.iloc[-N_SAMPLES:].tolist()

        atomic_write_lines(OUTFILE, out)
        print(f"OK: wrote {len(out)} bins to {OUTFILE}")
        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
