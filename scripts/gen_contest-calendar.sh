#!/bin/bash
# ============================================================
#
#   ██████╗ ██╗  ██╗██████╗
#  ██╔═══██╗██║  ██║██╔══██╗
#  ██║   ██║███████║██████╔╝
#  ██║   ██║██╔══██║██╔══██╗
#  ╚██████╔╝██║  ██║██████╔╝
#   ╚═════╝ ╚═╝  ╚═╝╚═════╝
#
#  Open HamClock Backend
#  gen-contest-calendar.sh
#
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#
#  You should have received a copy of the GNU Affero General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# ============================================================

URL="https://contestcalendar.com/weeklycontcustom.php"
OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/contests"

mkdir -p "$OUTDIR"

OUT311="$OUTDIR/contests311.txt"   # epoch format (existing)
OUT3="$OUTDIR/contests3.txt"       # human-readable dates
OUT="$OUTDIR/contests.txt"         # names only

# Headers
echo "WA7BNM Weekend Contests" > "$OUT311"
echo "WA7BNM Weekend Contests" > "$OUT3"
echo "WA7BNM Weekend Contests" > "$OUT"

curl -s "$URL" | tr -d '\r' | awk '
  /^BEGIN:VEVENT/ {printf "EVENT|"}
  /^DTSTART:/ {split($0, a, ":"); printf "%s|", a[2]}
  /^DTEND:/   {split($0, a, ":"); printf "%s|", a[2]}
  /^SUMMARY:/ {printf "%s|", substr($0, 9)}
  /^URL:/     {printf "%s\n", substr($0, 5)}
' | while IFS="|" read -r marker start_raw end_raw title url; do

    [[ -z "$start_raw" ]] && continue

    title=$(echo "$title" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    Y=${start_raw:0:4};  M=${start_raw:4:2};  D=${start_raw:6:2}
    H=${start_raw:9:2};  Min=${start_raw:11:2}; S=${start_raw:13:2}

    Y2=${end_raw:0:4};   M2=${end_raw:4:2};   D2=${end_raw:6:2}
    H2=${end_raw:9:2};   Min2=${end_raw:11:2}; S2=${end_raw:13:2}

    start_epoch=$(date -u -d "$Y-$M-$D $H:$Min:$S" +%s 2>/dev/null)
    end_epoch=$(date -u -d "$Y2-$M2-$D2 $H2:$Min2:$S2" +%s 2>/dev/null)
    dow=$(date -u -d "$Y-$M-$D $H:$Min:$S" +%w 2>/dev/null)

    if [[ "$dow" == "0" || "$dow" == "6" ]]; then

        # contests311.txt — epoch format (unchanged)
        printf "%s %s %s\n" "$start_epoch" "$end_epoch" "$title" >> "$OUT311"
        printf "%s\n" "$url" >> "$OUT311"

        # Format start
        start_hm=$(date -u -d "@$start_epoch" +"%H%M")
        start_day=$(date -u -d "@$start_epoch" +"%Y%m%d")
        start_fmt=$(date -u -d "@$start_epoch" +"%H%M %b %-d")

        # Format end — treat 2359 as 2400
        end_hm=$(date -u -d "@$end_epoch" +"%H%M")
        end_day=$(date -u -d "@$end_epoch" +"%Y%m%d")
        end_day_fmt=$(date -u -d "@$end_epoch" +"%b %-d")
        [[ "$end_hm" == "2359" ]] && end_hm="2400"
        end_fmt="$end_hm $end_day_fmt"

        # contests3.txt
        if [[ "$start_day" == "$end_day" ]]; then
            day_fmt=$(date -u -d "@$start_epoch" +"%b %-d")
            printf "%s\n%s-%s %s\n" "$title" "$start_hm" "$end_hm" "$day_fmt" >> "$OUT3"
        else
            printf "%s\n%s - %s\n" "$title" "$start_fmt" "$end_fmt" >> "$OUT3"
        fi

        # contests.txt — title only
        printf "%s\n" "$title" >> "$OUT"
    fi
done
