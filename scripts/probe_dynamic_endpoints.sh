#!/bin/bash
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
#  probe_dynamic_endpoints.sh
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
#
# probe_dynamic_endpoints.sh
# Probes HamClock CGI/dynamic endpoints and writes a sidecar JSON consumed
# by generate_status_json.sh.
#
# Usage:
#   probe_dynamic_endpoints.sh [-h HOST] [-o OUTPUT] [-t TIMEOUT] [-q]
#
#   -h HOST     Base host URL to probe (default: http://localhost)
#               Examples: http://localhost
#                         https://ohb.hamclock.app
#                         http://192.168.1.50:8080
#   -o OUTPUT   Output path for sidecar JSON
#               (default: /opt/hamclock-backend/htdocs/ham/HamClock/dynamic_status.json)
#   -t TIMEOUT  Per-request timeout in seconds (default: 10)
#   -q          Quiet mode (suppress final summary line)
#   --help      Show this help
#
# Environment overrides (lower precedence than flags):
#   HAMCLOCK_PROBE_HOST
#   HAMCLOCK_PROBE_OUTPUT
#   HAMCLOCK_PROBE_TIMEOUT
#
# Cron examples:
#   # Production (probe localhost, write to public htdocs):
#   */30 * * * * /opt/hamclock-backend/scripts/probe_dynamic_endpoints.sh
#
#   # Local dev — test against remote OHB, write next to script:
#   ./probe_dynamic_endpoints.sh -h https://ohb.hamclock.app -o ./dynamic_status.json

set -u

# ── Defaults ────────────────────────────────────────────────────────────────
HOST="${HAMCLOCK_PROBE_HOST:-http://localhost}"
SIDECAR="${HAMCLOCK_PROBE_OUTPUT:-/opt/hamclock-backend/htdocs/ham/HamClock/dynamic_status.json}"
NODE_EXPORTER_URL="${HAMCLOCK_NODE_EXPORTER_URL:-http://node-exporter:9100/metrics}"
TIMEOUT="${HAMCLOCK_PROBE_TIMEOUT:-10}"
QUIET=0
MIN_BYTES_OK=1   # 200 + >=1 byte counts as ACTIVE
UA="OHB-probe/1.0"

usage() {
    sed -n '32,59p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ── Parse args ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        -h)        HOST="$2";    shift 2 ;;
        -o)        SIDECAR="$2"; shift 2 ;;
        -t)        TIMEOUT="$2"; shift 2 ;;
        -q)        QUIET=1;      shift   ;;
        --help)    usage 0 ;;
        *)         echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

# Strip trailing slashes from HOST so we don't end up with double-slash URLs
HOST="${HOST%/}"
BASE="${HOST}/ham/HamClock"

# ── Endpoint catalog: label | path | tolerant-flag ──────────────────────────
# tolerant=1 means a 200 with zero bytes is reported as IDLE (not EMPTY) and
# does NOT count against `active`. Use for queries whose result depends on
# whether a station is currently transmitting/being heard — the CGI working
# correctly can legitimately return no data.
ENDPOINTS=(
  "version|version.pl|0"
  "wx|wx.pl?lat=33.4&lng=-90.5&is_de=1|0"
  "rss|RSS/web15rss.pl|0"
  "psk_reporter|fetchPSKReporter.pl?ofgrid=CM87&maxage=3600|1"
  "wspr.live|fetchWSPR.pl?maxage=3600|1"
  "rbn|fetchRBN.pl?ofgrid=CM87&maxage=3600|1"
  "band_conditions|fetchBandConditions.pl?MODE=19&MONTH=0&YEAR=2026&UTC=12&TXLAT=40&TXLNG=-90&RXLAT=50&RXLNG=10&POW=100&TOA=3&PATH=0|0"
  "voacap_muf|fetchVOACAP-MUF.pl?TXLAT=40&TXLNG=-90&MODE=19&MONTH=1&YEAR=2026&UTC=12&WATTS=100&MHZ=14.1&HEIGHT=330&WIDTH=660&TOA=3&PATH=0|0"
  "voacap_toa|fetchVOACAP-TOA.pl?TXLAT=40&TXLNG=-90&MODE=19&MONTH=1&YEAR=2026&UTC=12&WATTS=100&MHZ=21.1&HEIGHT=330&WIDTH=660&TOA=3&PATH=0|0"
  "voacap_area|fetchVOACAPArea.pl?TXLAT=40&TXLNG=-90&MODE=19&MONTH=1&YEAR=2026&UTC=12&WATTS=100&MHZ=14.1&HEIGHT=330&WIDTH=660&TOA=3&PATH=0|0"
)

NOW=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

# ── Classification ──────────────────────────────────────────────────────────
#   ACTIVE  : 200 with non-empty body
#   IDLE    : 200 + zero bytes for a "tolerant" endpoint (CGI worked; no spots
#             happens to be a valid answer — e.g. W1AW wasn't transmitting)
#   EMPTY   : 200 + zero bytes for a non-tolerant endpoint (suspicious)
#   TIMEOUT : curl couldn't connect or timed out
#   FAILED  : any other HTTP code (4xx, 5xx)
classify() {
    local code="$1" bytes="$2" tolerant="$3"
    if   [ "$code" = "000" ];                                           then echo "TIMEOUT"
    elif [ "$code" = "200" ] && [ "$bytes" -ge "$MIN_BYTES_OK" ];       then echo "ACTIVE"
    elif [ "$code" = "200" ] && [ "$tolerant" = "1" ];                  then echo "IDLE"
    elif [ "$code" = "200" ];                                           then echo "EMPTY"
    else                                                                     echo "FAILED"
    fi
}

probe() {
    local path="$1"
    local url="${BASE}/${path}"
    local start_ns end_ns code=0 bytes=0 elapsed_ms=0

    # Use %s if %N is not supported (e.g. non-GNU date)
    start_ns=$(date +%s%N 2>/dev/null || date +%s)

    # Capture curl output to a variable first to ensure we get clean data
    local resp
    resp=$(curl -A "$UA" -sS -o /dev/null --max-time "$TIMEOUT" \
                    -w '%{http_code} %{size_download}' \
                    "$url" 2>/dev/null || echo "000 0")
    # Strictly take only the first two space-separated words
    code=$(echo "$resp" | awk '{print $1}' | tr -dc '0-9' | sed 's/^0*//; s/^$/0/')
    bytes=$(echo "$resp" | awk '{print $2}' | tr -dc '0-9' | sed 's/^0*//; s/^$/0/')

    end_ns=$(date +%s%N 2>/dev/null || date +%s)

    # Calculate elapsed time; handle cases where %N is literal or math fails
    [[ "$start_ns" =~ ^[0-9]+$ ]] && [[ "$end_ns" =~ ^[0-9]+$ ]] && [ "$end_ns" -gt "$start_ns" ] \
        && elapsed_ms=$(( (end_ns - start_ns) / 1000000 )) || elapsed_ms=0

    # Return strictly sanitized integers
    echo "$code $bytes $elapsed_ms"
}

# ── Sanity-check output dir ─────────────────────────────────────────────────
SIDECAR_DIR="$(dirname "$SIDECAR")"
if [ ! -d "$SIDECAR_DIR" ]; then
    echo "Output directory does not exist: $SIDECAR_DIR" >&2
    exit 2
fi
if [ ! -w "$SIDECAR_DIR" ]; then
    echo "Output directory not writable: $SIDECAR_DIR" >&2
    exit 2
fi

# ── Probe loop ──────────────────────────────────────────────────────────────
active=0; idle=0; empty=0; failed=0; timeout=0; total=0
first=1

{
    printf '{\n'
    printf '  "generated_utc": "%s",\n' "$NOW"
    printf '  "host": "%s",\n'          "$HOST"
    printf '  "endpoints": [\n'

    for entry in "${ENDPOINTS[@]}"; do
        # Split label|path|tolerant — path may contain '|' in theory but our
        # endpoints don't, so a 3-way split with cut is safe.
        label=$(   printf '%s' "$entry" | cut -d'|' -f1)
        path=$(    printf '%s' "$entry" | cut -d'|' -f2)
        tolerant=$(printf '%s' "$entry" | cut -d'|' -f3)
        total=$(( total + 1 ))

        read -r code bytes elapsed_ms < <(probe "$path")
        status=$(classify "$code" "$bytes" "$tolerant")

        case "$status" in
            ACTIVE)  active=$((  active  + 1 )) ;;
            IDLE)    idle=$((    idle    + 1 )) ;;
            EMPTY)   empty=$((   empty   + 1 )) ;;
            TIMEOUT) timeout=$(( timeout + 1 )) ;;
            FAILED)  failed=$((  failed  + 1 )) ;;
        esac

        # Strictly sanitize results from probe to ensure valid JSON and decimal interpretation
        clean_code=$(echo "$code" | awk '{print $1}' | tr -dc '0-9' | sed 's/^0*//; s/^$/0/')
        clean_bytes=$(echo "$bytes" | awk '{print $1}' | tr -dc '0-9' | sed 's/^0*//; s/^$/0/')
        clean_elapsed=$(echo "$elapsed_ms" | awk '{print $1}' | tr -dc '0-9' | sed 's/^0*//; s/^$/0/')

        # JSON-escape the label and path
        safe_label=$(printf '%s' "$label" | sed 's/\\/\\\\/g; s/"/\\"/g')
        safe_path=$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')
        # Render tolerant as a real JSON boolean
        if [ "$tolerant" = "1" ]; then tolerant_json="true"; else tolerant_json="false"; fi

        [ "$first" -eq 0 ] && printf ',\n'
        first=0
        printf '    {\n'
        printf '      "label": "%s",\n'              "$safe_label"
        printf '      "path": "/ham/HamClock/%s",\n' "$safe_path"
        printf '      "http_code": %d,\n'            "$clean_code"
        printf '      "bytes": %d,\n'                "$clean_bytes"
        printf '      "elapsed_ms": %d,\n'           "$clean_elapsed"
        printf '      "tolerant": %s,\n'             "$tolerant_json"
        printf '      "status": "%s",\n'             "$status"
        printf '      "checked_utc": "%s"\n'         "$NOW"
        printf '    }'
    done

    # Healthy = ACTIVE + IDLE (CGI is responding; IDLE is a legitimate empty answer).
    healthy=$(( active + idle ))

    # Fetch custom metrics from node-exporter
    count_24h=$(curl -A "$UA" -sS --max-time "$TIMEOUT" "$NODE_EXPORTER_URL" 2>/dev/null | grep "^count_24_hours" | awk '{print $2}')
    # Ensure count_24h is a valid integer
    if ! [[ "$count_24h" =~ ^[0-9]+$ ]]; then
        count_24h=0
    fi

    printf '\n  ],\n'
    printf '  "summary": {\n'
    printf '    "total":   %d,\n' "$total"
    printf '    "active":  %d,\n' "$active"
    printf '    "idle":    %d,\n' "$idle"
    printf '    "empty":   %d,\n' "$empty"
    printf '    "failed":  %d,\n' "$failed"
    printf '    "timeout": %d,\n' "$timeout"
    printf '    "healthy": %d,\n' "$healthy"
    printf '    "count_24h": %d\n' "$count_24h"
    printf '  },\n'

    # Top-level rollup: OK if every endpoint is ACTIVE or IDLE.
    if   [ "$healthy" -eq "$total" ]; then printf '  "overall": "OK"\n'
    elif [ "$healthy" -gt 0 ];        then printf '  "overall": "DEGRADED"\n'
    else                                   printf '  "overall": "DOWN"\n'
    fi
    printf '}\n'
} > "${SIDECAR}.tmp" && mv "${SIDECAR}.tmp" "$SIDECAR"

if [ "$QUIET" -eq 0 ]; then
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] host=${HOST} healthy=${healthy}/${total} (active=${active} idle=${idle}) -> ${SIDECAR}"
fi
