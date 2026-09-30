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

# always be sure logrotate has been primed
wrapper /etc/cron.daily/logrotate

# reload fw files
runuser_wrapper $SCRIPTS/update_versions.pl

# reload rss cache
runuser_wrapper $SCRIPTS/web15rss_fetch.py

#############################################

#############################################
# things to run in this release
#############################################
/bin/true # example

# new scripts to prime

#############################################
