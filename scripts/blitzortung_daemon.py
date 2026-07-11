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

# blitzortung_daemon.py — connect directly to Blitzortung's realtime
# websocket firehose and maintain a rolling global strike cache for
# OHB's lightning/strikes endpoint.
#
# This bypasses the community MQTT proxy (blitzortung.ha.sed.pl) entirely.
# That proxy is geohash-scoped and built to fan one feed out to many
# independent, location-bound Home Assistant installs — not to hand a
# single consumer the full global stream. This daemon has exactly one
# consumer (its own cache) and needs full global coverage regardless of
# where any given HamClock sits, so it speaks the same protocol the
# proxy itself speaks upstream: Blitzortung's own websocket service.
#
# Protocol notes (reverse-engineered, undocumented by Blitzortung —
# ported from mrk-its/homeassistant-blitzortung's ws_client.py):
#   - wss://{ws1,ws3,ws7,ws8}.blitzortung.org:443/
#   - client sends '{"a": 111}' once connected to start receiving data
#   - each frame is a custom LZW-compressed JSON string (see decode())
#
# Run from container entrypoint before lighttpd:
#   python3 /opt/hamclock-backend/scripts/blitzortung_daemon.py &
#
# Requires: pip3 install websockets --break-system-packages

import asyncio
import json
import logging
import os
import random
import ssl
import threading
import time
from collections import deque

import websockets

# ---- configuration -------------------------------------------------------
# ws_client.py's reference list has "ws7" listed twice, which skews
# random.choice() toward that host — deduped here.
WS_HOSTS       = ["ws1", "ws3", "ws7", "ws8"]
WS_HELLO       = '{"a": 111}'

MAX_AGE_SECS         = 900               # keep 10 minutes of strikes
MAX_STRIKES          = 20000             # target size after each prune
STRIKE_SAFETY_MAXLEN = 100000            # hard ceiling between prunes, absorbs bursts
WRITE_INTERVAL       = 30                # write cache / log heartbeat every N seconds
SILENCE_WARN_SECS    = WRITE_INTERVAL * 3
RECONNECT_MIN_DELAY  = 5
RECONNECT_MAX_DELAY  = 60
CACHE_FILE           = '/opt/hamclock-backend/tmp/lightning_global.json'
LOG_FILE             = '/opt/hamclock-backend/logs/blitzortung.log'
# --------------------------------------------------------------------------

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)

# Standard certificate verification. The reference ws_client.py disables
# this entirely (check_hostname=False, verify_mode=CERT_NONE) — that is
# NOT carried over here. If you see TLS/handshake errors against these
# specific hosts once this is actually running against the real network,
# confirm it's a genuine cert issue before relaxing verification.
ssl_context = ssl.create_default_context()

# deque with a maxlen acts as a cheap safety valve: if a burst outruns
# WRITE_INTERVAL, oldest entries just fall off instead of the buffer
# growing unbounded until the next prune.
strikes = deque(maxlen=STRIKE_SAFETY_MAXLEN)
state_lock = threading.Lock()

# Running counters so the heartbeat log can say something useful about
# whether data is actually flowing, instead of just "still alive".
stats = {
    'received':       0,
    'malformed':      0,
    'last_strike_ts': 0.0,
}


def decode(b):
    """Decode Blitzortung's LZW-compressed websocket payload.

    Ported near-verbatim from Blitzortung's own JS client (via
    mrk-its/ws_client.py). Left close to the original on purpose — this
    is bit-exact reverse-engineered decompression, not code meant to be
    readable or "cleaned up".
    """
    e = {}
    d = list(b)
    c = d[0]
    f = c
    g = [c]
    h = 256
    o = h
    for b in range(1, len(d)):
        a = ord(d[b])
        a = d[b] if h > a else e.get(a, f + c)
        g.append(a)
        c = a[0]
        e[o] = f + c
        o += 1
        f = a
    return "".join(g)


def handle_frame(raw):
    """Parse one raw websocket frame into a strike record, or count it as
    malformed. Runs on the asyncio loop; touches shared state under the
    same state_lock the writer thread uses."""
    try:
        data = json.loads(decode(raw))
        strike = {
            'lat':        round(float(data['lat']), 4),
            'lon':        round(float(data['lon']), 4),
            'strikeTime': int(data['time']) // 1_000_000   # ns -> ms
        }
    except Exception:
        with state_lock:
            stats['malformed'] += 1
        return

    with state_lock:
        strikes.append(strike)
        stats['received'] += 1
        stats['last_strike_ts'] = time.time()


async def consume(host):
    uri = f"wss://{host}.blitzortung.org:443/"
    connect_time = time.time()
    async with websockets.connect(uri, ssl=ssl_context) as ws:
        log.info(f"Connected to {uri}")
        await ws.send(WS_HELLO)
        async for raw in ws:
            handle_frame(raw)
        # Loop only ends here on a clean close (code 1000/1001, no
        # exception raised) — log it so a disconnect always leaves a
        # trace, not just silence until the next "Connected to" line.
        duration = time.time() - connect_time
        log.warning(
            f"Disconnected from {uri} after {duration:.0f}s "
            f"(code={ws.close_code}, reason={ws.close_reason!r})"
        )


async def websocket_ingest_loop():
    """Outer reconnect loop with backoff. Catches everything, not just
    ConnectionClosed — a bad frame, a DNS blip, or a TLS hiccup on one
    host should not be able to kill the whole daemon."""
    delay = RECONNECT_MIN_DELAY
    host = random.choice(WS_HOSTS)
    while True:
        try:
            await consume(host)
            delay = RECONNECT_MIN_DELAY   # clean disconnect, reset backoff
        except websockets.ConnectionClosed as e:
            log.error(
                f"Websocket closed on {host}: code={e.code} "
                f"reason={e.reason!r}, retrying in {delay}s"
            )
            host = random.choice([h for h in WS_HOSTS if h != host])
        except Exception as e:
            log.error(f"Websocket error on {host}: {e}, retrying in {delay}s")
            # Force a different host next attempt rather than leaving it to
            # chance — a flaky host shouldn't get re-picked immediately.
            host = random.choice([h for h in WS_HOSTS if h != host])
        await asyncio.sleep(delay)
        delay = min(delay * 2, RECONNECT_MAX_DELAY)


def cache_writer():
    os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
    last_received_total = 0

    while True:
        time.sleep(WRITE_INTERVAL)
        # Whole body wrapped so one bad iteration (disk full, odd data,
        # whatever) logs and moves on instead of silently killing this
        # thread and leaving the cache to go stale with no signal.
        try:
            now_ms = int(time.time() * 1000)
            cutoff = now_ms - (MAX_AGE_SECS * 1000)

            with state_lock:
                fresh = [s for s in strikes if s['strikeTime'] >= cutoff]
                if len(fresh) > MAX_STRIKES:
                    fresh = fresh[-MAX_STRIKES:]
                strikes.clear()
                strikes.extend(fresh)
                snapshot        = list(fresh)
                received_total  = stats['received']
                malformed_total = stats['malformed']
                last_strike_ts  = stats['last_strike_ts']

            tmp = CACHE_FILE + '.tmp'
            with open(tmp, 'w') as f:
                json.dump({'strikes': snapshot, 'updated': now_ms}, f)
            os.replace(tmp, CACHE_FILE)

            new_since_last = received_total - last_received_total
            last_received_total = received_total
            silence = time.time() - last_strike_ts if last_strike_ts else None

            log.info(
                f"Cache: {len(snapshot)} strikes buffered | "
                f"+{new_since_last} new/{WRITE_INTERVAL}s | "
                f"malformed_total={malformed_total}"
            )

            # The check that would have caught the original MQTT bug
            # immediately: "connected", no errors, genuinely no data.
            if silence is not None and silence > SILENCE_WARN_SECS:
                log.warning(
                    f"No strikes received in {silence:.0f}s despite active "
                    f"connection — check websocket ingest"
                )
            elif last_strike_ts == 0:
                log.warning(
                    "No strikes received since startup — check websocket ingest"
                )

        except Exception as e:
            log.error(f"Cache writer error: {e}")


def main():
    log.info("Blitzortung daemon starting (websocket ingest)")
    threading.Thread(target=cache_writer, daemon=True).start()
    asyncio.run(websocket_ingest_loop())


if __name__ == '__main__':
    main()
