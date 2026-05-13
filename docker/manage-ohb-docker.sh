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

# at release time, this value is set to the tagged release
OHB_MANAGER_VERSION=latest
# tags to use
VOACAP_SERVICE_TAG=latest
PSKR_MQTT_CACHE_TAG=1.12

GITHUB_LATEST_RELEASE_URL="https://api.github.com/repos/komacke/open-hamclock-backend/releases/latest"
OHB_HTDOCS_DVC=ohb-htdocs
IMAGE_BASE=komacke/open-hamclock-backend

# Get our directory locations in order
HERE="$(cd "$(dirname "$0")" && pwd)"
THIS="$(basename "$0")"
STARTED_FROM="$PWD"
cd $HERE

DOCKER_PROJECT="${THIS%.sh}"
DOCKER_PROJECT="${DOCKER_PROJECT%-$OHB_MANAGER_VERSION}"
DEFAULT_TAG=$OHB_MANAGER_VERSION
GIT_TAG=$(git describe --exact-match --tags 2>/dev/null)
GIT_VERSION=$(git rev-parse --short HEAD 2>/dev/null)
CONTAINER=${IMAGE_BASE##*/}
VC_ALONE_CONTAINER=voacap-service-standalone
DEFAULT_HTTP_PORT=:80
DEFAULT_HTTPS_PORT=-
DEFAULT_CERT_PATH=-
DEFAULT_EXTERNAL_HTTP_LOG=false
# the following env is the lighttpd env file
DEFAULT_ENV_FILE="$STARTED_FROM/.env"
DEFAULT_MAP_SIZES=all
DEFAULT_VOACAP_SERVICE_HOST=voacap-service:8080
DEFAULT_ALPHA_INSTALL=false

# the following env is for sticky settings
STICKY_ENV_FILE=$DOCKER_PROJECT.env
REQUEST_DOCKER_PULL=false
RETVAL=0

SUPPORTED_MAP_SIZES=(
    all
    1600x960
    3200x1920
    2400x1440
    800x480
)

main() {
    get_sticky_vars

    COMMAND=$1
    case $COMMAND in
        -h|--help|help)
            usage
            ;;
        -v|--version|version)
            ohb_manager_version
            ;;
        check-docker)
            is_docker_installed
            ;;
        check-ohb-install)
            is_ohb_installed
            ;;
        install)
            shift && get_compose_opts "$@"
            install_ohb
            ;;
        upgrade)
            shift && get_compose_opts "$@"
            upgrade_ohb
            ;;
        full-reset)
            shift && get_compose_opts "$@"
            recreate_ohb
            ;;
        reset)
            shift && get_compose_opts "$@"
            docker_compose_reset
            ;;
        restart)
            docker_compose_restart
            ;;
        remove)
            remove_ohb
            ;;
        up)
            if [ "$2" == voacap-service ]; then
                REQUESTED_PROJECT=$2
                SAVE_STICKY_VARS=false
                shift
            elif [ "$1" == ohb ]; then
                REQUESTED_PROJECT=$2
                shift
            else
                REQUESTED_PROJECT=ohb
            fi
            shift && get_compose_opts "$@"
            if [ $REQUESTED_PROJECT == voacap-service ]; then
                docker_compose_up_voacap_service
            else
                docker_compose_up
            fi
            ;;
        down)
            if [ "$2" == voacap-service ]; then
                REQUESTED_PROJECT=$2
                SAVE_STICKY_VARS=false
                shift
            elif [ "$1" == ohb ]; then
                REQUESTED_PROJECT=$2
                shift
            else
                REQUESTED_PROJECT=ohb
            fi
            if [ $REQUESTED_PROJECT == voacap-service ]; then
                docker_compose_down_voacap_service
            else
                docker_compose_down
            fi
            ;;
        generate-docker-compose)
            if [ "$2" == voacap-service ]; then
                REQUESTED_PROJECT=$2
                SAVE_STICKY_VARS=false
                shift
            elif [ "$2" == ohb ]; then
                REQUESTED_PROJECT=$2
                shift
            else
                REQUESTED_PROJECT=ohb
            fi
            shift && get_compose_opts "$@"
            generate_docker_compose $REQUESTED_PROJECT
            ;;
        add-env-file)
            shift && get_compose_opts "$@"
            copy_env_to_container
            ;;
        upgrade-me)
            upgrade_this_script
            ;;
        *)
            echo "Invalid or missing option. Try using '$THIS help'."
            exit 1
            ;;
    esac

    if [[ "$SAVE_STICKY_VARS" == "true" && $RETVAL -eq 0 ]]; then
        save_sticky_vars
    fi
}

get_compose_opts() {
    while getopts ":ac:e:l:p:r:s:t:v:" opt; do
        case $opt in
            a)
                REQUESTED_ALPHA_INSTALL=true
                ;;
            c)
                REQUESTED_CERT_PATH="$OPTARG"
                ;;
            e)
                REQUESTED_ENV_FILE="$OPTARG"
                ;;
            l)
                REQUESTED_EXTERNAL_HTTP_LOG="$OPTARG"
                if [[ "$REQUESTED_EXTERNAL_HTTP_LOG" != "true" && "$REQUESTED_EXTERNAL_HTTP_LOG" != "false" ]]; then
                    echo "ERROR: -$opt option must be <true|false>"
                    exit 1
                fi
                ;;
            r)
                REQUESTED_MAP_SIZES="${OPTARG,,}"
                if [[ ! " ${SUPPORTED_MAP_SIZES[*]} " =~ " ${REQUESTED_MAP_SIZES} " ]]; then
                    echo "ERROR: -$opt option must be one of:"
                    printf '    %s\n' "${SUPPORTED_MAP_SIZES[@]}"
                    exit 1
                fi
                ;;
            p)
                REQUESTED_HTTP_PORT="$OPTARG"
                ;;
            s)
                REQUESTED_HTTPS_PORT="$OPTARG"
                ;;
            t)
                REQUESTED_TAG="$OPTARG"
                ;;
            v)
                REQUESTED_VOACAP_SERVICE_HOST="$OPTARG"
                ;;

            \?) # Handle invalid options
                echo "Command '$COMMAND': Invalid option: -$OPTARG" >&2
                exit 1
                ;;
            :) # Handle options requiring an argument but none provided
                echo "Command '$COMMAND': Option -$OPTARG requires an argument." >&2
                exit 1
                ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ -n "$1" ]; then
        echo "Command '$COMMAND': Invalid option(s): $@" >&2
        exit 1
    fi

    [ -z "$SAVE_STICKY_VARS" ] && SAVE_STICKY_VARS=true
}

usage () {
    cat<<EOF
$THIS <COMMAND> [options]:
    help: 
            This message

    check-docker:
            checks docker requirements and shows version

    check-ohb-install:
            checkif OHB is installed and report versions

    install
            do a fresh install

    upgrade
            upgrade ohb; defaults to current git tag if there is one. Otherwise you can provide one.

    full-reset
            clear out all data and start fresh

    reset:
            resets the OHB container to new but does not reset the persistent storage

    restart:
            restarts the OHB container. No file contents modified

    up [ohb|voacap-service] (default: ohb)
            start an existing

    down [ohb|voacap-service] (default: ohb)
            stop a running install

    remove: 
            stop and remove the docker container, docker storage and docker image

    add-env-file [-e <env file>]:
            add .env to OHB. Defaults a file named '.env' in your PWD. The
            .env file contains secrets such as api keys for services. If OHB
            was already running, it needs to be restarted for the file
            to take effect. See the restart command. See .env.example for more info.
            -e: .env file location

    generate-docker-compose [ohb|voacap-service] (default: ohb)
            writes the docker compose file to STDOUT

    upgrade-me:
            downloads the latest tagged version of itself and overwrites itself. Runs
            the new version to confirm it worked. Does an sha256 validation before
            overwriting itself.

The following arguments come after the command:
            -p: <port>
                ohb: set the HTTP port (default: 80 or to current setting)
                voacap-service: set the voacap-service port (default: 8080)
            -t: <image tag>
            -r: screen res limits number of maps generated: '${SUPPORTED_MAP_SIZES[*]}'
            -v: set voacap-service server host:port in ohb

EOF
}

ohb_manager_version() {
    echo $OHB_MANAGER_VERSION
}

get_sticky_vars() {
    if [ -r $STICKY_ENV_FILE ]; then
        source $STICKY_ENV_FILE
    fi
}

save_sticky_vars() {
    cat<<EOF > $STICKY_ENV_FILE
STICKY_HTTP_PORT="$HTTP_PORT"
STICKY_HTTPS_PORT="$HTTPS_PORT"
STICKY_LIGHTTPD_ENV_FILE="$ENV_FILE"
STICKY_EXTERNAL_HTTP_LOG="$ENABLE_EXTERNAL_HTTP_LOG"
STICKY_CERT_PATH="$CERT_PATH"
STICKY_MAP_SIZES="$MAP_SIZES"
STICKY_VOACAP_SERVICE_HOST="$VOACAP_SERVICE_HOST"
STICK_ALPHA_INSTALL="$ALPHA_INSTALL"
EOF
}

upgrade_this_script() {
    CHECK_LATEST_JSON=$(curl -s "$GITHUB_LATEST_RELEASE_URL")

    URL_LATEST_THIS=$(echo "$CHECK_LATEST_JSON" | jq -r ".assets[] | select(.browser_download_url | contains(\"$DOCKER_PROJECT\")) | .browser_download_url")
    DIGEST_LATEST_THIS=$(echo "$CHECK_LATEST_JSON" | jq -r ".assets[] | select(.browser_download_url | contains(\"$DOCKER_PROJECT\")) | .digest")

    URL_LATEST_RELEASE=$(echo "$CHECK_LATEST_JSON" | jq -r '.html_url')
    AVAILABLE_VERSION=$(basename "$URL_LATEST_RELEASE")

    if [ "$AVAILABLE_VERSION" == "$OHB_MANAGER_VERSION" ]; then
        echo "$THIS is currently the latest version: '$OHB_MANAGER_VERSION'"
        return $RETVAL
    fi
    cat <<EOF
There is a new version: '$AVAILABLE_VERSION'. The version you have is '$OHB_MANAGER_VERSION'.

Source and release notes can be found at this URL:

  $URL_LATEST_RELEASE

Would you like to download the latest version of $THIS and overwrite your current copy?
EOF

    DEFAULT_DOIT=y
    read -p "Overwrite? [Y/n]: " DOIT
    DOIT=${DOIT:-$DEFAULT_DOIT}

    echo
    if [ "${DOIT,,}" == y ]; then
        echo "Getting new version ..."
        TMP_MGR_FILE=$(mktemp -p ./)
        curl -sLo $TMP_MGR_FILE $URL_LATEST_THIS
        chmod --reference=$THIS $TMP_MGR_FILE

        DIGEST_FILE=sha256:$(sha256sum $TMP_MGR_FILE | cut -d ' ' -f1)
        if [ "$DIGEST_FILE" == "$DIGEST_LATEST_THIS" ]; then
            echo "Successfully downloaded new version. Let's run it and check its version:"
            echo
            echo "$ ./$THIS"
            mv $TMP_MGR_FILE $THIS
            exec "./$THIS" version
        else
            echo
            echo "ERROR: downloaded file '$TMP_MGR_FILE' seems to be corrupted. Not using it."
            echo "  Expected: '$DIGEST_LATEST_THIS'"
            echo "  Got:      '$DIGEST_FILE'"
            RETVAL=1
        fi
    else
        echo "Because you answered '$DOIT', we won't upgrade and overwrite. 'Y' or 'y' will do the upgrade."
    fi
}

install_ohb() {
    is_docker_installed >/dev/null || return $?
    is_dvc_created || return $?

    echo "Installing OHB ..."

    echo "Creeating persistent storage ..."
    if create_dvc; then
        echo "Persistent storage created successfully."
    else
        echo "ERROR: failed to create persistence storage." >&2
        return $RETVAL
    fi

    echo "Starting the container ..."
    if docker_compose_up; then
        echo "Container started successfully."
    else
        echo "ERROR: failed to start OHB with docker compose up" >&2
        return $RETVAL
    fi
    return $RETVAL
}

is_ohb_installed() {
    echo "$THIS version: '$OHB_MANAGER_VERSION'"

    echo
    echo "Checking for OHB source code from git ..."
    if [ -n "$GIT_VERSION" ]; then
        if [ -n "$GIT_TAG" ]; then
            echo "  release: '$GIT_TAG'"
        elif [ -n "$GIT_VERSION" ]; then
            echo "  git hash: '$GIT_VERSION'"
        fi
    else
        echo "  git checkout not found."
    fi
    TAG_FROM_GIT=$(curl -s --connect-timeout 2 "$GITHUB_LATEST_RELEASE_URL" | jq -r '.tag_name // ""')
    echo "  Latest release available from GitHub: '$TAG_FROM_GIT'"

    echo
    echo "Checking for docker ..."
    if ! is_docker_installed | sed 's/^/  /'; then
        RETVAL=1
        return $RETVAL
    fi
    echo

    echo "Checking for OHB ..."
    if is_dvc_exists; then
        echo "  OHB persistent storage found."
    else
        echo "OHB does not appear to be installed."
        RETVAL=1
        return $RETVAL
    fi

    get_current_image_tag
    if [ -z "$CURRENT_TAG" ]; then
        echo
        echo "OHB does not appear to be running. Try running '$THIS up'"
        RETVAL=1
        return $RETVAL
    else
        get_current_http_port
        get_current_https_port
        get_current_pskr_image_tag
        get_current_voacap_image_tag
        echo "  OHB version:           '$CURRENT_TAG'"
        echo "  Docker image:          '$CURRENT_IMAGE_BASE:$CURRENT_TAG'"
        echo "  Docker image (pskr):   '$CURRENT_PSKR_IMAGE_BASE:$CURRENT_PSKR_TAG'"
        echo "  Docker image (voacap): '$CURRENT_VOACAP_IMAGE_BASE:$CURRENT_VOACAP_TAG'"
        echo "  HTTP PORT in use:      '$CURRENT_HTTP_PORT'"
        if [ -n "$CURRENT_HTTPS_PORT" ]; then
            echo "  HTTPS PORT in use:     '$CURRENT_HTTPS_PORT'"
        fi
        if [ "$STICKY_CERT_PATH" != "-" ]; then
            echo "  HTTPS cert path:       '$STICKY_CERT_PATH'"
        fi
    fi

    if ! is_container_running; then
        echo
        echo "OHB appears to be in a failed state. Try '$THIS up' and look for docker errors."
    fi
}

upgrade_ohb() {
    is_docker_installed >/dev/null || return $?

    get_current_http_port
    get_current_https_port
    get_current_image_tag

    echo "Upgrading OHB ..."

    REQUEST_DOCKER_PULL=true
    echo "Starting the container ..."
    if docker_compose_up; then
        echo "Container started successfully."
    else
        echo "ERROR: failed to start OHB with docker compose up"
        return $RETVAL
    fi
    return $RETVAL
}

is_docker_installed() {
    DOCKERD_VERSION=$(docker -v 2>/dev/null)
    DOCKERD_RETVAL=$?
    DOCKER_COMPOSE_VERSION=$(docker compose version 2>/dev/null)
    DOCKER_COMPOSE_RETVAL=$?
    JQ_VERSION=$(jq --version 2>/dev/null)
    JQ_RETVAL=$?

    if [ $DOCKERD_RETVAL -ne 0 ]; then
        echo "ERROR: docker is not installed. Could not find docker." >&2
        RETVAL=$DOCKERD_RETVAL
    elif [ $DOCKER_COMPOSE_RETVAL -ne 0 ]; then
        echo "ERROR: docker compose is not installed but we found docker. Try installing docker compose." >&2
        echo "  docker version found: '$DOCKERD_VERSION'" >&2
        RETVAL=$DOCKER_COMPOSE_RETVAL
    elif [ $JQ_RETVAL -ne 0 ]; then
        echo "ERROR: jq is not installed. Could not find jq." >&2
        RETVAL=$JQ_RETVAL
    else
        echo "$DOCKERD_VERSION"
        echo "$DOCKER_COMPOSE_VERSION"
        echo "$JQ_VERSION"
    fi
    return $RETVAL
}

is_dvc_created() {
    if is_dvc_exists; then
        echo "This doesn't appear to be a fresh install. A docker volume container"
        echo "was found."
        echo
        echo "Maybe you wanted to upgrade:"
        echo "  $THIS upgrade"
        echo "or"
        echo "Maybe you wanted to reset the system and all its data:"
        echo "  $THIS full-reset"
        RETVAL=1
    fi
    return $RETVAL
}

docker_compose_up() {
    if is_container_running && [ ${FUNCNAME[1]} != upgrade_ohb ]; then
        echo "OHB is already running."
        RETVAL=1
    else
        export DOCKER_CLIENT_TIMEOUT=120
        export COMPOSE_HTTP_TIMEOUT=120
        docker_compose_yml && docker compose -f <(echo "$DOCKER_COMPOSE_YML") create
        RETVAL=$?
        [ $RETVAL -ne 0 ] && return $RETVAL
        if [ -n "$REQUESTED_ENV_FILE" -o -n "$STICKY_LIGHTTPD_ENV_FILE" -o -r "$DEFAULT_ENV_FILE" ]; then
            copy_env_to_container >/dev/null
        fi
        docker compose -f <(echo "$DOCKER_COMPOSE_YML") up -d
        RETVAL=$?
    fi

    return $RETVAL
}

docker_compose_up_voacap_service() {
    is_docker_installed >/dev/null || return $?

    echo "Upping voacap-service ..."

    export DOCKER_CLIENT_TIMEOUT=120
    export COMPOSE_HTTP_TIMEOUT=120
    IFS= DOCKER_COMPOSE_YML=$( docker_compose_yml_tmpl_voacap_service )
    docker compose -f <(echo "$DOCKER_COMPOSE_YML") create
    RETVAL=$?
    [ $RETVAL -ne 0 ] && return $RETVAL
    docker compose -f <(echo "$DOCKER_COMPOSE_YML") up -d
    RETVAL=$?
    return $RETVAL
}

docker_compose_down() {
    docker_compose_yml && docker compose -f <(echo "$DOCKER_COMPOSE_YML") down -v
    RETVAL=$?

    if is_container_exists; then
        RUNNING_PROJECT=$(docker inspect $CONTAINER | jq -r '.[0].Config.Labels."com.docker.compose.project"')
        if [ "$RUNNING_PROJECT" != "$DOCKER_PROJECT" ]; then
            echo "ERROR: this OHB was created with a different docker-compsose file. Please run" >&2
            echo "    'docker stop $CONTAINER'" >&2
            echo "    'docker rm $CONTAINER'" >&2
            echo "before running this utility." >&2
        else
            echo "ERROR: OHB failed to stop." >&2
        fi
        RETVAL=1
    fi
    
    return $RETVAL
}

docker_compose_down_voacap_service() {
    IFS= DOCKER_COMPOSE_YML=$( docker_compose_yml_tmpl_voacap_service )
    docker compose -f <(echo "$DOCKER_COMPOSE_YML") down -v
    RETVAL=$?
    return $RETVAL
}

docker_compose_reset() {
    get_current_http_port
    get_current_https_port
    get_current_image_tag
    docker_compose_down || return $RETVAL
    docker_compose_up
}

docker_compose_restart() {
    docker restart $CONTAINER
}

generate_docker_compose() {
    local SERVICE=$1
    if [ $SERVICE == ohb ]; then
        docker_compose_yml $SERVICE && echo "$DOCKER_COMPOSE_YML"
    elif [ $SERVICE == voacap-service ]; then
        IFS= DOCKER_COMPOSE_YML=$( docker_compose_yml_tmpl_voacap_service )
        echo "$DOCKER_COMPOSE_YML"
    fi
}

remove_ohb() {
    echo "Stopping the container ..."
    if docker_compose_down; then
        echo "Container stopped successfully."
    else
        echo "ERROR: failed to stop OHB with docker compose down" >&2
        return $RETVAL
    fi
    echo "Removing persistent storage ..."
    if rm_dvc; then
        echo "Persistent storage removed successfully."
    else
        echo "ERROR: failed to remove persistence storage." >&2
        return $RETVAL
    fi
}

recreate_ohb() {
    get_current_http_port
    get_current_https_port
    get_current_image_tag

    remove_ohb || return $RETVAL
    install_ohb || return $RETVAL
}

copy_env_to_container() {
    if [ -n "$REQUESTED_ENV_FILE" ]; then
        if [[ "$REQUESTED_ENV_FILE" == /* ]]; then
            ENV_FILE="$REQUESTED_ENV_FILE"
        else
            ENV_FILE="$STARTED_FROM/$REQUESTED_ENV_FILE"
        fi
    elif [ -n "$STICKY_LIGHTTPD_ENV_FILE" ]; then
        ENV_FILE="$STICKY_LIGHTTPD_ENV_FILE"
    else
        ENV_FILE="$DEFAULT_ENV_FILE"
    fi

    if is_container_exists; then
        if [ -r "$ENV_FILE" ]; then
            docker cp $ENV_FILE $CONTAINER:/opt/hamclock-backend/.env
        else
            echo "ERROR: ENV file not found: '$ENV_FILE'" >&2
            RETVAL=1
        fi
    else
        echo "ERROR: the docker container needs to exist for this command." >&2
        echo "Install or start OHB first." >&2
        RETVAL=1
    fi

    return $RETVAL
}

is_dvc_exists() {
    docker volume ls | grep -qsw $OHB_HTDOCS_DVC
    return $?
}

is_container_running() {
    docker ps --format '{{.Names}}' | grep -wqs $CONTAINER
    return $?
}

is_container_exists() {
    docker ps -a --format '{{.Names}}' | grep -wqs $CONTAINER
    return $?
}

create_dvc() {
    docker volume create $OHB_HTDOCS_DVC >/dev/null
    RETVAL=$?
    return $RETVAL
}

rm_dvc() {
    docker volume rm $OHB_HTDOCS_DVC >/dev/null
    RETVAL=$?
    return $RETVAL
}

get_current_http_port() {
    DOCKER_HTTP_PORT=$(docker inspect $CONTAINER 2>/dev/null | jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostPort')
    DOCKER_HTTP_IP=$(docker inspect $CONTAINER 2>/dev/null | jq -r '.[0].HostConfig.PortBindings."80/tcp"[0].HostIp')
    if [ "$DOCKER_HTTP_PORT" != 'null' ]; then
        if [ "$DOCKER_HTTP_IP" != 'null' ]; then
            CURRENT_HTTP_PORT=$DOCKER_HTTP_IP:$DOCKER_HTTP_PORT
        else
            CURRENT_HTTP_PORT=:$DOCKER_HTTP_PORT
        fi
    fi
}

get_current_https_port() {
    DOCKER_HTTPS_PORT=$(docker inspect $CONTAINER 2>/dev/null | jq -r '.[0].HostConfig.PortBindings."443/tcp"[0].HostPort')
    DOCKER_HTTPS_IP=$(docker inspect $CONTAINER 2>/dev/null | jq -r '.[0].HostConfig.PortBindings."443/tcp"[0].HostIp')
    if [ "$DOCKER_HTTPS_PORT" != 'null' ]; then
        if [ "$DOCKER_HTTPS_IP" != 'null' ]; then
            CURRENT_HTTPS_PORT=$DOCKER_HTTPS_IP:$DOCKER_HTTPS_PORT
        else
            CURRENT_HTTPS_PORT=:$DOCKER_HTTPS_PORT
        fi
    fi
}

get_current_image_tag() {
    CURRENT_DOCKER_IMAGE=$(docker inspect $CONTAINER 2>/dev/null | jq -r '.[0].Config.Image')
    if [ "$CURRENT_DOCKER_IMAGE" != 'null' ]; then
        CURRENT_TAG=${CURRENT_DOCKER_IMAGE#*:}
        CURRENT_IMAGE_BASE=${CURRENT_DOCKER_IMAGE%:*}
    fi
}

get_current_pskr_image_tag() {
    CURRENT_PSKR_DOCKER_IMAGE=$(docker inspect pskr-mqtt-cache 2>/dev/null | jq -r '.[0].Config.Image')
    if [ "$CURRENT_PSKR_DOCKER_IMAGE" != 'null' ]; then
        CURRENT_PSKR_TAG=${CURRENT_PSKR_DOCKER_IMAGE#*:}
        CURRENT_PSKR_IMAGE_BASE=${CURRENT_PSKR_DOCKER_IMAGE%:*}
    fi
}

get_current_voacap_image_tag() {
    CURRENT_VOACAP_DOCKER_IMAGE=$(docker inspect voacap-service 2>/dev/null | jq -r '.[0].Config.Image')
    if [ "$CURRENT_VOACAP_DOCKER_IMAGE" != 'null' ]; then
        CURRENT_VOACAP_TAG=${CURRENT_VOACAP_DOCKER_IMAGE#*:}
        CURRENT_VOACAP_IMAGE_BASE=${CURRENT_VOACAP_DOCKER_IMAGE%:*}
    fi
}

determine_http_port() {
    get_current_http_port

    # first precedence
    if [ -n "$REQUESTED_HTTP_PORT" ]; then
        HTTP_PORT=$REQUESTED_HTTP_PORT

    # second precedence
    elif [ -n "$CURRENT_HTTP_PORT" -a "$CURRENT_HTTP_PORT" != ':' ]; then
        HTTP_PORT=$CURRENT_HTTP_PORT

    # third precedence
    elif [ -n "$STICKY_HTTP_PORT" ]; then
        HTTP_PORT=$STICKY_HTTP_PORT

    # fourth precedence
    else
        HTTP_PORT=$DEFAULT_HTTP_PORT

    fi

    # if there was a :, it was probably IP:PORT; otherwise make sure there's a colon for port only
    [[ $HTTP_PORT =~ : ]] || HTTP_PORT=":$HTTP_PORT"
}

determine_https_port() {
    get_current_https_port

    # first precedence
    if [ -n "$REQUESTED_HTTPS_PORT" ]; then
        HTTPS_PORT=$REQUESTED_HTTPS_PORT

    # second precedence
    elif [ -n "$CURRENT_HTTPS_PORT" -a "$CURRENT_HTTPS_PORT" != ':' ]; then
        HTTPS_PORT=$CURRENT_HTTPS_PORT

    # third precedence
    elif [ -n "$STICKY_HTTPS_PORT" ]; then
        HTTPS_PORT=$STICKY_HTTPS_PORT

    # fourth precedence
    else
        HTTPS_PORT=$DEFAULT_HTTPS_PORT

    fi

    if [ "$HTTPS_PORT" == "-" ]; then
        HTTPS_PORT_MAPPING=""
    else
        # if there was a :, it was probably IP:PORT; otherwise make sure there's a colon for port only
        [[ $HTTPS_PORT =~ : ]] || HTTPS_PORT=":$HTTPS_PORT"
        HTTPS_PORT_MAPPING="- $HTTPS_PORT:443"
    fi
}

determine_http_log() {

    # first precedence
    if [ -n "$REQUESTED_EXTERNAL_HTTP_LOG" ]; then
        ENABLE_EXTERNAL_HTTP_LOG=$REQUESTED_EXTERNAL_HTTP_LOG

    # second precedence
    elif [ -n "$STICKY_EXTERNAL_HTTP_LOG" ]; then
        ENABLE_EXTERNAL_HTTP_LOG=$STICKY_EXTERNAL_HTTP_LOG

    # third precedence
    else
        ENABLE_EXTERNAL_HTTP_LOG=$DEFAULT_EXTERNAL_HTTP_LOG

    fi

    if [ "$ENABLE_EXTERNAL_HTTP_LOG" == true ]; then
        EXTERNAL_HTTP_LOG_MAPPING="- $HERE/logs/lighttpd:/var/log/lighttpd:rw"
        if [ "${FUNCNAME[2]}" == "docker_compose_up" ]; then
            if [ ! -e "$HERE/logs/lighttpd" ]; then
                mkdir -p "$HERE/logs/lighttpd"
            fi
            if [ "$(stat -c '%u' "$HERE/logs/lighttpd" 2>/dev/null)" != "33" ]; then
                # perms need to be set for logrotate to work
                echo
                echo "WARNING: folder '$HERE/logs/lighttpd' needs the following permission:"
                echo "   sudo chown 33 $HERE/logs/lighttpd"
                echo
            fi
        fi
    fi
}

determine_https_cert() {

    # first precedence
    if [ -n "$REQUESTED_CERT_PATH" ]; then
        CERT_PATH=$REQUESTED_CERT_PATH

    # second precedence
    elif [ -n "$STICKY_CERT_PATH" ]; then
        CERT_PATH=$STICKY_CERT_PATH

    # third precedence
    else
        CERT_PATH=$DEFAULT_CERT_PATH

    fi

    if [ "$CERT_PATH" == "-" ]; then
        HTTPS_CERT_MAPPING=""
    else
        # if there was a :, it was probably IP:PORT; otherwise make sure there's a colon for port only
        HTTPS_CERT_MAPPING="- $CERT_PATH:/etc/lighttpd/server.pem"
    fi
}

determine_map_sizes() {

    # first precedence
    if [ -n "$REQUESTED_MAP_SIZES" ]; then
        MAP_SIZES=$REQUESTED_MAP_SIZES

    # second precedence
    elif [ -n "$STICKY_MAP_SIZES" ]; then
        MAP_SIZES=$STICKY_MAP_SIZES

    # third precedence
    else
        MAP_SIZES=$DEFAULT_MAP_SIZES

    fi

    if [ "$MAP_SIZES" == all ]; then
        unset MAP_SIZES_MAPPING
    else
        MAP_SIZES_MAPPING="MAP_SIZES: $MAP_SIZES"
    fi
}

determine_alpha_install() {

    # first precedence
    if [ -n "$REQUESTED_ALPHA_INSTALL" ]; then
        ALPHA_INSTALL=$REQUESTED_ALPHA_INSTALL

    # second precedence
    elif [ -n "$STICKY_ALPHA_INSTALL" ]; then
        ALPHA_INSTALL=$STICKY_ALPHA_INSTALL

    # third precedence
    else
        ALPHA_INSTALL=$DEFAULT_ALPHA_INSTALL

    fi

    if [ "$ALPHA_INSTALL" == true ]; then
        ALPHA_INSTALL_MAPPING="ALPHA_INSTALL: $ALPHA_INSTALL"
    fi
}

determine_voacap_service_host() {
    # first precedence
    if [ -n "$REQUESTED_VOACAP_SERVICE_HOST" ]; then
        VOACAP_SERVICE_HOST=$REQUESTED_VOACAP_SERVICE_HOST

    # second precedence
    elif [ -n "$STICKY_VOACAP_SERVICE_HOST" ]; then
        VOACAP_SERVICE_HOST=$STICKY_VOACAP_SERVICE_HOST

    # third precedence
    else
        VOACAP_SERVICE_HOST=$DEFAULT_VOACAP_SERVICE_HOST

    fi

    if [ "$VOACAP_SERVICE_HOST" == "-" ]; then
        VOACAP_SERVICE_HOST=$DEFAULT_VOACAP_SERVICE_HOST
    fi
}

determine_tag() {
    get_current_image_tag

    # first precedence
    if [ -n "$REQUESTED_TAG" ]; then
        TAG=$REQUESTED_TAG
        return
    fi

    # upgrade shouldn't use the current tag unless it's 'latest'. 
    # GIT_TAG would be empty and we'll get DEFAULT_TAG

    # second precedence
    # FUNCNAME is a stack of nested function calls
    if [ -n "$CURRENT_TAG" -a ${FUNCNAME[3]} != upgrade_ohb ]; then
        TAG=$CURRENT_TAG

    # third precedence
    elif [ -n "$GIT_TAG" ]; then 
        if [ ${FUNCNAME[3]} == upgrade_ohb -a "$GIT_TAG" != "$OHB_MANAGER_VERSION" ]; then
            echo
            echo "WARNING:"
            echo "         You are in a git repository on tag: '$GIT_TAG'"
            echo "         Your version of '$THIS' is: '$OHB_MANAGER_VERSION'"
            echo
            echo "Please run upgrade again setting the version with the -t option."
            echo
            return 1
        fi
        TAG=$GIT_TAG

    # forth precedence
    else
        TAG=$DEFAULT_TAG

    fi
}

docker_compose_yml() {
    determine_http_port
    determine_https_port
    determine_https_cert
    determine_http_log
    determine_map_sizes
    determine_voacap_service_host
    determine_alpha_install

    determine_tag || return $?
    IMAGE=$IMAGE_BASE:$TAG

    if [ "$TAG" == "$CURRENT_TAG"  -a "$REQUEST_DOCKER_PULL" == true ]; then
        echo "Doing a docker pull of the image before docker compose."
        docker pull $IMAGE
    fi

    # compose file in $DOCKER_COMPOSE_YML
    IFS= DOCKER_COMPOSE_YML=$( docker_compose_yml_tmpl )
}

docker_compose_yml_tmpl() {
    cat<<EOF
name: $DOCKER_PROJECT
services:
  web:
    container_name: $CONTAINER
    image: $IMAGE
    restart: unless-stopped
    environment:
      HOST_HOSTNAME: $HOSTNAME
      PSKR_UID: 1001
      VOACAP_SERVICE_HOST: $VOACAP_SERVICE_HOST
      $MAP_SIZES_MAPPING
      $ALPHA_INSTALL_MAPPING
    networks:
      - ohb
    ports:
      - $HTTP_PORT:80
      $HTTPS_PORT_MAPPING
    volumes:
      - ohb-htdocs:/opt/hamclock-backend/htdocs
      $EXTERNAL_HTTP_LOG_MAPPING
      $HTTPS_CERT_MAPPING
    tmpfs:
       - /opt/hamclock-backend/upload-diags:uid=33,gid=33,mode=1700,size=16m
    healthcheck:
      test: ["CMD", "curl", "-f", "-A", "healthcheck/1.0", "http://localhost:80/ham/HamClock/version.pl"]
      timeout: "5s"
      start_period: "20s"
    logging:
      options:
        max-size: "10m"
        max-file: "2"

  pskr:
    container_name: pskr-mqtt-cache
    image: komacke/pskr-mqtt-cache:$PSKR_MQTT_CACHE_TAG
    restart: unless-stopped
    networks:
      - ohb
    volumes:
      - type: volume
        source: ohb-htdocs
        target: /data
        volume:
          subpath: pskr
    logging:
      options:
        max-size: "10m"
        max-file: "2"
    depends_on:
      web:
        condition: service_healthy

  voacap-service:
    image: komacke/voacap-service:$VOACAP_SERVICE_TAG
    container_name: voacap-service
    restart: unless-stopped
    environment:
      LOG_LEVEL: INFO
    networks:
      - ohb
    shm_size: "2gb"    # /dev/shm for fast VOACAP temp files
    mem_limit: "4gb"
    cpus: "4.0"
    tmpfs:
      - /run:size=16m
      - /tmp:size=2048m
    logging:
      options:
        max-size: "10m"
        max-file: "2"

networks:
  ohb:
    driver: bridge
    name: ohb
    enable_ipv6: true
    ipam:
     driver: default
     config:
       - subnet: 172.21.0.0/16
    driver_opts:
      com.docker.network.bridge.name: ohb

volumes:
  ohb-htdocs:
    external: true
EOF
}

docker_compose_yml_tmpl_voacap_service() {
    [ -z "$REQUESTED_TAG" ] && REQUESTED_TAG=$VOACAP_SERVICE_TAG
    [ -z "$REQUESTED_HTTP_PORT" ] && REQUESTED_HTTP_PORT=8080

    cat<<EOF
name: $VC_ALONE_CONTAINER
services:
  voacap-service:
    image: komacke/voacap-service:$REQUESTED_TAG
    container_name: $VC_ALONE_CONTAINER
    restart: unless-stopped
    environment:
      LOG_LEVEL: INFO
    ports:
      - $REQUESTED_HTTP_PORT:8080
    shm_size: "2gb"    # /dev/shm for fast VOACAP temp files
    mem_limit: "4gb"
    tmpfs:
      - /run:size=8m
      - /tmp:size=32m
    healthcheck:
      test: ["CMD", "wget", "-q", "-O-", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

main "$@"
exit $RETVAL
