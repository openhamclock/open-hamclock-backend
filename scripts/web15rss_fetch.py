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

# web15rss_fetch.py — run via cron or systemd timer, NOT by clients
# Writes: /opt/hamclock-backend/cache/rss/{arnewsline,ng3k,hamweekly}.txt
#
# Requirements:
#   pip install requests feedparser beautifulsoup4 lxml
#
# Suggested cron (every 15 min):
#   */15 * * * * /usr/bin/python3 /opt/hamclock-backend/web15rss_fetch.py >> /var/log/ohb-rss-fetch.log 2>&1

import os
import sys
import logging
import shutil
import tempfile
from datetime import date, datetime

import requests
import feedparser
from bs4 import BeautifulSoup

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CACHE_DIR = "/opt/hamclock-backend/cache/rss"
TMP_DIR = "/opt/hamclock-backend/tmp"
REQUEST_TIMEOUT = 15
HEADERS = {"User-Agent": "Mozilla/5.0"}
ARNEWSLINE_MAX = 5
NG3K_MAX = 5
HAMWEEKLY_MAX = 5

# Cache file encodings on disk (must match what web15rss.pl expects when decoding)
CACHE_ENCODINGS = {
    "arnewsline": "utf-8",
    "ng3k": "iso-8859-1",   # CSI-compatible path for NG3K
    "hamweekly": "utf-8",
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Helper: atomic cache write
# Writes to a .tmp file then renames so clients never see a partial file.
# ---------------------------------------------------------------------------
def write_cache(name: str, lines: list[str], encoding: str | None = None) -> None:
    if not lines:
        log.warning("[%s] Nothing to write, keeping existing cache", name)
        return

    enc = encoding or CACHE_ENCODINGS.get(name, "utf-8")

    os.makedirs(TMP_DIR, exist_ok=True)
    dest = os.path.join(CACHE_DIR, f"{name}.txt")
    tmp_fd, tmp_path = tempfile.mkstemp(dir=TMP_DIR, prefix=f"{name}_", suffix=".tmp")

    try:
        with os.fdopen(tmp_fd, "w", encoding=enc, errors="replace", newline="\n") as fh:
            fh.write("\n".join(lines) + "\n")
            fh.flush()
            os.fsync(fh.fileno())

        os.makedirs(CACHE_DIR, exist_ok=True)
        shutil.move(tmp_path, dest)
        os.chmod(dest, 0o644)
        log.info("[%s] Wrote %d lines to cache (%s)", name, len(lines), enc)

    except Exception:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise

# ---------------------------------------------------------------------------
# 1. ARNewsLine
# ---------------------------------------------------------------------------
def fetch_arnewsline() -> None:
    log.info("[arnewsline] Fetching...")

    resp = requests.get(
        "https://www.arnewsline.org/?format=rss",
        headers=HEADERS,
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()

    feed = feedparser.parse(resp.text)
    if not feed.entries:
        raise ValueError("No entries in feed")

    entry = feed.entries[0]
    html = entry.get("content", [{}])[0].get("value", "") or entry.get("summary", "")

    soup = BeautifulSoup(html, "lxml")

    # Remove script/audio link paragraphs
    for p in soup.find_all("p"):
        if p.find("a"):
            p.decompose()

    text = soup.get_text(separator="\n")

    lines = []
    for line in text.splitlines():
        if len(lines) >= ARNEWSLINE_MAX:
            break
        line = line.strip()
        if line.startswith("- "):
            headline = line[2:].strip()
            if headline:
                lines.append(f"ARNewsLine.org: {headline}")

    if not lines:
        raise ValueError("No bullet lines parsed")

    write_cache("arnewsline", lines, encoding=CACHE_ENCODINGS["arnewsline"])


# ---------------------------------------------------------------------------
# 2. NG3K DXpeditions
# ---------------------------------------------------------------------------
def fetch_ng3k() -> None:
    log.info("[ng3k] Fetching...")

    resp = requests.get(
        "https://www.ng3k.com/Misc/adxo.html",
        headers=HEADERS,
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()

    # Let BeautifulSoup parse from bytes to avoid requests text-decoding guess issues
    soup = BeautifulSoup(resp.content, "lxml")

    # Local date is fine for this endpoint; if you want UTC determinism, switch here.
    today = date.today()
    lines = []

    for row in soup.find_all("tr", class_="adxoitem"):
        if len(lines) >= NG3K_MAX:
            break

        tds = row.find_all("td")
        if len(tds) < 4:
            continue

        start_text = tds[0].get_text(strip=True)
        end_text   = tds[1].get_text(strip=True)
        entity     = tds[2].get_text(strip=True)

        call_span = row.find("span", class_="call")
        call = call_span.get_text(strip=True) if call_span else ""

        qsl = tds[-1].get_text(strip=True)

        # Parse dates: "2025 Mar01" or "2025 Mar 01"
        start = None
        end = None

        for fmt in ("%Y %b%d", "%Y %b %d"):
            try:
                start = datetime.strptime(start_text, fmt).date()
                break
            except ValueError:
                pass
        if start is None:
            continue

        for fmt in ("%Y %b%d", "%Y %b %d"):
            try:
                end = datetime.strptime(end_text, fmt).date()
                break
            except ValueError:
                pass
        if end is None:
            continue

        if not (start <= today <= end):
            continue

        smon = start.strftime("%b")
        sday = start.day
        emon = end.strftime("%b")
        eday = end.day
        year = start.year

        lines.append(
            f"NG3K.com: {entity}: {smon} {sday} - {emon} {eday}, {year} -- {call} -- QSL: {qsl}"
        )

    if not lines:
        raise ValueError("No active DXpeditions parsed")

    write_cache("ng3k", lines, encoding=CACHE_ENCODINGS["ng3k"])


# ---------------------------------------------------------------------------
# 3. HamWeekly
# ---------------------------------------------------------------------------
def fetch_hamweekly() -> None:
    log.info("[hamweekly] Fetching...")

    resp = requests.get(
        "https://daily.hamweekly.com/atom.xml",
        headers=HEADERS,
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()

    feed = feedparser.parse(resp.text)
    if not feed.entries:
        raise ValueError("No entries in feed")

    lines = []
    for entry in feed.entries[:HAMWEEKLY_MAX]:
        title = entry.get("title", "").strip()
        if title:
            lines.append(f"HamWeekly.com: {title}")

    if not lines:
        raise ValueError("No titles parsed")

    write_cache("hamweekly", lines, encoding=CACHE_ENCODINGS["hamweekly"])


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
SOURCES = [
    ("arnewsline", fetch_arnewsline),
    ("ng3k",       fetch_ng3k),
    ("hamweekly",  fetch_hamweekly),
]

if __name__ == "__main__":
    log.info("Starting RSS fetch")
    any_failed = False

    for name, fn in SOURCES:
        try:
            fn()
        except Exception as exc:
            log.error("[%s] FAILED: %s", name, exc)
            any_failed = True

    log.info("Fetch complete")
    sys.exit(1 if any_failed else 0)
