#!/bin/bash

# Usage: ./cron-wrapper.sh VAR=val /path/to/bin /path/to/script.py

# 1. Identify the last argument to use as the log filename
# This ensures "update_world_wx.py" becomes "update_world_wx.log"
FOR_NAME="${@: -1}"
SCRIPT_NAME=$(basename "$FOR_NAME" | sed 's/\.[^.]*$//') # Removes .sh, .py, etc.

LOG_DIR="/opt/hamclock-backend/logs"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}.log"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

mkdir -p "$LOG_DIR"

# 2. Locking Mechanism
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $SCRIPT_NAME is already running. Exiting." >> "$LOG_FILE"
    exit 1
fi

# 3. Execution with full arguments
START_TIME=$(date +%s)
echo "------------------------------------------------------------" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] START: $@" >> "$LOG_FILE"

# "$@" passes every argument exactly as received (env vars, python path, etc.)
eval "$@" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?

# 4. Metrics
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "[$(date '+%Y-%m-%d %H:%M:%S')] END: Exit Code $EXIT_CODE" >> "$LOG_FILE"
echo "DURATION: ${DURATION} seconds" >> "$LOG_FILE"
echo "------------------------------------------------------------" >> "$LOG_FILE"
