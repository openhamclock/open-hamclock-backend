#!/usr/bin/env bash
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
#  fetch_tle.sh  (AMSAT daily Keplerian source)
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
set -euo pipefail

TLEDIR="${TLEDIR:-/opt/hamclock-backend/tle}"
TLEFILE="$TLEDIR/amsat-latest.txt"   # last good AMSAT download (validated); nothing else is kept
TMPFILE="$TLEDIR/amsat-latest.new"
STAMPDIR="$TLEDIR/.stamps"
ESATS_OUT="${ESATS_OUT:-/opt/hamclock-backend/htdocs/ham/HamClock/esats/esats.txt}"
ESATS_NEW="${ESATS_OUT}.new"

FILTER="${FILTER:-/opt/hamclock-backend/scripts/filter_amsat_active.pl}"

MOONTLE_SCRIPT="${MOONTLE_SCRIPT:-/opt/hamclock-backend/scripts/moontle.py}"
PYTHON_BIN="${PYTHON_BIN-/opt/hamclock-backend/venv/bin/python3}"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="/usr/bin/python3"
fi

# AMSAT publishes one file per day.  Sources are tried in order; the first
# that returns a plausible TLE file wins.  A 304 (not modified) is not an error.
AMSAT_URLS=(
  "https://www.amsat.org/tle/dailytle.txt"
  "https://www.amsat.org/tle/daily-bulletin.txt"
)
MIN_OBJECTS="${MIN_OBJECTS:-20}"            # reject truncated / error-page downloads
STALE_WARN_HOURS="${STALE_WARN_HOURS:-72}"  # AMSAT is daily; warn if newest epoch is older

mkdir -p "$TLEDIR" "$STAMPDIR" "$(dirname "$ESATS_OUT")"

ts() { date -u +"%Y%m%dT%H%M%SZ"; }
CURL=(curl -A "HamClock-Backend/1.0" -sSL --connect-timeout 20 --max-time 90)

# stdin: any text.  stdout: only structurally valid 3-line TLE blocks (69-char
# lines, good checksums), one block per NORAD id, newest epoch wins.
tle_clean() {
    perl -e '
        sub ck { my $s=0; for my $c (split //, substr($_[0],0,68)) { $s+= ($c eq "-") ? 1 : ($c =~ /\d/ ? $c : 0) } $s%10 }
        my @L = map { s/\r?\n$//r } <STDIN>;
        my (%best, @order);
        for (my $i=0; $i+2 <= $#L; $i++) {
            my ($n,$a,$b) = @L[$i,$i+1,$i+2];
            next unless $a =~ /^1 / && $b =~ /^2 / && $n !~ /^[12] /;
            next unless length($a)==69 && length($b)==69;
            next unless ck($a)==substr($a,68,1) && ck($b)==substr($b,68,1);
            my ($id) = $a =~ /^1 (\d{5})/ or next;
            my $yy = substr($a,18,2); my $d = substr($a,20,12);
            next unless $d =~ /^\s*\d+\.\d+$/;
            my $ep = ($yy<57 ? 2000+$yy : 1900+$yy)*1000 + $d;
            $n =~ s/^\s+|\s+$//g;
            push @order, $id unless exists $best{$id};
            $best{$id} = [$ep,$n,$a,$b] if !exists $best{$id} || $ep >= $best{$id}[0];
            $i += 2;
        }
        print "$best{$_}[1]\n$best{$_}[2]\n$best{$_}[3]\n" for @order;
    '
}

echo "[$(date -u)] Fetching AMSAT keps..."

NEWDATA="$(mktemp)"; trap 'rm -f "$NEWDATA" "$TMPFILE" "$ESATS_NEW"' EXIT
GOT_NEW=0; UNCHANGED=0

for url in "${AMSAT_URLS[@]}"; do
    name="$(basename "$url")"; stamp="$STAMPDIR/$name"; resp="$(mktemp)"
    # conditional GET only if we also still hold the file it would refer to
    zopt=(); [[ -f "$stamp" && -s "$TLEFILE" ]] && zopt=(-z "$stamp")
    code="$("${CURL[@]}" ${zopt[@]+"${zopt[@]}"} -o "$resp" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
    if [[ "$code" == "304" ]]; then
        echo "  $name: not modified since last download"
        UNCHANGED=1; rm -f "$resp"; break
    fi
    n="$(tle_clean < "$resp" | grep -c '^1 ' || true)"
    if [[ "$code" == "200" && "$n" -ge "$MIN_OBJECTS" ]]; then
        cp "$resp" "$NEWDATA"; touch "$stamp"; GOT_NEW=1
        echo "  $name: $n valid objects"
        rm -f "$resp"; break
    fi
    echo "  $name: HTTP $code, $n valid objects — trying next source" >&2
    rm -f "$resp"
done

if [[ $GOT_NEW -eq 1 ]]; then
    # store only the validated blocks, replacing the previous file outright
    tle_clean < "$NEWDATA" > "$TMPFILE"
    mv "$TMPFILE" "$TLEFILE"
    echo "Saved $(grep -c '^1 ' "$TLEFILE") objects to $TLEFILE"
elif [[ $UNCHANGED -eq 0 ]]; then
    echo "WARNING: could not fetch AMSAT keps from any source — using last good download"
fi

if [[ ! -s "$TLEFILE" ]]; then
    echo "ERROR: no AMSAT data available — esats.txt left untouched"
    exit 1
fi

# --- Build esats.txt in a temp file, append Moon, then swap atomically -----
echo "[$(ts)] Running satellite filter..."
if ! env ESATS_TLE_CACHE="$TLEFILE" ESATS_OUT="$ESATS_NEW" perl "$FILTER"; then
    echo "WARNING: filter failed — esats.txt left untouched"
    exit 1
fi

echo "[$(ts)] Generating Moon TLE..."
MOON_TLE=""
if [[ -f "$MOONTLE_SCRIPT" ]]; then
    MOON_TLE=$("$PYTHON_BIN" -W ignore "$MOONTLE_SCRIPT" -q 2>/dev/null) || MOON_TLE=""
fi
if [[ "$(grep -c '^1 ' <<<"$MOON_TLE")" -eq 1 ]]; then
    echo "$MOON_TLE" >> "$ESATS_NEW"
    echo "[$(ts)] Moon TLE appended"
elif [[ -f "$ESATS_OUT" ]] && grep -q '^Moon$' "$ESATS_OUT"; then
    echo "WARNING: moontle.py failed — carrying over previous Moon block (valid ~24h)"
    grep -A2 '^Moon$' "$ESATS_OUT" >> "$ESATS_NEW"
else
    echo "WARNING: moontle.py failed — Moon TLE not added"
fi

chmod --reference="$ESATS_OUT" "$ESATS_NEW" 2>/dev/null || chmod 644 "$ESATS_NEW"
mv -f "$ESATS_NEW" "$ESATS_OUT"          # atomic: readers never see a partial file
echo "[$(ts)] esats.txt installed ($(grep -c '^1 ' "$ESATS_OUT") objects)"

# --- Report real data age (esats.txt mtime is meaningless: we rewrite it) ---
perl -MTime::Local -e '
    my ($now,$warn)=(time,$ARGV[0]*3600); my ($new,$old,$nn,$on);
    my @L=<STDIN>; chomp @L;
    for (my $i=0;$i<$#L;$i++){ next unless $L[$i+1] =~ /^1 /; my $n=$L[$i]; next if $n eq "Moon";
        my ($yy,$d)=(substr($L[$i+1],18,2),substr($L[$i+1],20,12));
        my $e=Time::Local::timegm(0,0,0,1,0,2000+$yy)+($d-1)*86400;
        my $age=$now-$e; ($new,$nn)=($age,$n) if !defined $new||$age<$new; ($old,$on)=($age,$n) if !defined $old||$age>$old; }
    printf "Data age: newest %.1fh (%s), oldest %.1fh (%s)\n",$new/3600,$nn,$old/3600,$on if defined $new;
    print "WARNING: newest satellite epoch is older than $ARGV[0]h — AMSAT data is NOT updating\n" if defined $new && $new>$warn;
' "$STALE_WARN_HOURS" < "$ESATS_OUT"
