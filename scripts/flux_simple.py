#!/usr/bin/env python3
"""
Generate HamClock-style solarflux-99.txt in a CSI-like format (simplified).

Output:
- 99 lines total
- 33 daily values, each repeated 3 times

Phases:
1) daily-solar-indices.txt (DSD):
   - parse last 30 daily rows
   - take Radio Flux 10.7cm column
   - skip the oldest row, keep 29 rows
   - repeat each value 3x

2) wwv.txt:
   - parse "Solar flux NNN"
   - repeat that value 3x
   - if unavailable (e.g. "???"), fall back to the most recent DSD value

3) 27-day outlook tail (3 days):
   - parse 27-day-outlook.txt
   - find the 3 forecast rows immediately following today's date
   - repeat each value 3x
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import date, timedelta
from pathlib import Path
from typing import List, Optional
from urllib.request import Request, urlopen


DSD_URL     = "https://services.swpc.noaa.gov/text/daily-solar-indices.txt"
WWV_URL     = "https://services.swpc.noaa.gov/text/wwv.txt"
OUTLOOK_URL = "https://services.swpc.noaa.gov/text/27-day-outlook.txt"

UA = "open-hamclock-backend/1.0 (+solarflux-99 generator)"

# Month abbreviations used in the 27-day outlook file
_MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4,  "May": 5,  "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}


def fetch_text(url: str, timeout: int = 20) -> str:
    req = Request(url, headers={"User-Agent": UA})
    with urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return raw.decode("utf-8", errors="replace")


def parse_dsd_fluxes(text: str) -> List[int]:
    """
    Parse daily-solar-indices.txt rows.

    Example row:
    2026 01 24  174    147      880      1    -999      *   5  0  0  0  0  0  0

    We only need the Radio Flux 10.7cm value (4th numeric field in the row).
    Returns the most recent 30 flux values.
    """
    fluxes: List[int] = []

    for line in text.splitlines():
        line = line.rstrip()
        if not line or line.startswith(":") or line.startswith("#"):
            continue

        # Match row start: YYYY MM DD flux ...
        m = re.match(r"^\s*(\d{4})\s+(\d{2})\s+(\d{2})\s+(\d+)\b", line)
        if not m:
            continue

        flux = int(m.group(4))
        fluxes.append(flux)

    if len(fluxes) < 30:
        raise ValueError(f"Expected at least 30 DSD rows, found {len(fluxes)}")

    # SWPC rows are chronological; keep the newest 30 parsed flux values.
    # Phase 1 later skips the oldest of these 30, leaving 29 daily values.
    return fluxes[-30:]


def parse_wwv_flux(text: str) -> Optional[int]:
    """
    Parse the WWV line:
      'Solar flux NNN and estimated planetary A-index 36.'
    Returns the integer flux value, or None if the value is unavailable
    (e.g. NOAA publishes '???' during a data outage).
    """
    m = re.search(r"\bSolar flux\s+(\d{1,3})\b", text, re.I)
    return int(m.group(1)) if m else None


def parse_outlook_fluxes(text: str, after_date: date, count: int = 3) -> List[int]:
    """
    Parse 27-day-outlook.txt and return `count` flux values for the days
    immediately following `after_date`.

    Row format:
      2026 Mar 09     135          12          4
    """
    # Build a date->flux map from all rows
    day_flux: dict[date, int] = {}

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(":") or line.startswith("#"):
            continue

        m = re.match(
            r"(\d{4})\s+([A-Za-z]{3})\s+(\d{2})\s+(\d+)", line
        )
        if not m:
            continue

        year  = int(m.group(1))
        month = _MONTHS.get(m.group(2).capitalize())
        day   = int(m.group(3))
        flux  = int(m.group(4))

        if month is None:
            continue

        try:
            d = date(year, month, day)
            day_flux[d] = flux
        except ValueError:
            continue

    result: List[int] = []
    for i in range(1, count + 1):
        d = after_date + timedelta(days=i)
        if d not in day_flux:
            raise ValueError(
                f"27-day outlook missing entry for {d} "
                f"(needed {count} days after {after_date})"
            )
        result.append(day_flux[d])

    return result


def expand_tripled(values: List[int]) -> List[int]:
    out: List[int] = []
    for v in values:
        out.extend([v, v, v])
    return out


def generate_solarflux_99(
    dsd_text: str,
    wwv_text: str,
    outlook_text: str,
    today: Optional[date] = None,
    debug: bool = False,
) -> List[int]:
    if today is None:
        today = date.today()

    # Phase 1: DSD rows (30 total, skip oldest => 29)
    dsd_fluxes_30 = parse_dsd_fluxes(dsd_text)
    phase1_daily = dsd_fluxes_30[1:]  # 29 values

    # Phase 2: WWV observed flux (1 day); fall back to most recent DSD if unavailable
    wwv_flux = parse_wwv_flux(wwv_text)
    if wwv_flux is None:
        wwv_flux = dsd_fluxes_30[-1]
        print(
            f"WARNING: WWV Solar flux unavailable (data gap?); "
            f"using most recent DSD value as fallback: {wwv_flux}",
            file=sys.stderr,
        )
    if debug:
        print(f"DEBUG: wwv_flux (after fallback check): {wwv_flux}", file=sys.stderr)

    # Phase 3: next 3 days from 27-day outlook
    phase3_daily = parse_outlook_fluxes(outlook_text, after_date=today, count=3)

    daily33 = phase1_daily + [wwv_flux] + phase3_daily

    if len(daily33) != 33:
        raise RuntimeError(f"Expected 33 daily values, got {len(daily33)}")

    out99 = expand_tripled(daily33)

    if len(out99) != 99:
        raise RuntimeError(f"Expected 99 values, got {len(out99)}")

    if debug:
        print(f"DEBUG: today={today}", file=sys.stderr)
        print(f"DEBUG: phase1_daily (29): {phase1_daily}", file=sys.stderr)
        print(f"DEBUG: phase3_daily (3): {phase3_daily}", file=sys.stderr)
        print(f"DEBUG: daily33: {daily33}", file=sys.stderr)

    return out99


def write_lines(path: Path, values: List[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for v in values:
            f.write(f"{v}\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate solarflux-99.txt (CSI-like, simplified)")
    ap.add_argument(
        "--out",
        default="/opt/hamclock-backend/htdocs/ham/HamClock/solar-flux/solarflux-99.txt",
        help="Output file path",
    )
    ap.add_argument("--debug", action="store_true", help="Verbose diagnostics to stderr")

    # Optional local overrides for offline testing
    ap.add_argument("--dsd-file",     help="Use local daily-solar-indices.txt instead of fetching SWPC")
    ap.add_argument("--wwv-file",     help="Use local wwv.txt instead of fetching SWPC")
    ap.add_argument("--outlook-file", help="Use local 27-day-outlook.txt instead of fetching SWPC")
    ap.add_argument("--today",        help="Override today's date (YYYY-MM-DD) for testing")

    args = ap.parse_args()

    try:
        today = date.fromisoformat(args.today) if args.today else date.today()

        if args.dsd_file:
            dsd_text = Path(args.dsd_file).read_text(encoding="utf-8", errors="replace")
        else:
            dsd_text = fetch_text(DSD_URL)

        if args.wwv_file:
            wwv_text = Path(args.wwv_file).read_text(encoding="utf-8", errors="replace")
        else:
            wwv_text = fetch_text(WWV_URL)

        if args.outlook_file:
            outlook_text = Path(args.outlook_file).read_text(encoding="utf-8", errors="replace")
        else:
            outlook_text = fetch_text(OUTLOOK_URL)

        values = generate_solarflux_99(dsd_text, wwv_text, outlook_text, today=today, debug=args.debug)
        write_lines(Path(args.out), values)

        if args.debug:
            print(f"DEBUG: wrote {len(values)} lines to {args.out}", file=sys.stderr)

        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
