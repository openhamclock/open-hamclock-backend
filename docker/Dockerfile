#######################################################
# Multi-stage build
#######################################################

#######################################################
# build support artifacts
#######################################################
FROM debian:13.4-slim AS build-support

USER root
WORKDIR /opt

# Install build prerequisites
COPY docker/package-list-support.txt /opt
COPY docker/ohb-maps.tar.zst /opt

# Build support artifacts: untar maps
RUN apt update && \
    apt install -y --no-install-recommends $(grep -v '^#' package-list-support.txt) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /opt/package-list-support.txt && \
    # \
    # untar the maps so we don't get the tgz in the layers \
    mkdir -p ohb-maps && \
    tar -x --zstd -f ohb-maps.tar.zst -C ohb-maps --strip-components=1 maps/ && \
    rm -Rf ohb-maps.tar.zst

RUN pip install --break-system-packages global-land-mask global_land_mask

#######################################################
# Build the real image
#######################################################
FROM debian:13.4-slim

USER root
WORKDIR /opt

COPY docker/package-list.txt /opt

# Install prerequisites
RUN apt update && \
    apt install -y --no-install-recommends $(grep -v '^#' package-list.txt) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /opt/package-list.txt

ARG GIT_VERSION

# the OHB tree
COPY --from=build-support /opt/ohb-maps /opt/hamclock-backend/ham/HamClock/maps

# some setup
RUN cd /opt/hamclock-backend && \
    # \
    # make directory structure \
    mkdir -p \
        tmp \
        logs \
        cache \
        data \
        htdocs && \
    # \
    echo $GIT_VERSION > git.version && \
    # \
    openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
        -keyout /etc/lighttpd/server.pem -out /etc/lighttpd/server.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/OU=IT/CN=localhost"

# Install hamclock-backend
COPY --exclude=**/__pycache__/ --exclude=**/__init__.py --from=build-support /usr/local/lib/python3.13/dist-packages/ /usr/local/lib/python3.13/dist-packages/
COPY --exclude=docker/ohb-maps.tar.zst . /opt/hamclock-backend/
RUN cd /opt/hamclock-backend && \
    mv  docker/run.sh /opt && \
    mv  docker/one-time-clean.sh /opt && \
    mv  docker/one-time-clean.txt /opt && \
    sed -i "s/^\(OHB_MANAGER_VERSION=\).*$/\1$(cat git.version)/" docker/manage-ohb-docker.sh && \
    # \
    # cron is tightly coupled to the type of python install. cron is written for pyenv. however \
    # when there is no pip or pyenv, python runs from /usr. \
    sed -i 's|^VENV=.*|VENV=/usr|' scripts/crontab && \
    # \
    # This crazy line takes the crontab file, removes the stderr redirect and adds echos to track progress. \
    # It generates a file that will be run only once on a fresh install \
    awk '/^[0-9\*]/ {full=$0; $1=$2=$3=$4=$5=""; sub(/^[ \t]+/, "", $0); exec=$0; sub(/[[:space:]]*[>|].*$/, "", exec); print "echo \"Running: " exec "\""; print $0; next} {print}' scripts/crontab | sed 's/[[:space:]]*2>&1//g' > prime_crontabs.sh && \
    # \
    # set permissions \
    chown -R www-data:www-data . && \
    chmod +x ham/HamClock/*.pl \
             scripts/* \
             prime_crontabs.sh \
             /opt/run.sh \
             /opt/one-time-clean.sh \
             /opt/hamclock-backend/lighttpd-conf/env-gen.sh \
             && \
    # \
    # fontconfig needs a writeable cache directory \
    mkdir -p /var/www/.fontconfig && \
    chown -R www-data:www-data /var/www/.fontconfig && \
    # \
    # set up cron \
    mv scripts/crontab /var/spool/cron/crontabs/www-data && \
    chown www-data:crontab /var/spool/cron/crontabs/www-data && \
    chmod 600 /var/spool/cron/crontabs/www-data && \
    # \
    # set up logrotate \
    mv logrotate/ohb.logrotate /etc/logrotate.d/ohb && \
    mv logrotate/lighttpd.logrotate /etc/logrotate.d/lighttpd && \
    chown root:root /etc/logrotate.d/ohb /etc/logrotate.d/lighttpd && \
    # I like dates in the rotated filenames \
    sed -i 's/^#dateext/dateext/' /etc/logrotate.conf && \
    # \
    # set up lighttpd \
    cp lighttpd-conf/*.conf /etc/lighttpd/conf-available/ && \
    /usr/sbin/lighty-disable-mod javascript-alias && \
    /usr/sbin/lighty-enable-mod accesslog && \
    /usr/sbin/lighttpd-enable-mod hamclock && \
    /usr/sbin/lighttpd-enable-mod voacap-cgi-timeouts && \
    /usr/sbin/lighttpd-enable-mod hc-firmware && \
    /usr/sbin/lighttpd-enable-mod sdo-movies && \
    /usr/sbin/lighttpd-enable-mod hc-diag && \
    /usr/sbin/lighttpd-enable-mod proxy-alpha && \
    /usr/sbin/lighttpd-enable-mod ssl && \
    # \
    # ImageMagick policy parameters need to be increased \
    sed -i 's/name="memory" value="[^"]*"/name="memory" value="2GiB"/' /etc/ImageMagick-?/policy.xml && \
    sed -i 's/name="disk" value="[^"]*"/name="disk" value="8GiB"/' /etc/ImageMagick-?/policy.xml

# let's rock!
CMD ["/opt/run.sh"]
