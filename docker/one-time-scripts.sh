#!/bin/bash

#############################################
# list of scripts to be run upon start of a fresh container. script gets used
# once per image based on the /opt/hamclock-backend/git.version value.
#
# Be sure to reset this file for each release.
#
# It's recommended to use "wrapper" to call scripts so that logging occurs
# and "runuser_wrapper" to call scripts as the container user and logging.
#############################################
THIS=$(basename $0)
SCRIPTS=/opt/hamclock-backend/scripts

# use cron wrapper for logging
wrapper() {
    echo "$THIS: Running: '$@'"
    "$@"
}

runuser_wrapper() {
    WRAPPER=$SCRIPTS/cron-wrapper.sh
    export -f wrapper
    export THIS
    runuser -u www-data -- bash -c 'wrapper "$1" "${@:2}"' _ "$WRAPPER" "$@"
}

#############################################
# pretty much keep these as standard:
#############################################
# always be sure logrotate has been primed
wrapper /etc/cron.daily/logrotate

# reload fw files
runuser_wrapper $SCRIPTS/update_versions.pl

# reload caches
runuser_wrapper $SCRIPTS/web15rss_fetch.py
runuser_wrapper $SCRIPTS/gen_solarflux-history.sh
runuser_wrapper $SCRIPTS/gen_ssn_history.pl
runuser_wrapper $SCRIPTS/gen_contest-calendar.sh
runuser_wrapper /usr/bin/python3 $SCRIPTS/fetch_IOTA.py
runuser_wrapper /usr/bin/python3 $SCRIPTS/gen_dxpeditions_spots.py
runuser_wrapper $SCRIPTS/fetch_tle.sh
runuser_wrapper $SCRIPTS/fetch_sat_freq.sh
runuser_wrapper $SCRIPTS/fetch_cyclones.py

#############################################

#############################################
# things to run in this release
#############################################
/bin/true # example

# new scripts to prime

#############################################
