#!/usr/bin/env python3
#
#  fetch_hamqsl.py  —  Open HamClock Backend (OHB)
#
#  Polls the HamQSL solar XML feed (Paul Herrman, N0NBH), parses it, and
#  writes a single CSV data product that HamClock's HF-Conditions and
#  VHF-Conditions panes read.  One OHB-central poll serves every client.
#
#  Data courtesy Paul L Herrman N0NBH — used with written permission
#  (2026-06-28).  Required credit "HamQSL.com" is emitted in the output
#  header and is intended to be shown in the panes.
#
#  Source feed : https://www.hamqsl.com/solarxml.php
#  Cadence     : N0NBH advises the XML is near real-time (some fields every
#                ~5 min).  We poll every 10 min to stay fresh while being a
#                good bandwidth citizen.  See crontab line in INSTALL notes.
#
#  Output      : /opt/hamclock-backend/htdocs/ham/HamClock/hamqsl/hamqsl-cond.csv
#                Lines beginning with '#' are comments (skipped by HamClock).
#                Columns: section,name,qualifier,value
#
#  Resilience  : on any fetch/parse error the previous good file is LEFT
#                INTACT (never clobbered with empty/partial data) so the
#                panes degrade to "stale" rather than blank.
#
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#  Licensed under the GNU Affero General Public License v3.0 or later.

import sys
import os
import time
import logging
import datetime
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

FEED_URL   = os.environ.get("HAMQSL_URL", "https://www.hamqsl.com/solarxml.php")
OUT_PATH   = Path(os.environ.get(
    "HAMQSL_OUT",
    "/opt/hamclock-backend/htdocs/ham/HamClock/hamqsl/hamqsl-cond.csv"))
POLL_SECS  = int(os.environ.get("HAMQSL_POLL", "600"))      # advisory; matches cron
TIMEOUT    = int(os.environ.get("HAMQSL_TIMEOUT", "20"))
USER_AGENT = os.environ.get(
    "HAMQSL_UA", "OHB/2.0 (+https://ohb.works) HamQSL-proxy")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s fetch_hamqsl %(levelname)s %(message)s")
log = logging.getLogger("fetch_hamqsl")

# Map raw XML tags -> (section, output-name).  Note N0NBH's tag spellings,
# including the historical "electonflux" typo, are preserved on his side.
SOLAR_FIELDS = [
    ("solarflux",     "sfi"),
    ("sunspots",      "sn"),
    ("aindex",        "a"),
    ("kindex",        "k"),
    ("kindexnt",      "k_nt"),
    ("xray",          "xray"),
    ("heliumline",    "heliumline"),
    ("protonflux",    "protonflux"),
    ("electonflux",   "electronflux"),   # fix typo on our side
    ("aurora",        "aurora"),
    ("normalization", "aurora_norm"),
    ("latdegree",     "aurlat"),
    ("solarwind",     "solarwind"),
    ("magneticfield", "bz"),
    ("geomagfield",   "geomagfield"),
    ("signalnoise",   "signalnoise"),
    ("fof2",          "fof2"),
    ("muffactor",     "muffactor"),
    ("muf",           "muf"),
]


def fetch(url: str) -> bytes:
    req = Request(url, headers={"User-Agent": USER_AGENT,
                                "Accept": "application/xml,text/xml"})
    with urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def _txt(el):
    return (el.text or "").strip() if el is not None else ""


def parse(xml_bytes: bytes) -> dict:
    root = ET.fromstring(xml_bytes)
    sd = root.find("solardata")
    if sd is None:
        raise ValueError("no <solardata> element")

    data = {"updated": _txt(sd.find("updated")),
            "source":  _txt(sd.find("source")) or "N0NBH",
            "solar": [], "hf": [], "vhf": []}

    for tag, name in SOLAR_FIELDS:
        v = _txt(sd.find(tag))
        if v != "":
            data["solar"].append((name, v))

    cc = sd.find("calculatedconditions")
    if cc is not None:
        for b in cc.findall("band"):
            data["hf"].append((b.get("name", ""), b.get("time", ""), _txt(b)))

    vc = sd.find("calculatedvhfconditions")
    if vc is not None:
        for p in vc.findall("phenomenon"):
            data["vhf"].append((p.get("name", ""), p.get("location", ""), _txt(p)))

    # sanity: must have the 8 HF cells at minimum to be useful
    if len(data["hf"]) < 8:
        raise ValueError(f"only {len(data['hf'])} HF band cells parsed")
    return data


def render_csv(data: dict) -> str:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = []
    out.append("# OHB HamQSL conditions  source=HamQSL.com/N0NBH "
               "(https://www.hamqsl.com/solar.html)")
    out.append(f"# hamqsl_updated={data['updated']}  ohb_fetched={now}  poll={POLL_SECS}s")
    out.append("# Data courtesy Paul Herrman N0NBH - used with permission. "
               "Credit: HamQSL.com")
    out.append("# format: section,name,qualifier,value   "
               "(lines beginning with # are comments, skip them)")
    for name, v in data["solar"]:
        out.append(f"SOLAR,{name},,{v}")
    for name, tod, v in data["hf"]:
        out.append(f"HF,{name},{tod},{v}")
    for name, loc, v in data["vhf"]:
        out.append(f"VHF,{name},{loc},{v}")
    return "\n".join(out) + "\n"


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)               # atomic on POSIX


def main() -> int:
    try:
        raw = fetch(FEED_URL)
    except (URLError, HTTPError, TimeoutError) as e:
        log.error("fetch failed (%s); keeping previous file intact", e)
        return 1
    try:
        data = parse(raw)
    except (ET.ParseError, ValueError) as e:
        log.error("parse failed (%s); keeping previous file intact", e)
        return 2
    try:
        atomic_write(OUT_PATH, render_csv(data))
    except OSError as e:
        log.error("write failed (%s)", e)
        return 3
    log.info("wrote %s  (hamqsl updated=%s, %d HF, %d VHF)",
             OUT_PATH, data["updated"], len(data["hf"]), len(data["vhf"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
