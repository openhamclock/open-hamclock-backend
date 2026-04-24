#!/usr/bin/env python3
# blitzortung_daemon.py — subscribe to Blitzortung MQTT and maintain
# a rolling global strike cache for OHB's lightning/strikes endpoint.
#
# Run from container entrypoint before lighttpd:
#   python3 /opt/hamclock-backend/scripts/blitzortung_daemon.py &
#
# Requires: pip3 install paho-mqtt --break-system-packages

import paho.mqtt.client as mqtt
import json
import os
import time
import threading
import logging

# ---- configuration -------------------------------------------------------
MQTT_HOST      = 'blitzortung.ha.sed.pl'
MQTT_PORT      = 1883
MQTT_TOPIC     = 'blitzortung/1.1/#'
MAX_AGE_SECS   = 900                    # keep 10 minutes of strikes
MAX_STRIKES    = 20000                  # hard cap on buffer size
WRITE_INTERVAL = 30                     # write cache every N seconds
CACHE_FILE     = '/opt/hamclock-backend/tmp/lightning_global.json'
LOG_FILE       = '/opt/hamclock-backend/logs/blitzortung.log'
# --------------------------------------------------------------------------

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)

strikes = []
strikes_lock = threading.Lock()

def on_connect(client, userdata, flags, rc, properties=None):
    if rc == 0:
        log.info(f"Connected to {MQTT_HOST}, subscribing to {MQTT_TOPIC}")
        client.subscribe(MQTT_TOPIC)
    else:
        log.error(f"Connection failed rc={rc}")

def on_message(client, userdata, msg):
    try:
        data = json.loads(msg.payload)
        strike = {
            'lat':        round(float(data['lat']), 4),
            'lon':        round(float(data['lon']), 4),
            'strikeTime': int(data['time']) // 1_000_000   # ns -> ms
        }
        with strikes_lock:
            strikes.append(strike)
    except Exception:
        pass    # malformed messages not worth logging

def on_disconnect(client, userdata, rc, properties=None):
    log.warning(f"Disconnected rc={rc}, will reconnect")

def cache_writer():
    os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
    while True:
        time.sleep(WRITE_INTERVAL)
        now_ms  = int(time.time() * 1000)
        cutoff  = now_ms - (MAX_AGE_SECS * 1000)
        with strikes_lock:
            fresh = [s for s in strikes if s['strikeTime'] >= cutoff]
            if len(fresh) > MAX_STRIKES:
                fresh = fresh[-MAX_STRIKES:]
            strikes.clear()
            strikes.extend(fresh)
            snapshot = list(fresh)
        tmp = CACHE_FILE + '.tmp'
        try:
            with open(tmp, 'w') as f:
                json.dump({'strikes': snapshot, 'updated': now_ms}, f)
            os.replace(tmp, CACHE_FILE)
            log.info(f"Cache: {len(snapshot)} strikes")
        except Exception as e:
            log.error(f"Write error: {e}")

if __name__ == '__main__':
    log.info("Blitzortung daemon starting")
    threading.Thread(target=cache_writer, daemon=True).start()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect    = on_connect
    client.on_message    = on_message
    client.on_disconnect = on_disconnect
    client.reconnect_delay_set(min_delay=5, max_delay=60)

    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
            client.loop_forever()
        except Exception as e:
            log.error(f"Connection error: {e}, retrying in 30s")
            time.sleep(30)
