#!/bin/bash

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

echo "This image is based on git: '$(cat hamclock-backend/git.version)'"
echo "Start up time: $(date -u +%H:%M:%S)"

# capture any env vars for cron, etc
printenv | grep ^HOST_HOSTNAME >> /etc/environment 

echo "Preparing for pskr ..."
mkdir -p /opt/hamclock-backend/htdocs/pskr
chown $PSKR_UID /opt/hamclock-backend/htdocs/pskr

# migrating to a new home
mkdir -p /opt/hamclock-backend/htdocs/state
if [ -e /opt/hamclock-backend/htdocs/prime_crontabs.done ]; then
    mv /opt/hamclock-backend/htdocs/prime_crontabs.done /opt/hamclock-backend/htdocs/state
fi

echo "Syncing the initial, static directory structure ..."
mkdir -p /opt/hamclock-backend/htdocs/ham
cp -a /opt/hamclock-backend/ham/HamClock /opt/hamclock-backend/htdocs/ham

if [ -n "$MAP_SIZES" ]; then
    echo "Limit map sizes to support screen size: '$MAP_SIZES'"
    cp \
        /opt/hamclock-backend/scripts/"map_sizes-$MAP_SIZES.txt" \
        /opt/hamclock-backend/scripts/map_sizes.txt
fi

echo Installing root folder ...
# remove traces of old, obsolete dashboard
find /opt/hamclock-backend/htdocs -maxdepth 1 -type f -exec rm -f "{}" +
cp /opt/hamclock-backend/ham/favicon.ico /opt/hamclock-backend/htdocs
cp /opt/hamclock-backend/ham/favicon.svg /opt/hamclock-backend/htdocs
cp /opt/hamclock-backend/ham/robots.txt /opt/hamclock-backend/htdocs
cp /opt/hamclock-backend/ham/index.html /opt/hamclock-backend/htdocs/index.html
cp /opt/hamclock-backend/docker/manage-ohb-docker.sh /opt/hamclock-backend/htdocs/

# start the web server
echo "Starting lighttpd ..."
/usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf

# only needs to be primed when docker volume container is instantiated
if [ ! -e /opt/hamclock-backend/htdocs/state/prime_crontabs.done ]; then
    echo "Running OHB for the first time."

    echo "Priming the data set ..."
    /usr/sbin/runuser -u www-data /opt/hamclock-backend/prime_crontabs.sh

    touch /opt/hamclock-backend/htdocs/state/prime_crontabs.done
    echo "Done! OHB data has been primed."

    LAST_TIME_EPOCH=$(date -u +%s)
else
    echo "OHB was previously installed and does not need to be primed."

    echo "Running the one-time-clean script"
    /opt/one-time-clean.sh

    LAST_TIME_EPOCH=$(find /opt/hamclock-backend/htdocs -type f -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d. -f1)
    echo "Last running timestamp found is: '$(date -ud @$LAST_TIME_EPOCH)'"
fi

echo $LAST_TIME_EPOCH > /opt/last-ts-running.txt
echo $(date -u +%s) > /opt/started-running.txt

# start cron
echo "Starting cron ..."
/usr/sbin/cron

echo "Starting blitzortung ..."
(
    while true; do
        /opt/hamclock-backend/scripts/blitzortung_daemon.py
        echo "$(date -u +%H:%M:%S): Blizortung stopped. Restarting in 5 seconds ..."
        sleep 5
    done
)&

echo "OHB is running and ready to use at: $(date -u +%H:%M:%S)"

# this extra work causes the container to stop quickly. We need to 
# kill our own jobs or bash will zombie and then docker takes 10 seconds
# before it sends kill -9. The wait will respond to a TERM whereas 
# tail does not so we need to background tail.
cleanup() {
    echo "Caught SIGTERM, shutting down services..."
    kill $(jobs -p)
    exit 0
}

# Trap the TERM signal
trap cleanup SIGTERM

# hold the script to keep the container running
tail --pid=$(pidof cron) -f /dev/null &
wait $!
