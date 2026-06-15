#!/bin/bash

THIS=$(basename $0)
TMPFILE=$(mktemp /opt/hamclock-backend/cache/$THIS-XXXXX)

# URL and Paths
URL="https://services.swpc.noaa.gov/text/drap_global_frequencies.txt"
OUTPUT="/opt/hamclock-backend/htdocs/ham/HamClock/drap/stats.txt"
LAST_DATE_FILE="/opt/hamclock-backend/cache/last_valid_date.txt"

# 1. Fetch the data into a variable to avoid multiple downloads
RAW_DATA=$(curl -s "$URL")

# 2. Extract the "Product Valid At" line
# Example line: # Product Valid At : 2026-02-03 23:01 UTC
CURRENT_VALID_DATE=$(echo "$RAW_DATA" | grep "Product Valid At" | cut -d':' -f2- | xargs)

echo "INFO: Product Valid At $CURRENT_VALID_DATE"

# 3. Check if we've already processed this timestamp
if [ -f "$LAST_DATE_FILE" ]; then
    LAST_VALID_DATE=$(cat "$LAST_DATE_FILE")
    if [ "$CURRENT_VALID_DATE" == "$LAST_VALID_DATE" ]; then
        # NOAA feed is frozen - append a heartbeat row with current wall clock
        # time and last known values to keep HamClock's staleness check happy.
        # This prevents HC from showing DRAP invalid during a NOAA outage.
        # We only do this if the output file already exists with real data.
        echo "WARN: NOAA DRAP data frozen!"
        if [ -e "$OUTPUT" ]; then
            echo "WARN: Appending last known good row..." 
            LAST_ROW=$(tail -n 1 "$OUTPUT")
            LAST_VALS=$(echo "$LAST_ROW" | cut -d' ' -f2-)
            NOW=$(date +%s)
            HEARTBEAT_ROW="$NOW $LAST_VALS"
            tail -n 439 "$OUTPUT" > "$TMPFILE"
            echo "$HEARTBEAT_ROW" >> "$TMPFILE"
            cp "$TMPFILE" "$OUTPUT"
        fi
        rm -f "$TMPFILE"
        exit 0
    fi
fi

# 4. Process the file using awk
EPOCH=$(date +%s)
NEW_ROW=$(
echo "$RAW_DATA" | awk -v now="$EPOCH" -F'|' '
NF > 1 {
    split($2, values, " ")
    for (i in values) {
        val = values[i]
        if (!initialized) {
            min = max = sum = val
            count = 1
            initialized = 1
            continue
        }
        if (val < min) min = val
        if (val > max) max = val
        sum += val
        count++
    }
}
END {
    if (count > 0) {
        printf "%s : %g %g %.5f\n", now, min, max, sum / count
    }
}')

# sanitize NEW_ROW to a single non-empty line (prevents accidental blank lines / CRs)
NEW_ROW="$(printf '%s' "$NEW_ROW" | tr -d '\r' | awk 'NF{print; exit}')"

# optional but recommended: fail fast if sanitize leaves it empty
[ -n "$NEW_ROW" ] || { echo "ERROR: NEW_ROW empty after sanitize" >&2; rm -f "$TMPFILE"; exit 1; }

# 5. Save the new timestamp
echo "$CURRENT_VALID_DATE" > "$LAST_DATE_FILE"

# 6. Save and trim the log
#
# If this is a fresh install we won't have the history. Bootstrap by walking
# backwards every 5 minutes from now using the first real values we have.
# This gives HC a plausible-looking history until real data fills in.
if [ -e "$OUTPUT" ]; then
    echo "INFO: DRAP stats.txt already exists... appending new row to file."
    # Keep last 439 lines and append the new real row
    tail -n 439 "$OUTPUT" > "$TMPFILE"
    echo "$NEW_ROW" >> "$TMPFILE"
else
    echo "INFO: DRAP stats.txt does not exist... seeding with 440 backdated rows at 5 min intervals."
    # File doesn't exist yet - seed with 440 backdated rows at 5 min intervals
    EPOCH_TIME=$(echo $NEW_ROW | cut -d " " -f 1)
    ROW_TAIL=$(echo $NEW_ROW | cut -d " " -f 2-)
    for i in {0..439}; do
        echo "$(($EPOCH_TIME - 5 * 60 * $i)) $ROW_TAIL" >> "$TMPFILE"
    done
    sort -V -o $TMPFILE $TMPFILE
fi

cp "$TMPFILE" "$OUTPUT"
rm -f "$TMPFILE"
