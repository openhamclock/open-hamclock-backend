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
#  fetch_launches.py
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
# fetch_launches.py  --  OHB backend cron script for HamClock "Upcoming Launches" pane.
#
# Queries the Launch Library 2 API (The Space Devs) for upcoming rocket launches
# and writes a formatted text file for HamClock to consume via openCachedFile().
#
# OUTPUT FILE:
#   <OUTDIR>/launches.txt  (served at <OHB>/ham/HamClock/launches/launches.txt)
#
# CRON (every 15 minutes):
#   */15 * * * * /usr/local/bin/fetch_launches.py
#
# FILE FORMAT (consumed by launches.cpp):
#   Line 1:  attribution credit string
#   Per launch (3 lines):
#     <net_unix_ts> <status_abbrev> <display_name>
#     <provider_abbrev> @ <location>
#     <web_page_url>
#
# STATUS ABBREVS (drives color coding in HamClock):
#   Go    = confirmed T-0  → green highlight
#   TBC   = awaiting confirmation → yellow
#   TBD   = date uncertain → gray
#   Hold  = launch on hold → orange
#   Suc   = success (filtered out as past)
#   Fail  = failure (filtered out)

import json
import os
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

API_URL    = "https://ll.thespacedevs.com/2.3.0/launches/upcoming/"
API_PARAMS = "?limit=20&ordering=net&format=json"
OUTDIR     = "/opt/hamclock-backend/htdocs/ham/HamClock/launches"   # adjust to your OHB webroot
OUTFILE    = os.path.join(OUTDIR, "launches.txt")
TMPDIR     = "/opt/hamclock-backend/htdocs/tmp"
TMPFILE    = os.path.join(TMPDIR + ".tmp")
TIMEOUT    = 15    # HTTP request timeout, seconds
MAX_NAME   = 48    # max display name length (chars) before truncation
MAX_LOC    = 30    # max location string length

# API status abbrevs to keep (filter out completed/failed)
SKIP_ABBREVS = {"Success", "Failure", "Partial Failure", "Anom"}

def unix_ts(iso_str):
    """Convert ISO 8601 UTC string to Unix timestamp int.  Returns 0 on error."""
    if not iso_str:
        return 0
    try:
        # Python 3.7+: handle trailing Z
        s = iso_str.rstrip("Z").split(".")[0]
        dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except Exception:
        return 0

def shorten(s, maxlen):
    """Truncate string to maxlen chars, appending '…' if needed."""
    if len(s) <= maxlen:
        return s
    return s[:maxlen - 1].rstrip() + "\u2026"   # U+2026 HORIZONTAL ELLIPSIS

def pick_url(launch):
    """Return the best human-readable web page URL for this launch."""
    # Prefer explicit infoURLs on the launch object
    for iu in launch.get("infoURLs", []):
        url = iu.get("url", "")
        t   = (iu.get("type") or {}).get("name", "")
        if url and t in ("Official Page", "Wikipedia", "Official Press Kit"):
            return url

    # Fall back to Space Launch Now web app (uses the same slug)
    slug = launch.get("slug", "")
    if slug:
        return f"https://spacelaunchnow.me/launch/{slug}/"

    # Last resort: The Space Devs API browse page
    lid = launch.get("id", "")
    if lid:
        return f"https://ll.thespacedevs.com/2.3.0/launches/{lid}/"

    return "https://thespacedevs.com/llapi"


def pick_location(launch):
    """Return a short location string."""
    try:
        loc = launch["pad"]["location"]["name"]
        # Common shortenings to fit the narrow pane
        loc = loc.replace("Space Force Base", "SFB")
        loc = loc.replace("Space Force Station", "SFS")
        loc = loc.replace("Launch Center", "LC")
        loc = loc.replace("Launch Site", "LS")
        loc = loc.replace("Cosmodrome", "Cosm.")
        loc = loc.replace("People's Republic of China", "China")
        loc = loc.replace(", United States of America", ", USA")
        return shorten(loc, MAX_LOC)
    except (KeyError, TypeError):
        return "Unknown"


def pick_provider(launch):
    """Return short provider abbreviation."""
    try:
        abbrev = launch["launch_service_provider"]["abbrev"]
        name   = launch["launch_service_provider"]["name"]
        return abbrev if abbrev else shorten(name, 12)
    except (KeyError, TypeError):
        return "Unknown"


def status_abbrev(launch):
    """Return a short, HamClock-friendly status tag."""
    try:
        abbrev = launch["status"]["abbrev"]
        name   = launch["status"]["name"]
    except (KeyError, TypeError):
        return "TBD"

    # Normalise to the four tags the C++ uses
    if abbrev == "Go":
        return "Go"
    if abbrev in ("TBC", "TBD"):
        return abbrev
    if "hold" in name.lower() or abbrev in ("Hold", "Liftoff"):
        return "Hold"
    # Everything else (Success, Failure, etc.) — caller should skip
    return abbrev


def fetch_launches():
    url = API_URL + API_PARAMS
    req = urllib.request.Request(url, headers={"User-Agent": "HamClock/fetch_launches.py"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"HTTP error {e.code}: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"URL error: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"JSON decode error: {e}", file=sys.stderr)
        sys.exit(1)

    results = data.get("results", [])
    now_ts  = int(time.time())

    os.makedirs(OUTDIR, exist_ok=True)

    lines = []
    # Credit line (always first)
    lines.append("The Space Devs / Launch Library 2 (thespacedevs.com)")

    count = 0
    for launch in results:
        sa = status_abbrev(launch)

        # Skip completed/failed launches
        if sa in SKIP_ABBREVS:
            continue

        net_ts = unix_ts(launch.get("net", ""))
        if net_ts == 0:
            continue

        # Skip launches more than 1 hour in the past (give a grace window)
        if net_ts < now_ts - 3600:
            continue

        name     = shorten(launch.get("name", "Unknown"), MAX_NAME)
        provider = pick_provider(launch)
        location = pick_location(launch)
        web_url  = pick_url(launch)

        # Line 1: timestamp, status, display name
        lines.append(f"{net_ts} {sa} {name}")
        # Line 2: provider @ location
        lines.append(f"{provider} @ {location}")
        # Line 3: web page URL
        lines.append(web_url)

        count += 1

    # Atomic write via temp file
    with open(TMPFILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(TMPFILE, OUTFILE)

    ts_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%MZ")
    print(f"fetch_launches: wrote {count} launches to {OUTFILE} at {ts_str}")


if __name__ == "__main__":
    fetch_launches()
