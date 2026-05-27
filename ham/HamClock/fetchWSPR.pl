#!/usr/bin/perl

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

use strict;
use warnings;
use JSON;
use URI::Escape;
use CGI;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use File::Path qw(make_path);

my $WSPR_URL       = "https://db1.wspr.live/";
my $UA_STRING      = "OHB/2.x (+https://github.com/komacke/open-hamclock-backend)";
my $HTTP_TIMEOUT   = 15;       # seconds
my $MAX_RETRIES    = 2;        # retry attempts on 5xx
my $RETRY_BASE     = 2;        # seconds (with jitter)
my $RESULT_LIMIT   = 5000;     # row cap
my $CACHE_DIR      = "/opt/hamclock-backend/tmp/wspr_cache";
my $CACHE_TTL      = 45;       # seconds; WSPR cycles are 120s so this is safe

# Hard caps to prevent abuse / runaway queries
my $MAX_AGE_CAP    = 86400;    # 24h max lookback
my $MIN_AGE        = 60;       # 1 min min lookback
my $MAX_CALL_LEN   = 16;
my $MAX_GRID_LEN   = 6;

print "Content-type: text/plain; charset=UTF-8\n\n";

my $q = CGI->new;

my $ofgrid = $q->param('ofgrid') // "";
my $bygrid = $q->param('bygrid') // "";
my $ofcall = $q->param('ofcall') // "";
my $bycall = $q->param('bycall') // "";
my $band   = $q->param('band')   // "";   # optional ClickHouse band code
my $maxage = $q->param('maxage') // 900;

# Grids: Maidenhead is alphanumeric only, max 6 chars
$ofgrid =~ s/[^A-Za-z0-9]//g;
$bygrid =~ s/[^A-Za-z0-9]//g;
$ofgrid = substr($ofgrid, 0, $MAX_GRID_LEN);
$bygrid = substr($bygrid, 0, $MAX_GRID_LEN);

# Callsigns: allow A-Z, 0-9, and '/' for portable/rover designators
$ofcall =~ s/[^A-Za-z0-9\/]//g;
$bycall =~ s/[^A-Za-z0-9\/]//g;
$ofcall = substr($ofcall, 0, $MAX_CALL_LEN);
$bycall = substr($bycall, 0, $MAX_CALL_LEN);

# Numeric fields
$maxage =~ s/[^0-9]//g;
$maxage = $MIN_AGE      if $maxage eq "" || $maxage < $MIN_AGE;
$maxage = $MAX_AGE_CAP  if $maxage > $MAX_AGE_CAP;

$band =~ s/[^0-9\-]//g;  # allow negative band codes (e.g. -1 for LF)

$ofgrid = uc($ofgrid);
$bygrid = uc($bygrid);
$ofcall = uc($ofcall);
$bycall = uc($bycall);

# Exactly one selector required
my @selectors = grep { $_ ne "" } ($ofgrid, $bygrid, $ofcall, $bycall);
if (@selectors == 0) {
    print "ARGUMENT ERROR: must supply one of ofgrid, bygrid, ofcall, bycall\n";
    exit;
}
if (@selectors > 1) {
    print "ARGUMENT ERROR: supply only one selector at a time\n";
    exit;
}

my $where_clause;
if ($ofgrid ne "") {
    $where_clause = "tx_loc LIKE '${ofgrid}%'";
} elsif ($bygrid ne "") {
    $where_clause = "rx_loc LIKE '${bygrid}%'";
} elsif ($ofcall ne "") {
    $where_clause = "tx_sign = '${ofcall}'";   # ClickHouse uses = not ==
} elsif ($bycall ne "") {
    $where_clause = "rx_sign = '${bycall}'";
}

# Optional band narrowing — strongly recommended to avoid 503s on busy bands
if ($band ne "") {
    $where_clause .= " AND band = $band";
}

# ORDER BY + LIMIT keeps result size bounded even for popular grids/calls
my $sql = "SELECT toUnixTimestamp(time) AS epoch, "
        . "tx_loc, tx_sign, rx_loc, rx_sign, band, frequency, snr "
        . "FROM wspr.rx "
        . "WHERE $where_clause "
        . "AND time > subtractSeconds(now(), $maxage) "
        . "ORDER BY time DESC "
        . "LIMIT $RESULT_LIMIT "
        . "FORMAT JSON";

my $cache_key  = md5_hex($sql);
my $cache_path = File::Spec->catfile($CACHE_DIR, "$cache_key.json");

# Recursive create (mkdir -p equivalent); make_path silently no-ops if it exists.
# Wrap in eval since make_path croaks on permission errors.
unless (-d $CACHE_DIR) {
    eval { make_path($CACHE_DIR) };
    warn "wspr cache: could not create $CACHE_DIR: $@" if $@;
}

# Caching is best-effort: if the dir doesn't exist or isn't writable, skip it
# entirely rather than silently failing on every request.
my $cache_ok = (-d $CACHE_DIR && -w $CACHE_DIR) ? 1 : 0;
warn "wspr cache: $CACHE_DIR not writable, caching disabled" unless $cache_ok;

my $cached_body;
if ($cache_ok && -f $cache_path) {
    my $age = time() - (stat($cache_path))[9];
    if ($age < $CACHE_TTL) {
        if (open(my $fh, '<', $cache_path)) {
            local $/;
            $cached_body = <$fh>;
            close $fh;
        }
    }
}

# If we found the cache, then skip the query and return the cached data 
# right back
my $body;
if (defined $cached_body) {
    $body = $cached_body;
} else {
    my $url = $WSPR_URL . "?query=" . uri_escape($sql);

    my $attempt = 0;
    my $http_code = 0;
    my $curl_body;
    my $curl_err;

    while ($attempt <= $MAX_RETRIES) {
        # -s silent, -S show errors, -L follow redirects,
        # -A user-agent, --max-time timeout,
        # -w writes the HTTP status code on its own line at the end.
        # The `--` keeps curl from interpreting the URL as an option,
        # and passing args via list form avoids any shell quoting issues.
        my @cmd = (
            'curl',
            '-sSL',
            '-A', $UA_STRING,
            '--max-time', $HTTP_TIMEOUT,
            '-w', "\n%{http_code}",
            '--', $url,
        );

        my $pid = open(my $ch, '-|');
        if (!defined $pid) {
            $curl_err = "fork failed: $!";
            last;
        }
        if ($pid == 0) {
            exec(@cmd) or exit 127;
        }
        local $/;
        my $raw = <$ch>;
        close $ch;
        my $exit = $? >> 8;

        if ($exit != 0) {
            $curl_err = "curl exited with status $exit";
            # Treat curl transport errors like a 5xx for retry purposes
            if ($attempt < $MAX_RETRIES) {
                my $sleep = $RETRY_BASE * (2 ** $attempt) + rand(1);
                sleep($sleep);
                $attempt++;
                next;
            }
            last;
        }

        # Split body from the trailing HTTP status code that -w appended
        if (defined $raw && $raw =~ /\A(.*)\n(\d{3})\z/s) {
            $curl_body = $1;
            $http_code = $2 + 0;
        } else {
            $curl_err = "could not parse curl output";
            last;
        }

        last if $http_code >= 200 && $http_code < 300;

        if ($http_code >= 500 && $http_code < 600 && $attempt < $MAX_RETRIES) {
            my $sleep = $RETRY_BASE * (2 ** $attempt) + rand(1);
            sleep($sleep);
            $attempt++;
            next;
        }
        last;
    }

    if ($http_code < 200 || $http_code >= 300) {
        if ($http_code == 429 || $http_code == 403) {
            print "ERROR: Rate limit exceeded. Back off before retrying.\n";
        } elsif ($http_code == 503) {
            print "ERROR: wspr.live temporarily unavailable (503) after retries.\n";
        } elsif ($http_code == 0) {
            print "HTTP ERROR: curl failed: " . ($curl_err // "unknown") . "\n";
        } else {
            print "HTTP ERROR: HTTP $http_code from wspr.live\n";
        }
        exit;
    }

    $body = $curl_body;

    # Write cache (best-effort)
    # In other words, if the cache can't be written then we don't care
    if ($cache_ok && open(my $fh, '>', $cache_path)) {
        print $fh $body;
        close $fh;
    }
}

# This is going to decode the cached data or the data from the query
my $decoded = eval { decode_json($body) };
if ($@ || !$decoded || !$decoded->{data}) {
    print "ERROR: could not parse wspr.live response\n";
    exit;
}

# Decoded. Now, emit in HamClock wire format.
# HamClock parses the frequency field with %ld and treats it as Hz.
foreach my $row (@{$decoded->{data}}) {
    printf("%s,%s,%s,%s,%s,WSPR,%d,%d\n",
        $row->{epoch}      // 0,
        uc($row->{tx_loc}  // ""),
        uc($row->{tx_sign} // ""),
        uc($row->{rx_loc}  // ""),
        uc($row->{rx_sign} // ""),
        int($row->{frequency} // 0),   # Hz as integer
        $row->{snr}        // 0,
    );
}
