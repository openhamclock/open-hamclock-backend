#!/bin/bash

# These are files that should be cleaned only one time. The docker volume container persists
# files basically forever. We need a maintenance mechanism. Possible uses are:
#   - old files that are no longer used
#   - cache or data files that need to be cleared out once upon upgrade, usually for fixing a bug
#
# After the files list is run, it is cleared out so that it doesn't run again. This is especially 
# required for clearing data on upgrade. We don't want to clear the data on every restart, just
# one time.
#
# The files are relative to a root of /opt/hamclock-backend/htdocs/state/ which is the docker-mounted volume

THIS=$(basename $0)
HERE="$(cd "$(dirname "$0")" && pwd)"
DVC_MOUNT=/opt/hamclock-backend/htdocs
STOCK_FILES_LIST=$HERE/${THIS%.*}.txt
FILES_LIST=$DVC_MOUNT/state/${THIS%.*}.txt
GIT_VERSION_FILE=/opt/hamclock-backend/git.version

# Only do something if the file exists in this image
[[ ! -r "$STOCK_FILES_LIST" ]] && exit 0

# Only do something if the file wasn't already run and marked
# by the image version
if cmp --silent "$FILES_LIST" "$GIT_VERSION_FILE"; then
    echo "One-time clean was done previously."
    exit
fi

# we have a files list and it wasn't already run from this image
cp "$STOCK_FILES_LIST" "$FILES_LIST"

while IFS= read -r file; do
    if [ -d "$DVC_MOUNT/$file" ]; then
        # remove only the directory contents if it ends in slash
        if [[ "$DVC_MOUNT/$file" == */ ]]; then
            echo "$THIS: Removing contents of directory: $DVC_MOUNT/$file"
	        rmdir "$DVC_MOUNT/$file/*"
        else
            echo "$THIS: Removing directory: $DVC_MOUNT/$file"
	        rmdir "$DVC_MOUNT/$file"
        fi
    elif [ -f "$DVC_MOUNT/$file" ]; then
        echo "$THIS: Deleting file: $DVC_MOUNT/$file"
	    rm -f "$DVC_MOUNT/$file"
    else
        echo "$THIS: No such file or directory: $DVC_MOUNT/$file"
    fi
done < <(grep -vE '^(\s*#|\s*$)' "$FILES_LIST" | tr -d '\r')

# mark the file as from this image and having been run already.
cp "$GIT_VERSION_FILE" "$FILES_LIST"
