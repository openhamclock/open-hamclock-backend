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
#  poll_activenets.py
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
poll_activenets.py - Poll the NetLogger XML API for currently active nets and
write a CSV snapshot for HamClock's "Active Nets" display (served by OHB).

Output (default):
    /opt/hamclock-backend/htdocs/ham/HamClock/activenets/activenets.txt

Design notes / NetLogger etiquette:
  * The NetLogger XML service is READ-ONLY and lives at
    https://www.netlogger.org/api/ . It asks clients to identify themselves
    (ClientName) and not to poll aggressively. Run this once per minute, no
    faster.
  * The file is written atomically (temp file + rename) so HamClock never
    reads a half-written file.
  * An empty result or an <Error> response is treated as "no active nets":
    a fresh file with just the header is written so HamClock can tell the data
    is current rather than stale.

Usage:
    poll_activenets.py            # normal run: fetch + write the CSV
    poll_activenets.py --debug    # print discovered XML tags + parsed rows
    poll_activenets.py --stdout   # write CSV to stdout instead of the file
"""

import argparse
import csv
import io
import os
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

API_URL      = "https://www.netlogger.org/api/GetActiveNets.php"
CLIENT_NAME  = "HamClock-OHB"   
SERVER_NAME  = ""               # "" = all servers, or e.g. "NETLOGGER"
OUTPUT_PATH  = "/opt/hamclock-backend/htdocs/ham/HamClock/activenets/activenets.txt"
HTTP_TIMEOUT = 20               # seconds
USER_AGENT   = "HamClock-OHB-ActiveNets/1.0 (+https://github.com/komacke/open-hamclock-backend)"

WRITE_TIMESTAMP_COMMENT = True  # first line: "# updated <UTC> ..."
WRITE_COLUMN_HEADER     = True  # second line: the CSV column names

# Output columns, in order. Each entry is:
#   (output_header, [source tag names to try, case-insensitive, first match wins])
COLUMNS = [
    ("NetName",    ["NetName"]),
    ("Frequency",  ["Frequency"]),
    ("Band",       ["Band"]),
    ("Mode",       ["Mode"]),
    ("NetControl", ["NetControl", "NCS"]),
    ("Checkins",   ["SubscriberCount", "Members", "NumCheckins", "Checkins"]),
    ("Logger",     ["Logger"]),
    ("Started",    ["Date"]),
]

def fetch_xml():
    """Return the raw XML bytes from the NetLogger GetActiveNets endpoint."""
    params = {"ClientName": CLIENT_NAME}
    if SERVER_NAME:
        params["ServerName"] = SERVER_NAME
    url = API_URL + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.read()

def localname(tag):
    """Strip any XML namespace, return lowercased local tag name."""
    if "}" in tag:
        tag = tag.split("}", 1)[1]
    return tag.lower()

def parse_nets(xml_bytes):
    """
    Parse the XML and return (rows, all_tags).

    rows     -- list of dicts mapping lowercased child-tag -> text, one per net.
    all_tags -- set of every child tag seen (for --debug).

    A "net record" is any element that has a direct child named <NetName>.
    This makes us robust to whatever the container element is called
    (ActiveNet / Net / etc.) and to forward-compatible extra fields.
    """
    rows = []
    all_tags = set()

    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        raise RuntimeError(f"could not parse NetLogger XML: {exc}")

    # If NetLogger reports an explicit error, treat as no nets.
    for el in root.iter():
        if localname(el.tag) == "error":
            text = (el.text or "").strip()
            sys.stderr.write(f"NetLogger returned <Error>: {text}\n")
            return rows, all_tags

    for el in root.iter():
        children = list(el)
        if not children:
            continue
        child_tags = {localname(c.tag): (c.text or "").strip() for c in children}
        if "netname" in child_tags:
            all_tags.update(child_tags.keys())
            rows.append(child_tags)

    return rows, all_tags

def pick(record, source_names):
    """First non-empty value from record for any of source_names (ci)."""
    for name in source_names:
        val = record.get(name.lower())
        if val:
            return val
    return ""

def normalize_frequency(raw: str) -> str:
    """
    Normalise a frequency string from NetLogger to a consistent display format.

    NetLogger entries are inconsistent – any of these may appear:
      "7153"        bare integer, kHz implied  (>= 1000)
      "7.248"       bare decimal, MHz implied  (< 1000)
      "7,153"       thousands-separated kHz
      "7153 kHz"    explicit kHz
      "7.153 MHz"   explicit MHz

    Ambiguity rule (no unit suffix):
      value >= 1000  →  kHz  (smallest ham band is ~1800 kHz on 160 m)
      value <  1000  →  MHz  (all bands expressed in MHz are < 1000)

    Output format:
      Below 54 MHz (6 m and lower HF bands)  →  kHz   e.g. "7153 kHz"
      54 MHz and above (VHF / UHF)           →  MHz   e.g. "144.200 MHz"

    Any value that cannot be parsed is returned unchanged.
    """
    if not raw:
        return raw

    cleaned = raw.strip().replace(",", "")   # drop thousands separators
    lower   = cleaned.lower()

    try:
        if lower.endswith("mhz"):
            freq_khz = float(lower[:-3].strip()) * 1000
        elif lower.endswith("khz"):
            freq_khz = float(lower[:-3].strip())
        else:
            value    = float(cleaned)
            freq_khz = value if value >= 1000 else value * 1000
    except ValueError:
        return raw                           # not a parseable number – leave it alone

    # Boundary: top of the 6 m allocation (~54 MHz)
    if freq_khz < 54_000.0:
        # HF / 6 m → kHz (integer when exact, one decimal place otherwise)
        if freq_khz == int(freq_khz):
            return f"{int(freq_khz)} kHz"
        return f"{freq_khz:.1f} kHz"
    else:
        # VHF / UHF → MHz with three decimal places (standard amateur precision)
        return f"{freq_khz / 1000:.3f} MHz"

def build_csv(rows):
    """Return the full CSV document as a string."""
    buf = io.StringIO()

    if WRITE_TIMESTAMP_COMMENT:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        buf.write(f"# NetLogger active nets - updated {now} - {len(rows)} net(s)\n")

    writer = csv.writer(buf)
    if WRITE_COLUMN_HEADER:
        writer.writerow([col for col, _ in COLUMNS])

    for rec in rows:
        row = []
        for header, srcs in COLUMNS:
            val = pick(rec, srcs)
            if header == "Frequency":
                val = normalize_frequency(val)
            row.append(val)
        writer.writerow(row)

    return buf.getvalue()

TMP_DIR = "/opt/hamclock-backend/htdocs/tmp"

def write_atomic(path, text):
    """Write text to path atomically using OHB temp dir + os.replace."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    os.makedirs(TMP_DIR, exist_ok=True)

    fd, tmp = tempfile.mkstemp(dir=TMP_DIR, prefix=".activenets.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())

        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def main():
    ap = argparse.ArgumentParser(description="Poll NetLogger for active nets.")
    ap.add_argument("--debug", action="store_true",
                    help="print discovered tags and parsed rows, do not write")
    ap.add_argument("--stdout", action="store_true",
                    help="print CSV to stdout instead of writing the file")
    args = ap.parse_args()

    try:
        xml_bytes = fetch_xml()
    except Exception as exc:
        # Network/HTTP failure: leave the existing file untouched (HamClock
        # keeps showing last-known data) and exit non-zero for cron logs.
        sys.stderr.write(f"fetch failed, leaving previous file in place: {exc}\n")
        return 1

    rows, all_tags = parse_nets(xml_bytes)
    rows.sort(key=lambda r: r.get("date", ""), reverse=True)

    if args.debug:
        print(f"Discovered child tags: {sorted(all_tags)}")
        print(f"Parsed {len(rows)} net record(s):")
        for rec in rows:
            print("  " + ", ".join(f"{k}={v!r}" for k, v in sorted(rec.items())))
        print("\n--- CSV that would be written ---")
        print(build_csv(rows), end="")
        return 0

    csv_text = build_csv(rows)

    if args.stdout:
        sys.stdout.write(csv_text)
        return 0

    try:
        write_atomic(OUTPUT_PATH, csv_text)
    except Exception as exc:
        sys.stderr.write(f"write failed: {exc}\n")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
