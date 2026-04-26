#!/usr/bin/env bash
# lib_sizes.sh - shared size selection for OHB map generators
#
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
#

# Canonical default list (keep in sync with HamClock)
# The sizes are listed in map_sizes.txt. Empty Lines and
# comments are ignored.

echo "$(dirname "$BASH_SOURCE[0]}")/map_sizes.txt"

mapfile -t DEFAULT_SIZES < <(sed -e '/^[[:blank:]]*#/d' -e '/^[[:blank:]]*$/d' "$(dirname "${BASH_SOURCE[0]}")/map_sizes.txt")

# Validate a single token looks like WxH.
ohb_is_size() {
    [[ "$1" =~ ^[0-9]+x[0-9]+$ ]]
}

# Load sizes into global bash array SIZES=()
#
# Inputs (in order of precedence):
#  1) OHB_SIZES env var: "660x330,1320x660"
#  2) An optional config file: /opt/hamclock-backend/etc/ohb-sizes.conf
#  3) DEFAULT_SIZES
#
# Outputs:
#  - Global array: SIZES=( "660x330" ... )
#  - Global string: OHB_SIZES_NORM="660x330,1320x660,..."
ohb_load_sizes() {
    local cfg="/opt/hamclock-backend/etc/ohb-sizes.conf"
    local raw=""

    # If OHB_SIZES not already set, try config file.
    if [[ -z "${OHB_SIZES:-}" && -r "$cfg" ]]; then
        # shellcheck disable=SC1090
        source "$cfg" 2>/dev/null || true
    fi

    raw="${OHB_SIZES:-}"

    # If still empty, use defaults.
    if [[ -z "$raw" ]]; then
        SIZES=( "${DEFAULT_SIZES[@]}" )
        OHB_SIZES_NORM="$(IFS=','; echo "${SIZES[*]}")"
        return 0
    fi

    # Normalize: remove whitespace, split on commas, dedupe preserving order, validate.
    raw="${raw//[[:space:]]/}"
    IFS=',' read -r -a _tmp <<< "$raw"

    declare -A _seen=()
    SIZES=()
    local s
    for s in "${_tmp[@]}"; do
        [[ -n "$s" ]] || continue
        if ! ohb_is_size "$s"; then
            echo "ERROR: invalid size '$s' (expected WxH like 660x330)" >&2
            return 1
        fi
        if [[ -z "${_seen[$s]:-}" ]]; then
            _seen[$s]=1
            SIZES+=( "$s" )
        fi
    done

    if [[ ${#SIZES[@]} -eq 0 ]]; then
        echo "ERROR: empty size list after parsing OHB_SIZES='$raw'" >&2
        return 1
    fi

    OHB_SIZES_NORM="$(IFS=','; echo "${SIZES[*]}")"
    return 0
}
