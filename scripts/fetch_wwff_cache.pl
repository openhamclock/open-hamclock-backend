#!/usr/bin/env perl
# =============================================================================
#
#   #####   #     #  ######
#  #     #  #     #  #     #
#  #     #  #     #  #     #
#  #     #  #######  ######
#  #     #  #     #  #     #
#  #     #  #     #  #     #
#   #####   #     #  ######
#
#  Open HamClock Backend (OHB)
#  fetch_wwff_cache.pl -- Central WWFF spot mirror fetcher
#
#           *** RUNS ON ALL OHB HOSTS ***
#      Behavior determined by ALPHA_INSTALL environment variable
#
#  Fetches live WWFF spots from cqgma.org once per minute and writes them
#  to a local JSON file that all OHB installations (central + self-install)
#  read via gen_onta.pl.
#
#  Per request from Mario, DL4MFM (https://www.cqgma.org), the WWFF spot
#  API is rate limited to 1 req/min and 1440 req/day per client. To keep
#  the service free and stable, OHB now uses a single shared mirror
#  instead of letting every installation poll GMA directly.
#
#  Self-install operators: DO NOT set ALPHA_INSTALL=true. Your gen_onta.pl
#  will read from the central mirror automatically.
#
#  Part of the OHB project:
#  https://github.com/komacke/open-hamclock-backend/tree/main
#
##
# Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
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
# =============================================================================

use strict;
use warnings;

use LWP::UserAgent;
use File::Copy qw(move);
use File::Basename qw(dirname);
use File::Path qw(make_path);

my $GMA_SOURCE = 'https://www.cqgma.org/api/spots/wwff/';

# Get CQGMA_API_KEY from environment or .env file
my $CQGMA_API_KEY = $ENV{CQGMA_API_KEY} // '';
if (!$CQGMA_API_KEY && -f '/opt/hamclock-backend/.env') {
    if (open my $efh, '<', '/opt/hamclock-backend/.env') {
        while (my $line = <$efh>) {
            if ($line =~ /^CQGMA_API_KEY=(.*)/) {
                $CQGMA_API_KEY = $1;
                $CQGMA_API_KEY =~ s/^\s+|\s+$//g;
                $CQGMA_API_KEY =~ s/^['"]|['"]$//g;
                last;
            }
        }
        close $efh;
    }
}

die "ERROR: CQGMA_API_KEY is not set in environment or /opt/hamclock-backend/.env\n" unless $CQGMA_API_KEY;
$GMA_SOURCE .= "?key=$CQGMA_API_KEY";

# If a mirror fetch fails, the script checks the local cache age. If it exceeds 
# this threshold (in seconds), a fallback fetch to the GMA source is attempted.
my $STALE_THRESHOLD = 3600;

my $alpha = $ENV{ALPHA_INSTALL} // '';
my $WWFF_URL;

if ($alpha eq 'true') {
    # This is the central mirror, fetch from the source
    $WWFF_URL = $GMA_SOURCE;
} elsif ($alpha =~ /^http/) {
    # Full URL provided
    $WWFF_URL = $alpha;
} elsif ($alpha ne '') {
    # Hostname provided, build the well-known path
    $WWFF_URL = "http://$alpha/ham/HamClock/ONTA/wwff_spots.json";
} else {
    # Fallback default
    $WWFF_URL = 'http://ohb.hamclock.app/ham/HamClock/ONTA/wwff_spots.json';
}

my $OUT      = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/wwff_spots.json';
my $TMP      = "$OUT.tmp";

# Ensure output directory exists
my $dir = dirname($OUT);
unless (-d $dir) {
    make_path($dir) or die "Cannot create $dir: $!\n";
}

my $ua = LWP::UserAgent->new(
    timeout => 15,
    agent   => 'OHB-WWFF-Cache/1.0 (+https://github.com/komacke/open-hamclock-backend; mirror fetcher)',
);

my $resp = $ua->get($WWFF_URL);

if (!$resp->is_success && $WWFF_URL ne $GMA_SOURCE) {
    # If primary fetch from a mirror fails, check staleness.
    # If the local file hasn't been updated in over an hour, allow one fallback attempt to GMA.
    my $mtime = (stat($OUT))[9] // 0;
    my $age   = time() - $mtime;

    if ($age > $STALE_THRESHOLD) {
        warn "Mirror $WWFF_URL failed (" . $resp->status_line . ") and cache is stale (${age}s). Falling back to GMA ($GMA_SOURCE).\n";
        my $fallback_resp = $ua->get($GMA_SOURCE);
        if ($fallback_resp->is_success) {
            $resp = $fallback_resp;
            $WWFF_URL = $GMA_SOURCE;
        } else {
            warn "Fallback to GMA also failed: " . $fallback_resp->status_line . "\n";
        }
    }
}

unless ($resp->is_success) {
    warn "WWFF fetch failed from $WWFF_URL: " . $resp->status_line . "\n";
    # Leave the existing cache file in place so consumers keep getting
    # the last-known-good data rather than an empty response.
    exit 1;
}

my $body = $resp->decoded_content;

# Basic sanity: must be non-empty and look like JSON
unless (defined($body) && length($body) > 0 && $body =~ /^\s*[\{\[]/) {
    warn "WWFF response from $WWFF_URL does not look like JSON; keeping previous cache.\n";
    exit 1;
}

open my $fh, '>', $TMP or die "Cannot write $TMP: $!\n";
print $fh $body;
close $fh;

move($TMP, $OUT) or die "move failed $TMP -> $OUT: $!\n";

# Optional: log size for monitoring
my $bytes = -s $OUT;
print "WWFF cache updated from $WWFF_URL: $bytes bytes\n";
