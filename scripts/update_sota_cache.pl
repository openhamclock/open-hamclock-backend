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
use POSIX qw(floor);
use Encode qw(decode encode);

my $SOTA_URL = 'https://storage.sota.org.uk/summitslist.csv';

my $OUT = '/opt/hamclock-backend/cache/sota_summits.csv';
my $TMP = "$OUT.tmp";

# ---------------------------------------------------------------------------
# Compute Maidenhead grid square (4-character) from longitude and latitude
# ---------------------------------------------------------------------------
sub latlon_to_grid {
    my ($lat, $lon) = @_;
    return '' if !defined $lat || !defined $lon;
    return '' if $lat < -90 || $lat > 90 || $lon < -180 || $lon > 180;

    my $adj_lon = $lon + 180.0;
    my $adj_lat = $lat + 90.0;

    my $field_lon = floor($adj_lon / 20);
    my $field_lat = floor($adj_lat / 10);
    my $sq_lon    = floor(($adj_lon - $field_lon * 20) / 2);
    my $sq_lat    = floor($adj_lat - $field_lat * 10);

    return sprintf('%s%s%d%d',
        chr(ord('A') + $field_lon),
        chr(ord('A') + $field_lat),
        $sq_lon,
        $sq_lat,
    );
}

# ---------------------------------------------------------------------------
# Download SOTA summits list
# ---------------------------------------------------------------------------
my $ua = LWP::UserAgent->new(
    timeout => 30,
    agent   => 'HamClock-Backend/1.0',
);

print "Downloading SOTA summits list...\n";
my $resp = $ua->get($SOTA_URL);
die "Fetch failed: " . $resp->status_line . "\n" unless $resp->is_success;

# Decode defensively rather than trusting the response's declared/assumed
# charset blindly: SOTA's summit list includes accented summit names
# (French/German/Spanish associations in particular), and has been
# observed NOT to be strictly valid UTF-8 -- decoding it as UTF-8
# unconditionally can leave malformed byte sequences (e.g. a raw \xE9,
# Latin-1/Windows-1252 for "e") sitting in memory, which then blow up
# whatever reads sota_summits.csv back with a UTF-8 filehandle layer
# later (e.g. gen_xonta.pl's load_lookup()). Try strict UTF-8 first;
# fall back to Windows-1252 (a superset of Latin-1, the common culprit
# for this kind of mojibake) if that fails.
my $raw = $resp->content;   # raw bytes, no charset assumption from LWP
my $content = eval { decode('UTF-8', $raw, Encode::FB_CROAK) };
if ($@) {
    warn "SOTA summitslist.csv was not valid UTF-8 -- falling back to Windows-1252 decode\n";
    $content = decode('cp1252', $raw);
}

# Strip the non-CSV first line ("SOTA Summits List (Date=...)")
$content =~ s/^[^\n]*\n// if $content =~ /^SOTA Summits List/;

# ---------------------------------------------------------------------------
# Parse and write output CSV
# ---------------------------------------------------------------------------
# In-memory filehandles cannot be opened directly on a character string
# that contains code points above 0xFF (an em dash, a curly quote, the
# Windows-1252 fallback's Euro sign, etc.) -- Perl refuses outright
# regardless of PerlIO layer ("Strings with code points over 0xFF may
# not be mapped into in-memory file handles"). The fix is to re-encode
# $content back into plain UTF-8 *bytes* (a byte string has no wide-char
# flag, so this works), then open THAT with an ':encoding(UTF-8)' layer,
# which decodes it back to characters on read. Net effect: whatever the
# upstream source's real encoding was (UTF-8 or the Windows-1252
# fallback above), what gets parsed here is always normalized UTF-8.
my $bytes = encode('UTF-8', $content);
open my $in_fh, '<:encoding(UTF-8)', \$bytes or die "Cannot open content buffer: $!\n";

my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });

# Read and validate header
my $header = $csv->getline($in_fh);
die "Could not read header\n" unless $header && @$header;

# Expected columns (0-based):
#   0=SummitCode, 1=AssociationName, 2=RegionName, 3=SummitName,
#   4=AltM, 5=AltFt, 6=GridRef1, 7=GridRef2,
#   8=Longitude, 9=Latitude, 10=Points, ...
my %idx;
for my $i (0 .. $#$header) {
    $idx{$header->[$i]} = $i;
}

for my $need (qw(SummitCode Longitude Latitude)) {
    die "Missing expected column '$need' in SOTA CSV\n" unless exists $idx{$need};
}

my $i_code   = $idx{SummitCode};
my $i_lon    = $idx{Longitude};
my $i_lat    = $idx{Latitude};

# RegionName is carried through as 'region' (one of gen_onta.pl's
# recognized location columns) so US/Canada SOTA summits can resolve a
# real 2-letter state/province instead of falling back to a bare
# country code. Optional: some upstream snapshots may omit it, in
# which case region is simply written blank for every row.
my $i_region = $idx{RegionName};

if (defined $i_region) {
    print "Using 'RegionName' column for state/region\n";
} else {
    print "No 'RegionName' column found -- region will be blank for every summit\n";
}

open my $out_fh, '>:encoding(UTF-8)', $TMP or die "Cannot write $TMP: $!\n";
my $out_csv = Text::CSV_XS->new({ binary => 1, eol => "\n" });

# Write header matching the format load_lookup() in gen_onta.pl expects
$out_csv->print($out_fh, [qw(reference latitude longitude grid region)]);

my $count = 0;
while (my $row = $csv->getline($in_fh)) {
    my $ref = $row->[$i_code] // next;
    $ref =~ s/^\s+|\s+$//g;
    next unless length $ref;

    my $lon = $row->[$i_lon] // '';
    my $lat = $row->[$i_lat] // '';

    # Skip rows with no usable coordinates
    next unless length($lon) && length($lat);
    next unless $lon =~ /^-?\d+\.?\d*$/ && $lat =~ /^-?\d+\.?\d*$/;

    my $grid = latlon_to_grid($lat + 0, $lon + 0);

    my $region = defined($i_region) ? ($row->[$i_region] // '') : '';
    $region =~ s/^\s+|\s+$//g;

    $out_csv->print($out_fh, [$ref, $lat, $lon, $grid, $region]);
    $count++;
}

close $in_fh;
close $out_fh;

move($TMP, $OUT) or die "move failed $TMP -> $OUT: $!\n";

print "Written $count summits to $OUT\n";
