#!/bin/bash
# Usage: ./cron-wrapper.sh [--notnice] VAR=val /path/to/bin /path/to/script.py

# 1. Handle optional flag first and clean it from arguments
CMD_PREFIX=()
if [ "$1" = "--notnice" ]; then
    shift
else
    # Store prefix as an array to safely handle spaces
    CMD_PREFIX=(nice -n 19 ionice -c 2 -n 7)
fi

# 2. Identify the last argument to use as the log filename
FOR_NAME="${@: -1}"
SCRIPT_NAME=$(basename "$FOR_NAME" | sed 's/\.[^.]*$//')
LOG_DIR="/opt/hamclock-backend/logs"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}.log"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

mkdir -p "$LOG_DIR"

# 3. Locking Mechanism
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $SCRIPT_NAME is already running. Exiting." >> "$LOG_FILE"
    exit 1
fi

# 4. Execution with full arguments
START_TIME=$(date +%s)
echo "------------------------------------------------------------" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] START: $*" >> "$LOG_FILE"

# Use 'env' to guarantee that inline assignments (like VAR=val) are processed 
# correctly regardless of whether nice/ionice prefixes them. 
# We wrap "$@" in the execution to preserve spaces and arguments safely without eval.
"${CMD_PREFIX[@]}" env "$@" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?

# 5. Metrics
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo "[$(date '+%Y-%m-%d %H:%M:%S')] END: Exit Code $EXIT_CODE" >> "$LOG_FILE"
echo "DURATION: ${DURATION} seconds" >> "$LOG_FILE"
echo "------------------------------------------------------------" >> "$LOG_FILE"
