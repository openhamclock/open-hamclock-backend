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
    faster. NetLogger's published guidance is roughly:
        GetActiveNets   1 call / minute
        GetCheckins     3 calls / minute   (hard cap higher, but be polite)
    and the server now returns HTTP 429 when flooded.
  * GetActiveNets gives us each net's NetControl CALLSIGN but no location.
    To put a net on the map we look up the NCS's grid square from its own
    check-in via GetCheckins. That is the rate-limited call, so we:
        - cache resolved grids persistently (GRID_CACHE_PATH), keyed by
          server|netname, with a TTL -- an NCS rarely moves mid-net;
        - look up at most MAX_CHECKINS_PER_RUN nets per run (oldest/unknown
          first), so over a few minutes every active net fills in while we
          stay well under the GetCheckins budget;
        - negative-cache (blank grid) for a shorter TTL so an NCS with no grid
          isn't retried every single minute.
    The "Grid" column may be blank for a net we haven't resolved yet; HamClock
    falls back to a cty.dat lookup of the NCS callsign in that case, so a blank
    is harmless.
  * Files are written atomically (temp file + rename) so HamClock never reads a
    half-written file.

Usage:
    poll_activenets.py            # normal run: fetch + write the CSV
    poll_activenets.py --debug    # print discovered XML tags + parsed rows
    poll_activenets.py --stdout   # write CSV to stdout instead of the file
"""

import argparse
import csv
import io
import json
import os
import re
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

API_URL       = "https://www.netlogger.org/api/GetActiveNets.php"
CHECKINS_URL  = "https://www.netlogger.org/api/GetCheckins.php"
CLIENT_NAME   = "HamClock-OHB"
SERVER_NAME   = ""              # "" = all servers, or e.g. "NETLOGGER"
OUTPUT_PATH   = "/opt/hamclock-backend/htdocs/ham/HamClock/activenets/activenets.txt"
HTTP_TIMEOUT  = 20              # seconds
USER_AGENT    = "HamClock-OHB-ActiveNets/1.1 (+https://github.com/komacke/open-hamclock-backend)"

WRITE_TIMESTAMP_COMMENT = True  # first line: "# updated <UTC> ..."
WRITE_COLUMN_HEADER     = True  # second line: the CSV column names

# --- frequency normalization --------------------------------------------------
# NetLogger frequencies are entered inconsistently: some as MHz ("7.153",
# "3.973 MHz"), some as bare kHz ("7140"), with or without a unit suffix. We
# normalize every value to one consistent style so the pane doesn't show e.g.
# "7153" next to "7.248" on the same band.
#   "hybrid" -> kHz at/below 6 m (HF/6m), MHz above (2 m, 70 cm, ...). Default:
#              keeps HF readable as integers and avoids ugly 6-digit kHz on VHF/UHF.
#   "mhz"    -> always MHz (narrowest, most uniform field width)
#   "khz"    -> always kHz
FREQ_UNIT_POLICY = "hybrid"
SIXM_TOP_KHZ     = 54000        # top of 6 m; at/below -> kHz, above -> MHz (hybrid)


# --- NCS grid lookup (Path B) cache + throttle ---------------------------------
GRID_CACHE_PATH      = "/opt/hamclock-backend/cache/activenets/grid_cache.json"
GRID_TTL_SECS        = 6 * 3600     # trust a known grid this long
GRID_NEG_TTL_SECS    = 1 * 3600     # retry a blank/unknown grid only this often
MAX_CHECKINS_PER_RUN = 2            # GetCheckins lookups per run (<= NetLogger's ~3/min)

# Output columns, in order. Each entry is:
#   (output_header, [source tag names to try, case-insensitive, first match wins])
# N.B. "Grid" is computed (NCS grid via GetCheckins) and stuffed into rec["grid"]
# before build_csv(); it MUST stay last so HamClock's column indexing is stable.
COLUMNS = [
    ("NetName",    ["NetName"]),
    ("Frequency",  ["Frequency"]),
    ("Band",       ["Band"]),
    ("Mode",       ["Mode"]),
    ("NetControl", ["NetControl", "NCS"]),
    ("Checkins",   ["SubscriberCount", "Members", "NumCheckins", "Checkins"]),
    ("Logger",     ["Logger"]),
    ("Started",    ["Date"]),
    ("Grid",       ["Grid"]),
]

TMP_DIR = "/opt/hamclock-backend/htdocs/tmp"


def localname(tag):
    """Strip any XML namespace, return lowercased local tag name."""
    if "}" in tag:
        tag = tag.split("}", 1)[1]
    return tag.lower()


def http_get(url):
    """GET url with our UA, return raw bytes."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.read()


def fetch_active_nets():
    """Return the raw XML bytes from the NetLogger GetActiveNets endpoint."""
    params = {"ClientName": CLIENT_NAME}
    if SERVER_NAME:
        params["ServerName"] = SERVER_NAME
    return http_get(API_URL + "?" + urllib.parse.urlencode(params))


def fetch_checkins(server, netname):
    """Return raw XML bytes from GetCheckins for one net."""
    params = {"ClientName": CLIENT_NAME, "ServerName": server, "NetName": netname}
    return http_get(CHECKINS_URL + "?" + urllib.parse.urlencode(params))


def parse_nets(xml_bytes):
    """
    Parse GetActiveNets and return (rows, all_tags).

    rows     -- list of dicts mapping lowercased child-tag -> text, one per net.
                Each row also carries "_server" = the owning <ServerName>.
    all_tags -- set of every child tag seen (for --debug).

    Primary parse walks <Server> -> <ServerName> + <Net>* so we keep the server
    each net lives on (needed for GetCheckins). Falls back to the old "anything
    with a <NetName> child" heuristic if the structure is unexpected.
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
            sys.stderr.write(f"NetLogger returned <Error>: {(el.text or '').strip()}\n")
            return rows, all_tags

    # structured walk: Server -> ServerName + Net*
    for server in root.iter():
        if localname(server.tag) != "server":
            continue
        sname = ""
        for c in server:
            if localname(c.tag) == "servername":
                sname = (c.text or "").strip()
        for net in server:
            if localname(net.tag) != "net":
                continue
            rec = {localname(g.tag): (g.text or "").strip() for g in net}
            if "netname" in rec:
                rec["_server"] = sname
                all_tags.update(k for k in rec if not k.startswith("_"))
                rows.append(rec)

    # fallback heuristic if the structured walk found nothing
    if not rows:
        for el in root.iter():
            children = list(el)
            if not children:
                continue
            rec = {localname(c.tag): (c.text or "").strip() for c in children}
            if "netname" in rec:
                rec["_server"] = rec.get("servername", "")
                all_tags.update(k for k in rec if not k.startswith("_"))
                rows.append(rec)

    return rows, all_tags


def ncs_grid_from_checkins(xml_bytes, ncs_call):
    """Return the <Grid> of the check-in whose <Callsign> matches ncs_call, or ''."""
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return ""
    want = (ncs_call or "").strip().upper()
    if not want:
        return ""
    for el in root.iter():
        if localname(el.tag) != "checkin":
            continue
        fields = {localname(c.tag): (c.text or "").strip() for c in el}
        if fields.get("callsign", "").upper() == want:
            return fields.get("grid", "")
    return ""


# --- grid cache ---------------------------------------------------------------

def load_grid_cache():
    try:
        with open(GRID_CACHE_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_grid_cache(cache):
    try:
        write_atomic(GRID_CACHE_PATH, json.dumps(cache, separators=(",", ":")))
    except Exception as exc:                                   # noqa: BLE001
        sys.stderr.write(f"grid cache write failed (non-fatal): {exc}\n")


def cache_key(server, netname):
    return f"{server}|{netname}"


def cache_is_fresh(entry, ncs):
    """A cache hit is usable if same NCS and within the (positive/negative) TTL."""
    if not entry or entry.get("ncs", "") != ncs:
        return False
    age = time.time() - entry.get("ts", 0)
    ttl = GRID_TTL_SECS if entry.get("grid") else GRID_NEG_TTL_SECS
    return age < ttl


def resolve_grids(rows, cache, do_lookups=True):
    """
    Fill rec["grid"] for every net, using the cache and (throttled) GetCheckins.

    Returns the number of GetCheckins calls actually made.
    Mutates rows in place and updates cache. Prunes cache to active keys.
    """
    now = time.time()
    active_keys = set()
    need_lookup = []        # (staleness_ts, key, server, netname, ncs)

    # first pass: serve from cache where we can, queue the rest
    for rec in rows:
        server  = rec.get("_server", "")
        netname = rec.get("netname", "")
        ncs     = rec.get("netcontrol", "") or rec.get("ncs", "")
        key     = cache_key(server, netname)
        active_keys.add(key)

        entry = cache.get(key)
        if cache_is_fresh(entry, ncs):
            rec["grid"] = entry.get("grid", "")
        else:
            rec["grid"] = entry.get("grid", "") if entry else ""   # show stale grid meanwhile
            # priority: never-seen (ts 0) first, then oldest
            need_lookup.append((entry.get("ts", 0) if entry else 0, key, server, netname, ncs))

    calls = 0
    if do_lookups and need_lookup:
        need_lookup.sort(key=lambda t: t[0])                       # stalest/unknown first
        for _, key, server, netname, ncs in need_lookup[:MAX_CHECKINS_PER_RUN]:
            grid = ""
            try:
                grid = ncs_grid_from_checkins(fetch_checkins(server, netname), ncs)
            except Exception as exc:                               # noqa: BLE001
                sys.stderr.write(f"GetCheckins failed for {server}|{netname}: {exc}\n")
            cache[key] = {"ncs": ncs, "grid": grid, "ts": now}
            calls += 1
            # reflect the just-resolved grid into the row we are about to write
            for rec in rows:
                if cache_key(rec.get("_server", ""), rec.get("netname", "")) == key:
                    rec["grid"] = grid

    # prune cache entries for nets no longer active
    for dead in [k for k in cache if k not in active_keys]:
        del cache[dead]

    return calls


# --- CSV ----------------------------------------------------------------------

def pick(record, source_names):
    """First non-empty value from record for any of source_names (ci)."""
    for name in source_names:
        val = record.get(name.lower())
        if val:
            return val
    return ""


_FREQ_NUM_RE = re.compile(r"[-+]?\d*\.?\d+")

def freq_to_khz(raw):
    """Parse a NetLogger frequency string to canonical kHz (float), or None.

    Entries are inconsistent -- MHz ("7.153", "3.973 MHz") or bare kHz ("7140").
    Disambiguate by magnitude: the lowest ham band is ~1.8 MHz, so a bare value
    < 1000 was typed as MHz and anything >= 1000 is already kHz. The same rule
    holds on the HamClock side, so the normalized string we emit stays parseable
    there for band-color purposes.
    """
    if not raw:
        return None
    m = _FREQ_NUM_RE.search(raw)        # leading number, ignores any " MHz"/"MHZ" suffix
    if not m:
        return None
    try:
        v = float(m.group())
    except ValueError:
        return None
    if v <= 0:
        return None
    return v * 1000.0 if v < 1000.0 else v

def format_freq(raw):
    """Return a normalized, consistent frequency string per FREQ_UNIT_POLICY.

    Unparseable input is returned unchanged rather than blanked, so a weird
    value still shows something.
    """
    khz = freq_to_khz(raw)
    if khz is None:
        return raw
    if FREQ_UNIT_POLICY == "mhz":
        use_khz = False
    elif FREQ_UNIT_POLICY == "khz":
        use_khz = True
    else:                               # hybrid
        use_khz = khz <= SIXM_TOP_KHZ
    if use_khz:
        return f"{round(khz)} kHz"      # e.g. 7140 -> "7140 kHz", 7.153 -> "7153 kHz"
    return f"{khz/1000.0:.3f} MHz"      # e.g. 145230 -> "145.230 MHz", 444000 -> "444.000 MHz"


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
        writer.writerow([pick(rec, srcs) for _, srcs in COLUMNS])

    return buf.getvalue()


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
        xml_bytes = fetch_active_nets()
    except Exception as exc:                                       # noqa: BLE001
        sys.stderr.write(f"fetch failed, leaving previous file in place: {exc}\n")
        return 1

    rows, all_tags = parse_nets(xml_bytes)

    # resolve NCS grids (cached + throttled). Skip the network in --debug.
    cache = load_grid_cache()
    calls = resolve_grids(rows, cache, do_lookups=not args.debug)
    if not args.debug:
        save_grid_cache(cache)

    # normalize the displayed frequency so every net uses one consistent style
    for rec in rows:
        rec["frequency"] = format_freq(rec.get("frequency", ""))

    if args.debug:
        print(f"Discovered child tags: {sorted(all_tags)}")
        print(f"Parsed {len(rows)} net record(s):")
        for rec in rows:
            shown = {k: v for k, v in rec.items() if not k.startswith("_")}
            print("  " + ", ".join(f"{k}={v!r}" for k, v in sorted(shown.items())))
        print("\n--- CSV that would be written ---")
        print(build_csv(rows), end="")
        return 0

    csv_text = build_csv(rows)
    sys.stderr.write(f"activenets: {len(rows)} net(s), {calls} GetCheckins call(s) this run\n")

    if args.stdout:
        sys.stdout.write(csv_text)
        return 0

    try:
        write_atomic(OUTPUT_PATH, csv_text)
    except Exception as exc:                                       # noqa: BLE001
        sys.stderr.write(f"write failed: {exc}\n")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
