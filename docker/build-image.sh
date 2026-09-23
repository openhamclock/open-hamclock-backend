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

# Variables to set
GIT_REPO=https://github.com/openhamclock/open-hamclock-backend
IMAGE_BASE=komacke/open-hamclock-backend
VOACAP_VERSION=v.0.7.6
HTTP_PORT=80

# Don't set anything past here

# Define color variables
RED=$(tput bold; tput setaf 1 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
NC=$(tput sgr0 2>/dev/null || true) # Reset color

if [ -n "$TAG" ]; then
    GIT_VERSION=$TAG
else
    if ! TAG=$(git describe --exact-match --tags 2>/dev/null); then
        echo "${RED}NOTE${NC}: Not currently on a tag. Using 'edge'."
        TAG=edge
        GIT_VERSION=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    else
        GIT_VERSION=$TAG
    fi
fi

IMAGE=$IMAGE_BASE:$TAG
CONTAINER=${IMAGE_BASE##*/}

# Get our directory locations in figured out
HERE="$(cd "$(dirname "$0")" && pwd)"
THIS="$(basename "$0")"
cd $HERE

usage() {
    cat<<EOF
$THIS: 

    Builds the latest docker image based on the current git branch. It will figure out
    if on a git tag and will use that for the docker image tag. Otherwise falls back
    to 'edge'.

    Options:
    -m: multi-platform image build for: linux/amd64 linux/arm64
        - remember to setup a buildx container: 
            docker buildx create --name ohb --driver docker-container --use
            docker buildx inspect --bootstrap
    -n: add --no-cache to build
    -h: show this help message

    Environment variables:
        TAG: override the image tag (default: git tag or 'edge')
        FORCE=true: bypass local edits check
EOF
    exit 0
}

main() {
    RETVAL=0
    MULTI_PLATFORM=false
    NOCACHE=false

    if [[ "$@" =~ --help ]]; then
        usage
    fi

    while getopts ":hmn" opt; do
        case $opt in
            h)
                usage
                ;;
            m)
                MULTI_PLATFORM=true
                ;;
            n)
                NOCACHE=true
                ;;
            \?) # Handle invalid options
                echo "Invalid option: -$OPTARG" >&2
                exit 1
                ;;
            :) # Handle options requiring an argument but none provided
                echo "Option -$OPTARG requires an argument." >&2
                exit 1
                ;;
        esac
    done
    shift $((OPTIND - 1))

    if [[ -n "$1" ]]; then
        echo
        echo "Invalid argument: $1"
        exit 1
    fi

    do_all
    build_done_message
}

do_all() {
    warn_image_tag
    warn_local_edits
    get_maps
    build_image
}

warn_image_tag() {
    if [ $TAG != edge ]; then
        if [ $MULTI_PLATFORM == true ]; then
            docker manifest inspect $IMAGE >/dev/null
            if [ $? -eq 0 ]; then
                echo
                echo "${RED}WARNING${NC}: the multiplatform docker image for '$IMAGE' already exists in Docker Hub. Please"
                echo "         remove it if you want to rebuild."
                exit 2
            fi
        elif docker image list --format '{{.Repository}}:{{.Tag}}' | grep -qs $IMAGE; then
            echo
            echo "${RED}WARNING${NC}: the docker image for '$IMAGE' already exists. Please remove it if you want to rebuild."
            exit 2
        fi
    fi
}

warn_local_edits() {
    # check if there are local edits in the filesystem. We probably don't want to push them
    git diff-index --quiet HEAD --
    LOCAL_EDITS=$?

    if [ $LOCAL_EDITS -ne 0 ]; then
        if [ "$FORCE" == "true" ] || [ "$CI" == "true" ]; then
            echo "${YELLOW}WARNING${NC}: Local edits detected, but proceeding because CI or FORCE is set."
            return 0
        fi
        if [ $MULTI_PLATFORM == true ]; then
            echo
            echo "${RED}ERROR${NC}: There are local edits. stash or reset them before pushing"
            echo "       images to Docker Hub."
            exit 3
        else
            echo
            echo "${RED}WARNING${NC}: there are local edits. If you didn't intend that, stash"
            echo "         them and build again."
        fi
    fi
    return $LOCAL_EDITS
}

get_maps() {
    if [ ! -e ohb-maps.tar.zst ]; then
        echo
        echo "Getting ohb-maps from GitHub ..."
        curl -fsSLO $GIT_REPO/releases/download/maps-v2/ohb-maps.tar.zst
    fi
}

build_image() {
    if [ $NOCACHE == true ]; then
        NOCACHE_ARG="--no-cache"
    fi
    # Build the image
    echo
    echo "Building image for '$IMAGE_BASE:$TAG'"
    pushd "$HERE/.." >/dev/null

    # only use latest on stable versions
    if [[ $TAG =~ ^v[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
        TAG_LATEST="-t $IMAGE_BASE:latest"
    fi

    if [ $MULTI_PLATFORM == true ]; then
        docker buildx build \
            $NOCACHE_ARG \
            --pull \
            --build-arg GIT_VERSION=${GIT_VERSION} \
            -t $IMAGE \
            $TAG_LATEST \
            -f docker/Dockerfile \
            --platform linux/amd64,linux/arm64 \
            --push \
            .
    else
        docker build \
            $NOCACHE_ARG \
            --pull \
            --build-arg GIT_VERSION=${GIT_VERSION} \
            -t $IMAGE \
            $TAG_LATEST \
            -f docker/Dockerfile \
            .
    fi
    RETVAL=$?
    popd >/dev/null
}

build_done_message() {
    if [ $RETVAL -eq 0 ]; then
        # basic info
        echo
        echo "Completed building '$IMAGE'."
    else
        echo "build failed with error: $RETVAL"
    fi
}

main "$@"
exit $RETVAL
