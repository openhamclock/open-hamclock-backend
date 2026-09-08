#!/usr/bin/env perl
# Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

use strict;
use warnings;

use LWP::UserAgent;
use Text::CSV_XS;
use File::Copy qw(move);
use Encode qw(decode encode);

my $WWFF_URL = 'https://wwff.co/wwff-data/wwff_directory.csv';

my $OUT = '/opt/hamclock-backend/cache/wwff_parks.csv';
my $TMP = "$OUT.tmp";

my $ua = LWP::UserAgent->new(
    timeout => 30,
    agent   => 'HamClock-Backend/1.0',
);

print "Downloading WWFF directory...\n";
my $resp = $ua->get($WWFF_URL);
die "Fetch failed: " . $resp->status_line . "\n" unless $resp->is_success;

# Decode defensively rather than trusting the response's declared/assumed
# charset blindly -- see the identical comment in update_sota_cache.pl for
# why. Try strict UTF-8 first; fall back to Windows-1252 if that fails.
my $raw = $resp->content;   # raw bytes, no charset assumption from LWP
my $content = eval { decode('UTF-8', $raw, Encode::FB_CROAK) };
if ($@) {
    warn "WWFF directory CSV was not valid UTF-8 -- falling back to Windows-1252 decode\n";
    $content = decode('cp1252', $raw);
}
# See update_sota_cache.pl's comment on this exact block: in-memory
# filehandles can't be opened directly on a wide-character string, so
# re-encode to plain UTF-8 bytes first, then open that with an
# ':encoding(UTF-8)' layer to decode it back on read.
my $bytes = encode('UTF-8', $content);
open my $in_fh, '<:encoding(UTF-8)', \$bytes or die "Cannot open content buffer: $!\n";

my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });

my $header = $csv->getline($in_fh);
die "Could not read header\n" unless $header && @$header;

my %idx;
for my $i (0 .. $#$header) {
    $idx{$header->[$i]} = $i;
}

for my $need (qw(reference latitude longitude iaruLocator)) {
    die "Missing expected column '$need' in WWFF CSV\n" unless exists $idx{$need};
}

my $i_ref  = $idx{reference};
my $i_lat  = $idx{latitude};
my $i_lon  = $idx{longitude};
my $i_grid = $idx{iaruLocator};
my $i_stat = $idx{status} // -1;

# 'state' is carried through as-is: it's already "K-ME" / "VE-BC" style
# for the US/Canada (matching POTA's locationDesc convention) and the
# bare DXCC/ham prefix (e.g. "S5", "9A", "VK") everywhere else. Both
# forms are handled by resolve_state() in gen_onta.pl.
my $i_state = $idx{state} // -1;

if ($i_state < 0) {
    print "No 'state' column found in WWFF CSV -- state will be blank for every reference\n";
}

open my $out_fh, '>:encoding(UTF-8)', $TMP or die "Cannot write $TMP: $!\n";
my $out_csv = Text::CSV_XS->new({ binary => 1, eol => "\n" });

# 'state' is one of gen_onta.pl's recognized location columns
# (@LOC_COLS), so no changes are needed there to pick this up.
$out_csv->print($out_fh, [qw(reference latitude longitude grid state)]);

my $count = 0;
while (my $row = $csv->getline($in_fh)) {
    # Skip inactive references if status column is present
    if ($i_stat >= 0) {
        my $status = $row->[$i_stat] // '';
        next unless $status eq 'active';
    }

    my $ref = $row->[$i_ref] // next;
    $ref =~ s/^\s+|\s+$//g;
    next unless length $ref;

    my $lat  = $row->[$i_lat]  // '';
    my $lon  = $row->[$i_lon]  // '';
    my $grid = $row->[$i_grid] // '';

    # Skip rows with no usable coordinates
    next unless length($lat) && length($lon);
    next unless $lat =~ /^-?\d+\.?\d*$/ && $lon =~ /^-?\d+\.?\d*$/;

    # Truncate Maidenhead to 4 characters (WWFF provides 6-char locators)
    $grid = substr($grid, 0, 4) if length($grid) >= 4;

    my $state = ($i_state >= 0) ? ($row->[$i_state] // '') : '';
    $state =~ s/^\s+|\s+$//g;

    $out_csv->print($out_fh, [$ref, $lat, $lon, $grid, $state]);
    $count++;
}

close $in_fh;
close $out_fh;

move($TMP, $OUT) or die "move failed $TMP -> $OUT: $!\n";

print "Written $count references to $OUT\n";
