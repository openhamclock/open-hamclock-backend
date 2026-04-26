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

"""
psk_cache_updater.py — PSKReporter rolling 24-hour spot cache updater.

Uses PSKReporter's lastseqno mechanism to efficiently poll only NEW spots
each run, building a rolling 24-hour window in a local SQLite database.

Cron entry (every 15 minutes):
    */15 * * * * /opt/hamclock-backend/venv/bin/python3 /opt/hamclock-backend/scripts/psk_reporter_cache.py >> /opt/hamclock-backend/log/psk_cache_updater.log 2>&1

Database: /opt/hamclock-backend/tmp/psk-cache/spots.db
Table: spots
  t        INTEGER  -- flowStartSeconds (indexed)
  s_grid   TEXT     -- senderLocator    (indexed)
  s_call   TEXT     -- senderCallsign
  r_grid   TEXT     -- receiverLocator  (indexed)
  r_call   TEXT     -- receiverCallsign
  mode     TEXT
  freq     INTEGER
  snr      INTEGER
"""

import os
import sys
import time
import logging
import sqlite3
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from pathlib import Path

CACHE_DIR   = Path("/opt/hamclock-backend/tmp/psk-cache")
DB_FILE     = CACHE_DIR / "spots.db"
STATE_FILE  = CACHE_DIR / "lastseqno.txt"
LOCK_FILE   = CACHE_DIR / "updater.lock"

MAX_AGE_SEC = 86400   # prune spots older than 24 hours
BASE_URL    = "https://retrieve.pskreporter.info/query"
HTTP_TIMEOUT = 60
USER_AGENT  = "HamClock-Backend/2.0 (open-hamclock-backend)"
APP_CONTACT = ""      # optional: "appcontact=W4XXX"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [psk_updater] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

def acquire_lock() -> bool:
    if LOCK_FILE.exists():
        try:
            pid = int(LOCK_FILE.read_text().strip())
            os.kill(pid, 0)
            log.warning("Another updater (PID %d) still running — skipping.", pid)
            return False
        except (ProcessLookupError, ValueError):
            log.info("Stale lock removed.")
    LOCK_FILE.write_text(str(os.getpid()))
    return True

def release_lock():
    LOCK_FILE.unlink(missing_ok=True)

def load_lastseqno() -> str | None:
    if STATE_FILE.exists():
        val = STATE_FILE.read_text().strip()
        if val.isdigit():
            return val
    return None

def save_lastseqno(seqno: str):
    STATE_FILE.write_text(seqno)
    log.info("Saved lastseqno=%s", seqno)

def open_db() -> sqlite3.Connection:
    """Open (or create) the SQLite database with optimal settings for concurrency."""
    db = sqlite3.connect(DB_FILE, timeout=30)

    # WAL mode: allows concurrent readers while writer is active
    # This is the key setting that makes 1000 concurrent CGI readers work
    db.execute("PRAGMA journal_mode=WAL")

    # Relaxed durability — we can rebuild from PSKReporter if the DB is lost
    db.execute("PRAGMA synchronous=NORMAL")

    # Keep temp tables in memory
    db.execute("PRAGMA temp_store=MEMORY")

    # 16MB cache — helps with concurrent read performance
    db.execute("PRAGMA cache_size=-16384")

    db.execute("""
        CREATE TABLE IF NOT EXISTS spots (
            t       INTEGER NOT NULL,
            s_grid  TEXT    NOT NULL DEFAULT '',
            s_call  TEXT    NOT NULL DEFAULT '',
            r_grid  TEXT    NOT NULL DEFAULT '',
            r_call  TEXT    NOT NULL DEFAULT '',
            mode    TEXT    NOT NULL DEFAULT '',
            freq    INTEGER NOT NULL DEFAULT 0,
            snr     INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (t, s_call, r_call, freq)
        )
    """)

    # Indexes for the two query patterns: bygrid (sender) and ofgrid (receiver)
    db.execute("CREATE INDEX IF NOT EXISTS idx_r_grid ON spots(r_grid)")
    db.execute("CREATE INDEX IF NOT EXISTS idx_s_grid ON spots(s_grid)")

    # Index on t for fast pruning
    db.execute("CREATE INDEX IF NOT EXISTS idx_t ON spots(t)")

    db.commit()
    return db

def prune_old_spots(db: sqlite3.Connection, cutoff: int) -> int:
    """Delete spots older than cutoff. Returns number of rows deleted."""
    cur = db.execute("DELETE FROM spots WHERE t < ?", (cutoff,))
    db.commit()
    return cur.rowcount

def insert_spots(db: sqlite3.Connection, rows: list[tuple]) -> int:
    """
    Bulk insert spots, ignoring duplicates (PRIMARY KEY conflict).
    Returns number of rows actually inserted.
    """
    cur = db.executemany("""
        INSERT OR IGNORE INTO spots (t, s_grid, s_call, r_grid, r_call, mode, freq, snr)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, rows)
    db.commit()
    return cur.rowcount

def count_spots(db: sqlite3.Connection) -> int:
    return db.execute("SELECT COUNT(*) FROM spots").fetchone()[0]

def build_url(lastseqno: str | None) -> str:
    if lastseqno:
        params = f"lastseqno={lastseqno}&rronly=1&noactive=1&statistics=1"
    else:
        params = "flowStartSeconds=-86400&rronly=1&noactive=1&statistics=1"
    if APP_CONTACT:
        params += f"&{APP_CONTACT}"
    return f"{BASE_URL}?{params}"

def fetch_xml(lastseqno: str | None) -> str:
    url = build_url(lastseqno)
    log.info("Fetching PSKReporter: %s", url)
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept-Encoding": "gzip",
    })
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            data = resp.read()
    except urllib.error.HTTPError as e:
        log.error("HTTP %d: %s", e.code, e.reason)
        raise
    except urllib.error.URLError as e:
        log.error("Network error: %s", e.reason)
        raise

    log.info("Received %d bytes.", len(data))
    if data[:2] == b'\x1f\x8b':
        import gzip
        data = gzip.decompress(data)
        log.info("Decompressed to %d bytes.", len(data))
    return data.decode("utf-8", errors="replace")

def parse_xml(xml_text: str, cutoff: int) -> tuple[list[tuple], str | None]:
    """
    Parse XML into a list of row tuples and extract lastSequenceNumber.
    Only includes spots with flowStartSeconds >= cutoff.
    """
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        log.error("XML parse error: %s", exc)
        return [], None

    new_lastseqno = None
    lsn = root.find("lastSequenceNumber")
    if lsn is not None:
        new_lastseqno = lsn.get("value")
        log.info("lastSequenceNumber from response: %s", new_lastseqno)

    rows = []
    skipped_old = 0
    skipped_bad = 0

    for node in root.iter("receptionReport"):
        t_str = node.get("flowStartSeconds", "")
        try:
            t = int(t_str)
        except ValueError:
            skipped_bad += 1
            continue

        if t < cutoff:
            skipped_old += 1
            continue

        s_grid = (node.get("senderLocator")   or "").upper()
        r_grid = (node.get("receiverLocator") or "").upper()
        s_grid = s_grid[:6] if len(s_grid) >= 6 else s_grid
        r_grid = r_grid[:6] if len(r_grid) >= 6 else r_grid
        s_call = (node.get("senderCallsign")   or "")
        r_call = (node.get("receiverCallsign") or "")
        mode   = (node.get("mode")             or "")
        freq   = int(node.get("frequency") or 0)
        snr    = int(node.get("sNR")       or 0)

        if not s_grid and not r_grid:
            continue

        rows.append((t, s_grid, s_call, r_grid, r_call, mode, freq, snr))

    log.info("Parsed %d spots (%d too old, %d malformed).",
             len(rows), skipped_old, skipped_bad)
    return rows, new_lastseqno

def main():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    if not acquire_lock():
        sys.exit(0)

    try:
        now    = int(time.time())
        cutoff = now - MAX_AGE_SEC

        lastseqno = load_lastseqno()
        if lastseqno:
            log.info("Incremental fetch from lastseqno=%s", lastseqno)
        else:
            log.info("No lastseqno — first run, bootstrapping.")

        xml_text          = fetch_xml(lastseqno)
        rows, new_seqno   = parse_xml(xml_text, cutoff)

        if new_seqno:
            save_lastseqno(new_seqno)
        else:
            log.warning("No lastSequenceNumber in response — state not updated.")

        db      = open_db()
        pruned  = prune_old_spots(db, cutoff)
        added   = insert_spots(db, rows)
        total   = count_spots(db)
        db.close()

        log.info("DB: pruned=%d inserted=%d(of %d fetched) total=%d",
                 pruned, added, len(rows), total)

    except Exception as exc:
        log.error("Fatal: %s", exc, exc_info=True)
        sys.exit(1)
    finally:
        release_lock()

if __name__ == "__main__":
    main()
