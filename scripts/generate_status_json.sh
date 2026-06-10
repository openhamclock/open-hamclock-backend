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
#  generate_status_json.sh
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
# generate_status_json.sh
# Generates a static status board HTML + JSON for HamClock data products & maps.
# Run via cron every 5–15 minutes, e.g.:
#   */5 * * * * /opt/hamclock-backend/generate_status_json.sh
#
# Reads dynamic_status.json (sidecar) produced by probe_dynamic_endpoints.sh,
# which should run on its own cron every 30 minutes.

# ── Config ──────────────────────────────────────────────────────────────────
# Load external thresholds
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Ensure SCRIPT_DIR is set
STATUS_SETTINGS_CONF="${SCRIPT_DIR}/status_settings.conf"

# Provide default thresholds if the config file is missing or values are not set
THRESH_BZ_ONTA_WX="${THRESH_BZ_ONTA_WX:-300 600 1800}"
THRESH_DRAP_WIND="${THRESH_DRAP_WIND:-600 1200 3600}"
THRESH_XRAY="${THRESH_XRAY:-300 600 1800}"
THRESH_AURORA="${THRESH_AURORA:-1800 3600 7200}"
THRESH_SDO_SPACE="${THRESH_SDO_SPACE:-3600 7200 14400}"
THRESH_SSN="${THRESH_SSN:-7200 14400 28800}" # 2h 4h 8h
THRESH_SSN_HISTORY="${THRESH_SSN_HISTORY:-86400 172800 259200}" # 1d 2d 3d
THRESH_ESATS="${THRESH_ESATS:-3600 7200 14400}"
THRESH_CONTESTS="${THRESH_CONTESTS:-86400 172800 259200}" # 1d 2d 3d
THRESH_CTY_DX="${THRESH_CTY_DX:-2592000 5184000 7776000}" # 30d 60d 90d
THRESH_MAP="${THRESH_MAP:-3600 7200 14400}"
THRESH_CLOUDS="${THRESH_CLOUDS:-3600 7200 14400}"
THRESH_WX_MAP="${THRESH_WX_MAP:-3600 7200 14400}"
THRESH_SOLAR_HISTORY="${THRESH_SOLAR_HISTORY:-2592000 5184000 7776000}" # 30d 60d 90d
THRESH_DEFAULT="${THRESH_DEFAULT:-3600 7200 14400}"

if [ -r "$STATUS_SETTINGS_CONF" ]; then
    source "$STATUS_SETTINGS_CONF"
else
    echo "WARNING: status_settings.conf not found or not readable. Using default thresholds." >&2
fi

DATA_DIR="/opt/hamclock-backend/htdocs/ham/HamClock"
MAPS_DIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
SDO_DIR="/opt/hamclock-backend/htdocs/ham/HamClock/SDO"

# Determine the central mirror host
MIRROR_HOST="${MIRROR:-ohb.hamclock.app}"

OUTPUT="/opt/hamclock-backend/htdocs/ham/HamClock/status.html"
OUTPUT_JSON="${OUTPUT%.html}.json"
DYNAMIC_SIDECAR="/opt/hamclock-backend/htdocs/ham/HamClock/dynamic_status.json"
CALLSIGN="OHB" # your station callsign
VERSION=$(cat /opt/hamclock-backend/git.version 2>/dev/null | cut -b -12)
VERSION="${VERSION:-unknown}" # Provide a default if git.version is missing or empty
TZ_LABEL="UTC"          # display timezone label

PUBLIC_IP=$(dig +short TXT o-o.myaddr.l.google.com @ns1.google.com | tr -d '"' || echo "unknown")

# Named data product subdirectories to enumerate (order preserved in output).
# RSS is intentionally omitted (probed dynamically). SDO has its own section.
DATA_SUBDIRS=(
    Bz
    NOAASpaceWX
    ONTA
    aurora
    contests
    cty
    drap
    dst
    dxpeds
    esats
    geomag
    solar-flux
    solar-wind
    ssn
    worldwx
    xray
)
# ─────────────────────────────────────────────────────────────────────────────

# ── Per-category/file thresholds (seconds) ──────────────────────────────────
get_thresholds() {
    local category="$1"
    local filename="$2"

    # Files that never change — return sentinel
    case "$filename" in
        rank_coeffs.txt|rank2_coeffs.txt|solar-flux-history-1945-2025.txt)
            echo "STATIC"
            return
            ;;
        # regex for cloud maps
        map-[DN]-*-Clouds.*)
            echo "$THRESH_CLOUDS"
            return
            ;;
        # map-[D|N]-*-Countries.* and map-[D|N]-*-Terrain* are static
        map-[DN]-*-Countries.*|map-[DN]-*-Terrain*|Terrain*)
            echo "STATIC"
            return
            ;;
        map-[DN]-*-Wx-mB.*|map-[DN]-*-Wx-in.*)
            echo "$THRESH_WX_MAP"
            return
            ;;
        solarflux-history.txt)
            echo "$THRESH_SOLAR_HISTORY"
            return
            ;;
        ssn-history.txt)
            echo "$THRESH_SSN_HISTORY"
            return
            ;;
    esac

    # Per-category thresholds: echo "fresh_sec recent_sec aged_sec"
    case "$category" in
        Bz|ONTA|worldwx)                       echo "$THRESH_BZ_ONTA_WX" ;;
        drap|solar-wind)                       echo "$THRESH_DRAP_WIND"  ;;
        xray)                                  echo "$THRESH_XRAY"       ;;
        aurora)                                echo "$THRESH_AURORA"     ;;
        NOAASpaceWX|dst|geomag|solar-flux|SDO) echo "$THRESH_SDO_SPACE"  ;;
        ssn)                                   echo "$THRESH_SSN"        ;;
        esats)                                 echo "$THRESH_ESATS"      ;;
        contests)                              echo "$THRESH_CONTESTS"   ;;
        cty|dxpeds)                            echo "$THRESH_CTY_DX"     ;;
        map)                                   echo "$THRESH_MAP"        ;;
        *)                                     echo "$THRESH_DEFAULT"    ;;
    esac
}

classify_age() {
    local age_sec="$1"
    local thresholds="$2"   # "fresh_sec recent_sec aged_sec" or "STATIC"

    if [ "$thresholds" = "STATIC" ]; then
        echo "static STATIC"
        return
    fi

    read -r t_fresh t_recent t_aged <<< "$thresholds"

    if   [ "$age_sec" -lt "$t_fresh"  ]; then echo "ok FRESH"
    elif [ "$age_sec" -lt "$t_recent" ]; then echo "warn RECENT"
    elif [ "$age_sec" -lt "$t_aged"   ]; then echo "aged AGED"
    else                                      echo "stale STALE"
    fi
}
# ─────────────────────────────────────────────────────────────────────────────

# ── Stats Aggregation ────────────────────────────────────────────────────────
DATA_FRESH=0; DATA_RECENT=0; DATA_AGED=0; DATA_STALE=0; DATA_STATIC=0; DATA_TOTAL=0
SDO_FRESH=0;  SDO_RECENT=0;  SDO_AGED=0;  SDO_STALE=0;  SDO_STATIC=0;  SDO_TOTAL=0
MAP_FRESH=0;  MAP_RECENT=0;  MAP_AGED=0;  MAP_STALE=0;  MAP_STATIC=0;  MAP_TOTAL=0

calculate_stats() {
    local dir="$1"
    local label="$2"
    local -n _f=$3; local -n _r=$4; local -n _a=$5; local -n _s=$6; local -n _st=$7; local -n _t=$8

    # Special case: If we are proxying maps, local files don't matter/exist.
    # We iterate the remote status entries instead.
    if [[ "$label" == "map" && -n "$REMOTE_STATUS_HOST" ]]; then
        if [ "$REMOTE_STATUS_SYNCED" -eq 1 ]; then
            for rfname in "${!REMOTE_FILE_STATUS[@]}"; do
                [[ "${REMOTE_FILE_CAT[$rfname]}" == "map" ]] || continue
                _t=$(( _t + 1 ))
                case "${REMOTE_FILE_STATUS[$rfname]}" in
                    FRESH)  _f=$(( _f + 1 )) ;;
                    RECENT) _r=$(( _r + 1 )) ;;
                    AGED)   _a=$(( _a + 1 )) ;;
                    STALE)  _s=$(( _s + 1 )) ;;
                    STATIC) _st=$(( _st + 1 )) ;;
                esac
            done
        else
            # Sync failed for proxied maps - report as stalled/error
            _s=1; _t=1
        fi
        return
    fi

    [ ! -d "$dir" ] && return
    while IFS= read -r -d '' filepath; do
        local filename=$(basename "$filepath")
        [ "$filename" = "ignore" ] && continue
        _t=$(( _t + 1 ))

        local status_text
        local use_remote=0
        if [[ "$label" == "map" && -n "$REMOTE_STATUS_HOST" ]]; then
            use_remote=1
        fi

        if [ "$use_remote" -eq 1 ]; then
            if [ "$REMOTE_STATUS_SYNCED" -eq 1 ]; then
                status_text="${REMOTE_FILE_STATUS[$filename]:-STALE}"
            else
                status_text="SYNC_ERR"
            fi
        else
            local mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo 0)
            local age_sec=$(( NOW_EPOCH - mod_epoch ))
            local thresholds
            thresholds=$(get_thresholds "$label" "$filename")
            local class_and_text
            class_and_text=$(classify_age "$age_sec" "$thresholds")
            status_text="${class_and_text#* }"
        fi

        case "$status_text" in
            FRESH)  _f=$(( _f + 1 )) ;;
            RECENT) _r=$(( _r + 1 )) ;;
            AGED)   _a=$(( _a + 1 )) ;;
            STALE|SYNC_ERR)  _s=$(( _s + 1 )) ;;
            STATIC) _st=$(( _st + 1 )) ;;
        esac
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
}

# ─────────────────────────────────────────────────────────────────────────────

NOW=$(date -u "+%Y-%m-%d %H:%M:%S")
NOW_EPOCH=$(date -u +%s)

# ── Remote Alpha Status ─────────────────────────────────────────────────────
declare -A REMOTE_FILE_MOD=()
declare -A REMOTE_FILE_STATUS=()
declare -A REMOTE_FILE_CAT=()

REMOTE_STATUS_SYNCED=0
REMOTE_STATUS_HOST=""
if [[ -n "${PROXY_MAPS:-}" && "${PROXY_MAPS}" != "false" ]]; then
    REMOTE_STATUS_HOST="${PROXY_MAPS}"
    [[ "$REMOTE_STATUS_HOST" == "true" ]] && REMOTE_STATUS_HOST="$MIRROR_HOST"
fi

if [[ -n "$REMOTE_STATUS_HOST" ]]; then
    REMOTE_URL="http://${REMOTE_STATUS_HOST}/ham/HamClock/status.json"
    # Attempt to fetch with up to 3 retries if data is missing or malformed
    for i in {1..3}; do
        REMOTE_JSON=$(curl -sSL --max-time 10 "$REMOTE_URL" 2>/dev/null)
        if [[ -n "$REMOTE_JSON" ]] && echo "$REMOTE_JSON" | jq -e . >/dev/null 2>&1; then
            while IFS=$'\t' read -r rfname rcat mtime status; do
                [[ -n "$rfname" ]] || continue
                REMOTE_FILE_MOD["$rfname"]="$mtime"
                REMOTE_FILE_STATUS["$rfname"]="$status"
                REMOTE_FILE_CAT["$rfname"]="$rcat"
            done < <(echo "$REMOTE_JSON" | jq -r '.files[] | "\(.filename)\t\(.category)\t\(.modified_utc)\t\(.status)"' 2>/dev/null)
            REMOTE_STATUS_SYNCED=1
            break
        fi
        [ "$i" -lt 3 ] && sleep 2
    done
fi

# ── Dynamic endpoints sidecar ────────────────────────────────────────────────
# Populated by probe_dynamic_endpoints.sh on its own cron (every 30 min).
# We read it here and surface ACTIVE/DEGRADED/DOWN in both HTML and JSON.
# If the sidecar is missing, we degrade gracefully.
DYN_OVERALL="UNKNOWN"
DYN_TOTAL=0
DYN_ACTIVE=0
DYN_IDLE=0
DYN_HEALTHY=0
DYN_EMPTY=0
DYN_FAILED=0
DYN_TIMEOUT=0
DYN_COUNT_24H=0
DYN_GENERATED=""
DYN_AGE_SEC=0
DYN_AVAILABLE=0

DYNAMIC_SIDECAR_CONTENT=""
if [ -r "$DYNAMIC_SIDECAR" ]; then
    # Read content once to avoid multiple file reads
    DYNAMIC_SIDECAR_CONTENT=$(cat "$DYNAMIC_SIDECAR")
    # Check if content is non-empty and valid JSON using jq -e
    if [ -n "$DYNAMIC_SIDECAR_CONTENT" ] && command -v jq >/dev/null 2>&1 && echo "$DYNAMIC_SIDECAR_CONTENT" | jq -e . >/dev/null 2>&1; then
        DYN_AVAILABLE=1
        DYN_OVERALL=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.overall // "UNKNOWN"')
        DYN_TOTAL=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.total // 0')
        DYN_ACTIVE=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.active // 0')
        DYN_IDLE=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.idle // 0')
        DYN_HEALTHY=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.healthy // 0')
        DYN_EMPTY=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.empty // 0')
        DYN_FAILED=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.failed // 0')
        DYN_TIMEOUT=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.timeout // 0')
        DYN_COUNT_24H=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.summary.count_24h // 0')
        DYN_GENERATED=$(echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '.generated_utc // ""')
        # Backward-compat: if sidecar predates "healthy" key, fall back to active
        [ "$DYN_HEALTHY" -eq 0 ] && [ "$DYN_ACTIVE" -gt 0 ] && DYN_HEALTHY="$DYN_ACTIVE"
        if [ -n "$DYN_GENERATED" ]; then
            DYN_GEN_EPOCH=$(date -u -d "$DYN_GENERATED" +%s 2>/dev/null || echo "$NOW_EPOCH")
            DYN_AGE_SEC=$(( NOW_EPOCH - DYN_GEN_EPOCH ))
            # If the sidecar is older than 90 minutes (3 missed runs) treat it as stale.
            if [ "$DYN_AGE_SEC" -gt 5400 ]; then DYN_OVERALL="STALE"; fi
        fi
    else
        echo "WARNING: $DYNAMIC_SIDECAR is empty or malformed JSON. Treating as unavailable." >&2
    fi
else
    echo "WARNING: $DYNAMIC_SIDECAR not found or not readable. Treating as unavailable." >&2
fi

for subdir in "${DATA_SUBDIRS[@]}"; do
    calculate_stats "${DATA_DIR}/${subdir}" "$subdir" DATA_FRESH DATA_RECENT DATA_AGED DATA_STALE DATA_STATIC DATA_TOTAL
done
calculate_stats "$SDO_DIR" "SDO" SDO_FRESH SDO_RECENT SDO_AGED SDO_STALE SDO_STATIC SDO_TOTAL
calculate_stats "$MAPS_DIR" "map" MAP_FRESH MAP_RECENT MAP_AGED MAP_STALE MAP_STATIC MAP_TOTAL

fmt_stat_summary() {
    local f=$1 r=$2 a=$3 s=$4 st=$5
    [ "$f" -gt 0 ] && echo -n "<span class='badge ok'>FRESH: $f</span> "
    [ "$r" -gt 0 ] && echo -n "<span class='badge warn'>RECENT: $r</span> "
    [ "$a" -gt 0 ] && echo -n "<span class='badge aged'>AGED: $a</span> "
    [ "$s" -gt 0 ] && echo -n "<span class='badge stale'>STALE: $s</span> "
    [ "$st" -gt 0 ] && echo -n "<span class='badge static'>STATIC: $st</span> "
}

fmt_dyn_summary() {
    local active=$1 idle=$2 empty=$3 timeout=$4 failed=$5
    [ "$active" -gt 0 ]  && echo -n "<span class='badge ok'>ACTIVE: $active</span> "
    [ "$idle" -gt 0 ]    && echo -n "<span class='badge static'>IDLE: $idle</span> "
    [ "$empty" -gt 0 ]   && echo -n "<span class='badge warn'>EMPTY: $empty</span> "
    [ "$timeout" -gt 0 ] && echo -n "<span class='badge aged'>TIMEOUT: $timeout</span> "
    [ "$failed" -gt 0 ]  && echo -n "<span class='badge stale'>FAILED: $failed</span> "
}

dyn_badge_class() { # This function is fine as is, it just maps states to CSS classes
    case "$1" in
        OK)       echo "ok" ;;
        DEGRADED) echo "warn" ;;
        DOWN)     echo "stale" ;;
        STALE)    echo "aged" ;;
        *)        echo "static" ;;
    esac
}

# ── HTML row builder ─────────────────────────────────────────────────────────
# Args: $1=filepath  $2=category-label
emit_file_row() {
    local filepath="$1"
    local label="$2"
    local filename
    filename=$(basename "$filepath")
    [ "$filename" = "ignore" ] && return

    local mod_epoch mod_human age_sec status_class status_text

    local use_remote=0
    if [[ "$label" == "map" && -n "$REMOTE_STATUS_HOST" ]]; then
        use_remote=1
    fi

    if [ "$use_remote" -eq 1 ]; then
        if [ "$REMOTE_STATUS_SYNCED" -eq 1 ]; then
            mod_human="${REMOTE_FILE_MOD[$filename]:-unknown}"
            mod_epoch=$(date -u -d "$mod_human" +%s 2>/dev/null || echo 0)
            age_sec=$(( NOW_EPOCH - mod_epoch ))
            status_text="${REMOTE_FILE_STATUS[$filename]:-STALE}"
            case "$status_text" in
                FRESH)  status_class="ok" ;;
                RECENT) status_class="warn" ;;
                AGED)   status_class="aged" ;;
                STALE)  status_class="stale" ;;
                *)      status_class="static" ;;
            esac
        else
            status_text="SYNC_ERR"
            status_class="syncerr"
            mod_human="unknown"
            age_sec=0
            age_str="n/a"
        fi
    else
        mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo 0)
        mod_human=$(date -u -d "@$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                 || date -u -r "$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        age_sec=$(( NOW_EPOCH - mod_epoch ))
        class_text=$(classify_age "$age_sec" "$(get_thresholds "$label" "$filename")")
        status_class="${class_text%% *}"
        status_text="${class_text#* }"
    fi

    [ -z "${age_str:-}" ] && {
        local age_min=$(( age_sec / 60 ))
        local age_h=$(( age_sec / 3600 ))

        if   [ "$age_h"   -ge 48 ]; then age_str="$(( age_h / 24 ))d ago"
        elif [ "$age_h"   -ge 1  ]; then age_str="${age_h}h ago"
        elif [ "$age_min" -ge 1  ]; then age_str="${age_min}m ago"
        else                             age_str="${age_sec}s ago"
        fi
    }

    echo "    <tr>"
    echo "      <td class='name'>${filename}</td>"
    echo "      <td class='category'>${label}</td>"
    echo "      <td class='timestamp'>${mod_human} UTC</td>"
    echo "      <td class='age'><span class='badge ${status_class}'>${status_text}</span><span class='age-str'> ${age_str}</span></td>"
    echo "    </tr>"
}

build_rows() {
    local dir="$1"
    local label="$2"

    # Special handling for Maps Proxy
    if [[ "$label" == "map" && -n "$REMOTE_STATUS_HOST" ]]; then
        if [ "$REMOTE_STATUS_SYNCED" -eq 1 ]; then
            local found=0
            for rfname in $(echo "${!REMOTE_FILE_STATUS[@]}" | tr ' ' '\n' | sort); do
                [[ "${REMOTE_FILE_CAT[$rfname]}" == "map" ]] || continue
                found=1
                emit_file_row "$dir/$rfname" "$label"
            done
            return
        else
            echo "    <tr><td colspan='4' class='missing'>⚠ Proxy Sync failed with ${REMOTE_STATUS_HOST}</td></tr>"
            return
        fi
    fi

    if [ ! -d "$dir" ]; then
        echo "    <tr><td colspan='4' class='missing'>⚠ Directory not found: ${dir}</td></tr>"
        return
    fi

    local found=0
    while IFS= read -r -d '' filepath; do
        found=1
        emit_file_row "$filepath" "$label"
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)

    if [ "$found" -eq 0 ]; then
        echo "    <tr><td colspan='4' class='empty'>— no files in ${label}/ —</td></tr>"
    fi
}

build_data_rows() {
    local first=1
    for subdir in "${DATA_SUBDIRS[@]}"; do
        local dir="${DATA_DIR}/${subdir}"

        if [ "$first" -eq 1 ]; then first=0; else
            echo "    <tr class='divider'><td colspan='4'></td></tr>"
        fi

        echo "    <tr class='subdir-header'>"
        echo "      <td colspan='4'>"
        echo "        <span class='subdir-label'>${subdir}/</span>"
        [ ! -d "$dir" ] && echo "        <span class='subdir-missing'>directory not found</span>"
        echo "      </td>"
        echo "    </tr>"

        build_rows "$dir" "$subdir"
    done
}

# ── Dynamic endpoint HTML rows ───────────────────────────────────────────────
build_dynamic_rows() {
    if [ "$DYN_AVAILABLE" -ne 1 ]; then
        echo "    <tr><td colspan='4' class='missing'>⚠ dynamic_status.json not found — has probe_dynamic_endpoints.sh run yet?</td></tr>"
        return
    fi

    echo "$DYNAMIC_SIDECAR_CONTENT" | jq -r '
        .endpoints[] |
        "    <tr>" +
        "<td class=\"name\">" + .path + "</td>" +
        "<td class=\"category\">" + (.http_code|tostring) + "</td>" +
        "<td class=\"timestamp\">" + (.elapsed_ms|tostring) + " ms</td>" +
        "<td class=\"age\"><span class=\"badge " +
          (if   .status=="ACTIVE"  then "ok"
           elif .status=="IDLE"    then "static"
           elif .status=="EMPTY"   then "warn"
           elif .status=="TIMEOUT" then "aged"
           else "stale" end) +
        "\">" + .status + "</span></td>" +
        "</tr>"
    ' "$DYNAMIC_SIDECAR"
}

# ── JSON builder ─────────────────────────────────────────────────────────────
# Args: $1=directory  $2=category-label  $3=nameref to first-entry flag
build_json_entries() {
    local dir="$1"
    local label="$2"
    local -n _first_entry="$3"

    [ ! -d "$dir" ] && return

    while IFS= read -r -d '' filepath; do
        local filename
        filename=$(basename "$filepath")
        [ "$filename" = "ignore" ] && continue

        local mod_epoch mod_human age_sec status_text

        local use_remote=0
        if [[ "$label" == "map" && -n "${REMOTE_FILE_MOD[$filename]:-}" ]]; then
            use_remote=1
        elif [[ "$filename" == "wwff_spots.json" && ! "$CQGMA_API_KEY" =~ ^GMA- && -n "${REMOTE_FILE_MOD[$filename]:-}" ]]; then
            use_remote=1
        fi

        if [ "$use_remote" -eq 1 ]; then
            mod_human="${REMOTE_FILE_MOD[$filename]}"
            mod_epoch=$(date -u -d "$mod_human" +%s 2>/dev/null || echo 0)
            age_sec=$(( NOW_EPOCH - mod_epoch ))
            status_text="${REMOTE_FILE_STATUS[$filename]}"
        else
            mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo 0)
            mod_human=$(date -u -d "@$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                     || date -u -r "$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            age_sec=$(( NOW_EPOCH - mod_epoch ))
            local class_and_text
            class_and_text=$(classify_age "$age_sec" "$(get_thresholds "$label" "$filename")")
            status_text="${class_and_text#* }"
        fi

        local safe_name safe_label
        safe_name=$(printf '%s' "$filename" | sed 's/\\/\\\\/g; s/"/\\"/g')
        safe_label=$(printf '%s' "$label"   | sed 's/\\/\\\\/g; s/"/\\"/g')

        [ "$_first_entry" -eq 0 ] && printf ',\n'
        _first_entry=0
        printf '    {\n'
        printf '      "filename": "%s",\n'      "$safe_name"
        printf '      "category": "%s",\n'      "$safe_label"
        printf '      "modified_utc": "%s",\n'  "$mod_human"
        printf '      "age_seconds": %d,\n'     "$age_sec"
        printf '      "status": "%s"\n'         "$status_text"
        printf '    }'
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
}

build_json() {
    local first_entry=1

    {
        printf '{\n'
        printf '  "generated_utc": "%s",\n'      "$NOW"
        printf '  "callsign": "%s",\n'           "$CALLSIGN"
        printf '  "version": "%s",\n'            "$VERSION"
        printf '  "hostname": "%s",\n'           "$HOST_HOSTNAME"
        printf '  "public_ip": "%s",\n'          "$PUBLIC_IP"
        printf '  "remote_sync_host": "%s",\n'   "$REMOTE_STATUS_HOST"
        printf '  "remote_sync_ok": %s,\n'       "$( [ "$REMOTE_STATUS_SYNCED" -eq 1 ] && echo "true" || echo "false" )"
        printf '  "summary": {\n'
        printf '    "data_product_files": %d,\n' "$DATA_TOTAL"
        printf '    "sdo_files": %d,\n'          "$SDO_TOTAL"
        printf '    "map_files": %d,\n'          "$MAP_TOTAL"
        printf '    "dynamic_endpoints": %d,\n'  "$DYN_TOTAL"
        printf '    "dynamic_active": %d,\n'     "$DYN_ACTIVE"
        printf '    "dynamic_idle": %d,\n'       "$DYN_IDLE"
        printf '    "dynamic_healthy": %d,\n'    "$DYN_HEALTHY"
        printf '    "dynamic_count_24h": %d,\n'  "$DYN_COUNT_24H"
        printf '    "total_files": %d\n'         "$(( DATA_TOTAL + SDO_TOTAL + MAP_TOTAL ))"
        printf '  },\n'

        # Inline the full dynamic sidecar (or null if missing) so consumers
        # have one place to look. Cheap: it's already JSON.
        if [ "$DYN_AVAILABLE" -eq 1 ]; then
            # Use the already read and validated content
            printf '  "dynamic": %s,\n' "$DYNAMIC_SIDECAR_CONTENT"
        else
            printf '  "dynamic": null,\n'
        fi

        printf '  "files": [\n'

        for subdir in "${DATA_SUBDIRS[@]}"; do
            build_json_entries "${DATA_DIR}/${subdir}" "$subdir" first_entry
        done
        build_json_entries "$SDO_DIR"  "SDO" first_entry
        build_json_entries "$MAPS_DIR" "map" first_entry

        printf '\n  ]\n'
        printf '}\n'
    } > "$OUTPUT_JSON"
}

# ── Write HTML ───────────────────────────────────────────────────────────────
{
SYNC_SUBTITLE=""
if [[ -n "$REMOTE_STATUS_HOST" ]]; then
    if [ "$REMOTE_STATUS_SYNCED" -eq 1 ]; then
        SYNC_SUBTITLE="<div class='subtitle' style='color:var(--ok); font-weight:600;'>✓ Synced with ${REMOTE_STATUS_HOST}</div>"
    else
        SYNC_SUBTITLE="<div class='subtitle' style='color:var(--stale); font-weight:600;'>⚠ Sync failed: ${REMOTE_STATUS_HOST} (using local fallback)</div>"
    fi
fi

cat << HTML_HEAD
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="refresh" content="300">
  <title>${CALLSIGN} · Data Product Status</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg:       #f7f5f2;
      --panel:    #fdfcfa;
      --border:   #e0dbd4;
      --accent:   #3d6b99;
      --accent2:  #3a7a56;
      --accent3:  #7a5a99;
      --accent4:  #99623d;
      --dim:      #9a9590;
      --text:     #2e2b27;
      --muted:    #7a756e;
      --ok:       #2e7a50;
      --warn:     #8a6200;
      --aged:     #8a4e00;
      --stale:    #9e2020;
      --static:   #3d6b99;
    }

    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      background: var(--bg);
      color: var(--text);
      font-family: 'IBM Plex Sans', sans-serif;
      font-size: 14px;
      line-height: 1.6;
      min-height: 100vh;
      overflow-x: hidden;
    }

    /* ── Header ── */
    header {
      border-bottom: 1px solid var(--border);
      padding: 20px 24px 16px;
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
      background: var(--panel);
      flex-wrap: wrap;
    }
    .header-left { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
    .callsign {
      font-family: 'IBM Plex Sans', sans-serif;
      font-weight: 600;
      font-size: clamp(1.3rem, 5vw, 2.2rem);
      letter-spacing: 0.04em;
      color: var(--accent);
      line-height: 1.1;
    }
    .subtitle { font-size: 0.7rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; }
    .header-right {
      text-align: right;
      display: flex;
      flex-direction: column;
      gap: 3px;
      align-items: flex-end;
      flex-shrink: 0;
    }
    .clock-label { font-size: 0.65rem; letter-spacing: 0.05em; color: var(--muted); text-transform: uppercase; }
    .clock {
      font-family: 'IBM Plex Mono', monospace;
      font-size: clamp(0.78rem, 2.5vw, 1.0rem);
      color: var(--accent2);
      letter-spacing: 0.02em;
      font-weight: 500;
    }

    /* ── Summary bar ── */
    .summary {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      border-bottom: 1px solid var(--border);
      background: var(--panel);
    }
    .summary-item {
      padding: 12px 20px;
      border-right: 1px solid var(--border);
      border-bottom: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      gap: 2px;
    }
    .summary-item:nth-child(2n) { border-right: none; }

    /* If the total number of items is odd, make the last one span both columns */
    .summary-item:last-child:nth-child(odd) {
      grid-column: span 2;
      border-right: none;
    }

    .summary-item:nth-last-child(-n+2) { border-bottom: none; }
    /* If 2nd-to-last item is even, it sits above a spanning last item; give it a border-bottom */
    .summary-item:nth-last-child(2):nth-child(even) { border-bottom: 1px solid var(--border); }

    .summary-label { font-size: 0.62rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; }
    .summary-value {
      font-family: 'IBM Plex Mono', monospace;
      font-size: 1.25rem;
      font-weight: 500;
      color: var(--accent);
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
      align-items: center;
      min-height: 1.8rem;
    }

    /* ── Legend ── */
    .legend {
      display: flex;
      flex-direction: column;
      gap: 10px;
      padding: 10px 24px;
      background: #f0ede8;
      border-bottom: 1px solid var(--border);
    }
    .legend-group {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
    }
    .legend-label {
      font-size: 0.63rem;
      color: var(--muted);
      font-weight: 600;
      letter-spacing: 0.05em;
      min-width: 150px;
    }
    .legend-item { display: flex; align-items: center; gap: 5px; font-size: 0.65rem; color: var(--muted); }

    /* ── Sections ── */
    .section { padding: 20px 24px; border-bottom: 1px solid var(--border); }
    .section-header { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
    .section-icon {
      width: 4px; height: 18px; background: var(--accent);
      border-radius: 2px; flex-shrink: 0; opacity: 0.7;
    }
    .maps-icon    { background: var(--accent2); }
    .sdo-icon     { background: var(--accent3); }
    .dynamic-icon { background: var(--accent4); }
    .section-title {
      font-family: 'IBM Plex Sans', sans-serif; font-size: 0.78rem; font-weight: 600;
      letter-spacing: 0.07em; color: var(--text); text-transform: uppercase;
    }
    .section-path {
      font-family: 'IBM Plex Mono', monospace;
      font-size: 0.62rem;
      color: var(--dim);
      margin-left: auto;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      max-width: 40vw;
    }

    .dynamic-summary {
      margin-bottom: 10px;
      font-size: 0.78rem;
      color: var(--muted);
    }

    /* ── Table ── */
    table { width: 100%; border-collapse: collapse; font-size: 0.83rem; }
    thead tr { border-bottom: 1px solid var(--border); }
    th {
      font-size: 0.64rem; letter-spacing: 0.06em; color: var(--muted);
      text-transform: uppercase; text-align: left; padding: 7px 10px; font-weight: 500;
    }
    tbody tr { border-bottom: 1px solid rgba(200,193,185,0.4); transition: background 0.12s; }
    tbody tr:hover { background: rgba(61,107,153,0.04); }

    tr.subdir-header { background: rgba(61,107,153,0.05); border-top: 1px solid var(--border); border-bottom: none; }
    tr.subdir-header:hover { background: rgba(61,107,153,0.05); }
    tr.subdir-header td { padding: 6px 10px; }
    .subdir-label {
      font-family: 'IBM Plex Mono', monospace; font-size: 0.73rem;
      font-weight: 500; letter-spacing: 0.02em; color: var(--accent);
    }
    .subdir-missing { font-size: 0.65rem; color: var(--stale); margin-left: 8px; }
    tr.divider td { padding: 0; height: 4px; background: transparent; border: none; }

    td { padding: 8px 10px; vertical-align: middle; }
    td.name {
      font-family: 'IBM Plex Mono', monospace;
      color: var(--text);
      word-break: break-all;
      min-width: 0;
    }
    td.category { color: var(--muted); font-size: 0.73rem; white-space: nowrap; }
    td.timestamp { font-family: 'IBM Plex Mono', monospace; color: var(--dim); white-space: nowrap; font-size: 0.78rem; }
    td.age { white-space: nowrap; }
    .age-str { color: var(--dim); font-size: 0.78rem; }

    td.missing { color: var(--stale); font-size: 0.76rem; padding: 10px; }
    td.empty   { color: var(--muted); font-size: 0.76rem; padding: 8px 10px; font-style: italic; }

    /* ── Badges ── */
    .badge {
      display: inline-block; padding: 2px 8px; border-radius: 3px;
      font-size: 0.63rem; font-family: 'IBM Plex Sans', sans-serif;
      font-weight: 600; letter-spacing: 0.03em; vertical-align: middle;
    }
    .badge.ok     { background: #e8f4ee; color: var(--ok);     border: 1px solid #b8d8c5; }
    .badge.warn   { background: #f7f0de; color: var(--warn);   border: 1px solid #dfc882; }
    .badge.aged   { background: #f7ede0; color: var(--aged);   border: 1px solid #ddb882; }
    .badge.stale  { background: #f5e8e8; color: var(--stale);  border: 1px solid #d8a8a8; }
    .badge.syncerr { background: #fff1f1; color: var(--stale); border: 1px solid #d8a8a8; font-style: italic; }
    .badge.static { background: #eeeeee; color: #7a7a7a;       border: 1px solid #d1d1d1; }

    /* ── Footer ── */
    footer {
      padding: 12px 24px;
      display: flex; justify-content: space-between; align-items: center;
      flex-wrap: wrap; gap: 8px;
      border-top: 1px solid var(--border);
      background: var(--panel);
    }
    .footer-note { font-size: 0.65rem; color: var(--muted); }
    .refresh-indicator { font-size: 0.65rem; color: var(--dim); display: flex; align-items: center; gap: 5px; }
    .pulse {
      width: 7px; height: 7px; border-radius: 50%;
      background: var(--accent2); opacity: 0.75;
      animation: pulse 2.5s ease-in-out infinite; flex-shrink: 0;
    }
    @keyframes pulse {
      0%, 100% { opacity: 0.75; transform: scale(1); }
      50%       { opacity: 0.3;  transform: scale(0.7); }
    }

    /* ── Mobile ── */
    @media (max-width: 600px) {
      header   { padding: 14px 16px 12px; flex-direction: column; align-items: flex-start; gap: 16px; }
      .header-right { text-align: left; align-items: flex-start; }
      .section { padding: 14px 16px; }
      .legend  { padding: 9px 16px; gap: 8px; }
      footer   { padding: 10px 16px; }
      .summary-item { padding: 10px 14px; }
      .summary-value { font-size: 1.05rem; }
      .section-path { display: none; }
      th.col-category,  td.category  { display: none; }
      th.col-timestamp, td.timestamp { display: none; }
      td.age { white-space: normal; }
      th, td { padding: 6px 8px; }


      .legend-label {
        flex-basis: 100%;
        min-width: auto;
        margin-bottom: -2px;
      }
    }
    @media (max-width: 380px) {
      .callsign { font-size: 1.15rem; }
      .clock    { font-size: 0.72rem; }
      .summary  { grid-template-columns: 1fr; }
      .summary-item:nth-child(2n)        { border-right: none; }
      .summary-item:nth-last-child(-n+2) { border-bottom: 1px solid var(--border); }
      .summary-item:last-child:nth-child(odd) { grid-column: auto; }
      .summary-item:last-child           { border-bottom: none; }
    }
  </style>
</head>
<body>

<header>
  <div class="header-left">
    <div class="callsign">${CALLSIGN}</div>
    <div class="subtitle">Data Product Status Board / ${VERSION}</div>
    <div class="subtitle" style="text-transform: none;">${HOST_HOSTNAME} (${PUBLIC_IP})</div>
    ${SYNC_SUBTITLE}
  </div>
  <div class="header-right">
    <div class="clock-label">Page generated</div>
    <div class="clock">${NOW} ${TZ_LABEL}</div>
    <div class="clock-label" style="margin-top:4px">Auto-refreshes every 5 min</div>
  </div>
</header>

<div class="summary">
  <div class="summary-item">
    <span class="summary-label">Dynamic Endpoints</span>
    <div class="summary-value">$(fmt_dyn_summary "$DYN_ACTIVE" "$DYN_IDLE" "$DYN_EMPTY" "$DYN_TIMEOUT" "$DYN_FAILED")</div>
  </div>
  <div class="summary-item">
    <span class="summary-label">Data Product Files</span>
    <div class="summary-value">$(fmt_stat_summary "$DATA_FRESH" "$DATA_RECENT" "$DATA_AGED" "$DATA_STALE" "$DATA_STATIC")</div>
  </div>
  <div class="summary-item">
    <span class="summary-label">SDO Files</span>
    <div class="summary-value">$(fmt_stat_summary "$SDO_FRESH" "$SDO_RECENT" "$SDO_AGED" "$SDO_STALE" "$SDO_STATIC")</div>
  </div>
  <div class="summary-item">
    <span class="summary-label">Map Files</span>
    <div class="summary-value">$(fmt_stat_summary "$MAP_FRESH" "$MAP_RECENT" "$MAP_AGED" "$MAP_STALE" "$MAP_STATIC")</div>
  </div>
  <div class="summary-item">
    <span class="summary-label">Unique HamClocks: 24h</span>
    <div class="summary-value">${DYN_COUNT_24H}</div>
  </div>
</div>

<div class="legend">
  <div class="legend-group">
    <span class="legend-label">DYNAMIC ENDPOINTS:</span>
    <div class="legend-item"><span class="badge ok">ACTIVE</span> data ok</div>
    <div class="legend-item"><span class="badge warn">EMPTY</span> no data</div>
    <div class="legend-item"><span class="badge static">IDLE</span> working/no spots</div>
    <div class="legend-item"><span class="badge aged">TIMEOUT</span> connection lost</div>
    <div class="legend-item"><span class="badge stale">FAILED</span> error</div>
  </div>
  <div class="legend-group">
    <span class="legend-label">FILES:</span>
    <div class="legend-item"><span class="badge ok">FRESH</span> updated</div>
    <div class="legend-item"><span class="badge warn">RECENT</span> late</div>
    <div class="legend-item"><span class="badge aged">AGED</span> old</div>
    <div class="legend-item"><span class="badge stale">STALE</span> stalled</div>
    <div class="legend-item"><span class="badge syncerr">SYNC_ERR</span> sync failed</div>
    <div class="legend-item"><span class="badge static">STATIC</span> baseline</div>
  </div>
</div>

<!-- Dynamic Endpoints -->
<div class="section">
  <div class="section-header">
    <div class="section-icon dynamic-icon"></div>
    <span class="section-title">Dynamic Endpoints</span>
    <span class="section-path">probe results from ${DYN_GENERATED:-never}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Endpoint</th>
        <th class="col-category">HTTP</th>
        <th class="col-timestamp">Latency</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
$(build_dynamic_rows)
    </tbody>
  </table>
</div>

<!-- Data Products -->
<div class="section">
  <div class="section-header">
    <div class="section-icon"></div>
    <span class="section-title">Data Products</span>
    <span class="section-path">${DATA_DIR}/{Bz,NOAASpaceWX,ONTA,aurora,contests,cty,drap,dst,dxpeds,esats,geomag,solar-flux,solar-wind,ssn,worldwx,xray}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Filename</th>
        <th class="col-category">Category</th>
        <th class="col-timestamp">Last Modified (UTC)</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
HTML_HEAD

build_data_rows

cat << HTML_SDO
    </tbody>
  </table>
</div>

<!-- SDO -->
<div class="section">
  <div class="section-header">
    <div class="section-icon sdo-icon"></div>
    <span class="section-title">SDO</span>
    <span class="section-path">${SDO_DIR}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Filename</th>
        <th class="col-category">Category</th>
        <th class="col-timestamp">Last Modified (UTC)</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
HTML_SDO

build_rows "$SDO_DIR" "SDO"

cat << HTML_MAPS
    </tbody>
  </table>
</div>

<!-- Maps -->
<div class="section">
  <div class="section-header">
    <div class="section-icon maps-icon"></div>
    <span class="section-title">Maps</span>
    <span class="section-path">${MAPS_DIR}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Filename</th>
        <th class="col-category">Category</th>
        <th class="col-timestamp">Last Modified (UTC)</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
HTML_MAPS

build_rows "$MAPS_DIR" "map"

cat << HTML_FOOT
    </tbody>
  </table>
</div>

<footer>
  <div class="footer-note">73 · ${CALLSIGN} · Generated by generate_status_json.sh / ${VERSION}</div>
  <div class="refresh-indicator">
    <div class="pulse"></div>
    Auto-refresh active · every 5 minutes
  </div>
</footer>

</body>
</html>
HTML_FOOT

} > "$OUTPUT"

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Status board written to ${OUTPUT}"

build_json
echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] JSON status written  to ${OUTPUT_JSON}"
