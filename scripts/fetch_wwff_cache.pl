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
#  *** RUN ONLY ON THE CENTRAL OHB HOST ***
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
#  Self-install operators: DO NOT enable this cron entry. Your gen_onta.pl
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

my $WWFF_URL = 'https://www.cqgma.org/api/spots/wwff/';
my $OUT      = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/wwff_spots.json';
my $TMP      = "$OUT.tmp";

# Ensure output directory exists
my $dir = dirname($OUT);
unless (-d $dir) {
    make_path($dir) or die "Cannot create $dir: $!\n";
}

my $ua = LWP::UserAgent->new(
    timeout => 15,
    agent   => 'OHB-WWFF-Cache/1.0 (+https://github.com/komacke/open-hamclock-backend; central mirror per DL4MFM request)',
);

my $resp = $ua->get($WWFF_URL);

unless ($resp->is_success) {
    warn "GMA WWFF fetch failed: " . $resp->status_line . "\n";
    # Leave the existing cache file in place so consumers keep getting
    # the last-known-good data rather than an empty response.
    exit 1;
}

my $body = $resp->decoded_content;

# Basic sanity: must be non-empty and look like JSON
unless (defined($body) && length($body) > 0 && $body =~ /^\s*[\{\[]/) {
    warn "GMA WWFF response does not look like JSON; keeping previous cache.\n";
    exit 1;
}

open my $fh, '>', $TMP or die "Cannot write $TMP: $!\n";
print $fh $body;
close $fh;

move($TMP, $OUT) or die "move failed $TMP -> $OUT: $!\n";

# Optional: log size for monitoring
my $bytes = -s $OUT;
print "WWFF cache updated: $bytes bytes\n";
