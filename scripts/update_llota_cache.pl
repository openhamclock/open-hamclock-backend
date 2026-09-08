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
#  update_llota_cache.pl -- fetches the LLOTA (Lagos y Lagunas On The Air)
#  reference database and produces a local CSV lookup, same pattern as
#  update_sota_cache.pl / update_wwff_cache.pl.
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
# =============================================================================

use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json);
use Text::CSV_XS;
use File::Copy qw(move);
use Encode qw(decode encode);

my $LLOTA_URL = 'https://llota.app/api/public/references';

my $OUT = '/opt/hamclock-backend/cache/llota_references.csv';
my $TMP = "$OUT.tmp";

my $ua = LWP::UserAgent->new(
    timeout => 30,
    agent   => 'HamClock-Backend/1.0',
);

print "Downloading LLOTA reference list...\n";
my $resp = $ua->get($LLOTA_URL);
die "Fetch failed: " . $resp->status_line . "\n" unless $resp->is_success;

# Decode defensively rather than trusting the response's declared/assumed
# charset blindly -- same reasoning as update_sota_cache.pl /
# update_wwff_cache.pl. LLOTA's region names include plenty of accented
# characters (Spanish, Polish), so this matters here too.
my $raw = $resp->content;
my $content = eval { decode('UTF-8', $raw, Encode::FB_CROAK) };
if ($@) {
    warn "LLOTA reference list was not valid UTF-8 -- falling back to Windows-1252 decode\n";
    $content = decode('cp1252', $raw);
}

my $data = eval { decode_json(encode('UTF-8', $content)) };
if ($@) {
    die "LLOTA JSON parse failed: $@\n";
}
unless (ref $data eq 'ARRAY') {
    die "LLOTA response was not a JSON array\n";
}

open my $out_fh, '>:encoding(UTF-8)', $TMP or die "Cannot write $TMP: $!\n";
my $out_csv = Text::CSV_XS->new({ binary => 1, eol => "\n" });
$out_csv->print($out_fh, [qw(reference latitude longitude grid country_code region)]);

my $count = 0;
for my $ref (@$data) {
    next unless ref $ref eq 'HASH';

    my $reference = $ref->{reference_code};
    next unless defined $reference && length $reference;

    my $lat  = $ref->{latitude};
    my $lon  = $ref->{longitude};
    next unless defined $lat && defined $lon && length($lat) && length($lon);
    next unless $lat =~ /^-?\d+\.?\d*$/ && $lon =~ /^-?\d+\.?\d*$/;

    my $grid    = $ref->{grid_locator} // '';
    my $country = $ref->{country_code} // '';
    my $region  = $ref->{region} // '';

    $out_csv->print($out_fh, [$reference, $lat, $lon, $grid, $country, $region]);
    $count++;
}

close $out_fh;
move($TMP, $OUT) or die "move failed $TMP -> $OUT: $!\n";

print "Written $count LLOTA references to $OUT\n";
