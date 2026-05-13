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
#  gen_onta.pl -- POTA / SOTA / WWFF on-the-air spot aggregator
#
#  Part of the OHB project:
#  https://github.com/komacke/open-hamclock-backend/tree/main
#
#  Fetches live activator spots from POTA, SOTA (via Parks'n'Peaks),
#  and WWFF (via the OHB central mirror by default), deduplicates,
#  resolves grid/lat/lng from cached reference CSVs, and writes
#  onta.txt for HamClock consumption.
#
#  WWFF NOTE: Per request from Mario, DL4MFM (https://www.cqgma.org),
#  the GMA WWFF API is rate limited to 1 req/min and 1440 req/day per
#  client. OHB no longer polls cqgma.org from every installation.
#  Instead, the OHB central host runs fetch_wwff_cache.pl once per
#  minute and serves the result to all OHB clients (central and
#  self-install) via $WWFF_URL below.
#
#  To override (e.g. on the central host itself, or for testing),
#  set the OHB_WWFF_URL environment variable. Accepts http(s)://,
#  file://, or a bare filesystem path.
#
#  *** Please do NOT set OHB_WWFF_URL to https://www.cqgma.org/... ***
#  *** on a self-install. That defeats the purpose of the mirror. ***
##
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
use Time::Local;
use Text::CSV_XS;
use File::Copy qw(move);

my $POTA_URL = 'https://api.pota.app/spot';
my $SOTA_URL = 'https://parksnpeaks.org/api/ALL';

# WWFF source: defaults to the OHB central mirror. Override via env if needed.
# *** Update this default URL to point at your project's actual mirror host ***
my $WWFF_URL = $ENV{OHB_WWFF_URL}
    // 'https://ohb.hamclock.app/ham/HamClock/ONTA/wwff_spots.json';

my $OUT      = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/onta.txt';
my $TMP      = "$OUT.tmp";

my $POTA_CSV = '/opt/hamclock-backend/cache/all_parks_ext.csv';
my $SOTA_CSV = '/opt/hamclock-backend/cache/sota_summits.csv';
my $WWFF_CSV = '/opt/hamclock-backend/cache/wwff_parks.csv';

my %csv_generators = (
    $POTA_CSV => '/opt/hamclock-backend/scripts/update_pota_parks_cache.sh',
    $SOTA_CSV => '/opt/hamclock-backend/scripts/update_sota_cache.pl',
    $WWFF_CSV => '/opt/hamclock-backend/scripts/update_wwff_cache.pl',
);

# HamClock rejects callsigns longer than 12 characters
my $MAX_CALL  = 12;
# Parks'n'Peaks returns up to ~4 hours of history so match that window.
# POTA spots older than 1h will simply be deduped by fresher ones.
my $MAX_AGE_S = 14400;

sub org_from_ref {
    my ($ref) = @_;
    return 'WWFF' if defined($ref) && $ref =~ /^[A-Z]{1,4}FF-/i;
    return 'SOTA' if defined($ref) && $ref =~ m{/};     # e.g. W7O/NC-051
    return 'POTA';
}

# ---------------------------------------------------------------------------
# Load a reference lookup CSV into a hash keyed by reference string.
# Expects columns: reference, latitude, longitude, grid
# ---------------------------------------------------------------------------
sub load_lookup {
    my ($path) = @_;
    my %park;

    return %park unless -f $path;

    open my $fh, '<:encoding(UTF-8)', $path or do {
        warn "Cannot read $path: $!\n";
        return %park;
    };

    my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });

    my $header = $csv->getline($fh);
    unless ($header && @$header) {
        warn "Empty or unreadable header in $path\n";
        close $fh;
        return %park;
    }

    my %idx;
    for my $i (0 .. $#$header) {
        my $k = $header->[$i] // next;
        $k =~ s/^"|"$//g;
        $idx{$k} = $i;
    }

    for my $need (qw(reference latitude longitude grid)) {
        unless (exists $idx{$need}) {
            warn "Missing '$need' column in $path\n";
            close $fh;
            return %park;
        }
    }

    while (my $row = $csv->getline($fh)) {
        my $ref = $row->[$idx{reference}] // next;
        $ref =~ s/^"|"$//g;

        $park{$ref} = {
            lat  => ($row->[$idx{latitude}]  // ''),
            lng  => ($row->[$idx{longitude}] // ''),
            grid => ($row->[$idx{grid}]      // ''),
        };
    }

    close $fh;
    return %park;
}

# ---------------------------------------------------------------------------
# Fetch a resource that may be HTTP(S), file://, or a bare local path.
# Returns the body string on success, undef on failure.
# ---------------------------------------------------------------------------
sub fetch_source {
    my ($url, $ua, $label) = @_;

    # Local file path or file:// URL: read directly, no HTTP traffic
    if ($url =~ m{^file://(.+)$} || $url =~ m{^(/.+)$}) {
        my $path = $1;
        unless (-f $path) {
            warn "$label local file not found: $path\n";
            return undef;
        }
        open my $fh, '<', $path or do {
            warn "$label cannot read $path: $!\n";
            return undef;
        };
        local $/;
        my $body = <$fh>;
        close $fh;
        return $body;
    }

    # HTTP(S)
    my $resp = $ua->get($url);
    unless ($resp->is_success) {
        warn "$label fetch failed: " . $resp->status_line . "\n";
        return undef;
    }
    return $resp->decoded_content;
}

foreach my $file (keys %csv_generators) {
    unless (-e $file) {
        my $script = $csv_generators{$file};
        print "Missing $file. Running $script...\n";

        # Execute the specific script
        system("perl $script");

        # Verify the script actually created the file
        if ($? != 0 || !-e $file) {
            print "Error: Failed to generate $file using $script (Exit code: $?). Continuing.\n";
        }
    }
}
my %pota_lookup = load_lookup($POTA_CSV);
my %sota_lookup = load_lookup($SOTA_CSV);
my %wwff_lookup = load_lookup($WWFF_CSV);

# Merge into one hash; POTA takes precedence over WWFF, WWFF over SOTA
# for any ref that somehow appears in multiple sources.
my %park_lookup = (%sota_lookup, %wwff_lookup, %pota_lookup);

my $ua = LWP::UserAgent->new(
    timeout => 10,
    agent   => 'OHB/1.1 (+https://github.com/komacke/open-hamclock-backend)',
);

my $now = time();
my %best;   # dedup key -> row hashref
my %counts = ( pota => 0, sota => 0, wwff => 0 );

# ---------------------------------------------------------------------------
# Helper: attempt to resolve location for a park/summit reference.
# Returns (grid, lat, lng) — all empty/zero if not found.
# ---------------------------------------------------------------------------
sub resolve_location {
    my ($ref) = @_;
    return ('', 0, 0) unless $ref && exists $park_lookup{$ref};
    return (
        $park_lookup{$ref}{grid} // '',
        $park_lookup{$ref}{lat}  // 0,
        $park_lookup{$ref}{lng}  // 0,
    );
}

# ---------------------------------------------------------------------------
# Source 1: POTA  (https://api.pota.app/spot)
# Fields: activator, frequency (kHz), mode, reference, spotTime (ISO8601 UTC)
# ---------------------------------------------------------------------------
{
    my $body = fetch_source($POTA_URL, $ua, 'POTA');
    if (defined $body) {
        my $spots = eval { decode_json($body) };
        if ($@) {
            warn "POTA JSON parse failed: $@\n";
        } elsif (ref $spots eq 'ARRAY') {
            for my $s (@$spots) {
                next unless ref $s eq 'HASH';

                my $call = $s->{activator} // next;
                next if length($call) > $MAX_CALL;
                my $freq = $s->{frequency} // next;   # kHz
                my $mode = $s->{mode}      // '';
                my $park = $s->{reference} // '';
                my $time = $s->{spotTime}  // next;

                my ($Y,$m,$d,$H,$M,$S) =
                    $time =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/
                    or next;

                my $epoch = timegm($S,$M,$H,$d,$m-1,$Y);
                next if ($now - $epoch) > $MAX_AGE_S;

                my $hz = int((0 + $freq) * 1000);
                next unless $hz > 0 && $hz <= 1_300_000_000;  # sanity: max ~1.3 GHz

                my $org = org_from_ref($park);

                my ($grid, $lat, $lng) = resolve_location($park);

                # Skip if HamClock would reject it (no location data)
                next unless $grid || ($lat != 0 && $lng != 0);

                my $key = join('|', $call, $park, $mode, $hz, $org);

                if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
                    $best{$key} = {
                        call  => $call,
                        hz    => $hz,
                        epoch => $epoch,
                        mode  => $mode,
                        grid  => $grid,
                        lat   => $lat,
                        lng   => $lng,
                        park  => $park,
                        org   => $org,
                    };
                    $counts{pota}++;
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Source 2: SOTA via Parks'n'Peaks  (https://parksnpeaks.org/api/ALL)
# Fields: actCallsign, actFreq (MHz), actMode, actSiteID, actClass,
#         actTime ("YYYY-MM-DD HH:MM:SS" UTC)
# ---------------------------------------------------------------------------
{
    my $body = fetch_source($SOTA_URL, $ua, 'SOTA');
    if (defined $body) {
        my $spots = eval { decode_json($body) };
        if ($@) {
            warn "Parks'n'Peaks JSON parse failed: $@\n";
        } elsif (ref $spots eq 'ARRAY') {
            for my $s (@$spots) {
                next unless ref $s eq 'HASH';

                my $cls = uc($s->{actClass} // '');
                next unless $cls eq 'SOTA';

                my $call = $s->{actCallsign} // next;
                next if length($call) > $MAX_CALL;
                my $freq = $s->{actFreq}     // next;   # MHz
                my $mode = $s->{actMode}     // '';
                my $time = $s->{actTime}     // next;
                my $park = $s->{actSiteID}   // '';

                # Parse "YYYY-MM-DD HH:MM:SS"
                my ($Y,$m,$d,$H,$M,$S) =
                    $time =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/
                    or next;

                my $epoch = timegm($S,$M,$H,$d,$m-1,$Y);
                next if ($now - $epoch) > $MAX_AGE_S;

                next unless length($freq) && $freq > 0;
                my $hz = int($freq * 1_000_000 + 0.5);
                next unless $hz > 0 && $hz <= 1_300_000_000;

                my ($grid, $lat, $lng) = resolve_location($park);
                next unless $grid || ($lat != 0 && $lng != 0);

                my $key = join('|', $call, $park, $mode, $hz, 'SOTA');

                if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
                    $best{$key} = {
                        call  => $call,
                        hz    => $hz,
                        epoch => $epoch,
                        mode  => $mode,
                        grid  => $grid,
                        lat   => $lat,
                        lng   => $lng,
                        park  => $park,
                        org   => 'SOTA',
                    };
                    $counts{sota}++;
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Source 3: WWFF — via OHB central mirror by default (set via $WWFF_URL).
#
# The mirror serves the raw cqgma.org JSON body unchanged, so the parsing
# below is identical to a direct GMA fetch.
#
# Fields: ACTIVATOR, QRG (MHz), MODE, REF, LAT, LON, DATE ("YYYYMMDD"),
#         TIME ("HHMM" UTC)
# Location is embedded in each spot — no cache lookup needed.
# ---------------------------------------------------------------------------
{
    my $body = fetch_source($WWFF_URL, $ua, 'WWFF');
    if (defined $body) {
        my $data = eval { decode_json($body) };
        if ($@) {
            warn "WWFF JSON parse failed: $@\n";
        } else {
        my $spots = $data->{RCD} // [];
        for my $s (@$spots) {
            next unless ref $s eq 'HASH';

            my $call = uc($s->{ACTIVATOR} // '');
            $call =~ s/^\s+|\s+$//g;
            next unless length $call;
            next if length($call) > $MAX_CALL;

            my $freq = $s->{QRG}  // next;   # kHz
            my $mode = uc($s->{MODE} // '');
            next unless length $mode;         # skip spots with no mode

            my $park = $s->{REF}  // next;
            my $lat  = $s->{LAT}  // next;
            my $lon  = $s->{LON}  // next;
            my $date = $s->{DATE} // next;   # YYYYMMDD
            my $time = $s->{TIME} // next;   # HHMM

            next unless length($freq) && $freq > 0;
            my $hz = int($freq * 1000);      # kHz -> Hz
            next unless $hz > 0 && $hz <= 1_300_000_000;

            next unless $date =~ /^(\d{4})(\d{2})(\d{2})$/ ;
            my ($Y, $m, $d) = ($1, $2, $3);
            next unless $time =~ /^(\d{2})(\d{2})$/;
            my ($H, $M) = ($1, $2);

            my $epoch = eval { timegm(0, $M, $H, $d, $m-1, $Y) } or next;
            next if ($now - $epoch) > $MAX_AGE_S;

            next unless length($lat) && length($lon);
            next unless $lat =~ /^-?\d+\.?\d*$/ && $lon =~ /^-?\d+\.?\d*$/;

            # Compute 4-char Maidenhead grid from embedded coordinates
            use POSIX qw(floor);
            my $grid = do {
                my $alon = $lon + 180.0;
                my $alat = $lat + 90.0;
                my $fl = floor($alon / 20);
                my $fla = floor($alat / 10);
                my $sl = floor(($alon - $fl * 20) / 2);
                my $sla = floor($alat - $fla * 10);
                sprintf('%s%s%d%d',
                    chr(ord('A') + $fl),
                    chr(ord('A') + $fla),
                    $sl, $sla);
            };

            my $key = join('|', $call, $park, $mode, $hz, 'WWFF');

            if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
                $best{$key} = {
                    call  => $call,
                    hz    => $hz,
                    epoch => $epoch,
                    mode  => $mode,
                    grid  => $grid,
                    lat   => $lat,
                    lng   => $lon,
                    park  => $park,
                    org   => 'WWFF',
                };
                $counts{wwff}++;
            }
        }
        } # end JSON parse else
    }
}

# ---------------------------------------------------------------------------
# Sort newest-first, cap, write output
# ---------------------------------------------------------------------------
my @out = sort { $b->{epoch} <=> $a->{epoch} } values %best;

open my $fh, '>', $TMP or die "Cannot write temp file $TMP: $!\n";
print $fh "#call,Hz,unix,mode,grid,lat,lng,park,org\n";

for my $r (@out) {
    print $fh join(',',
        $r->{call},
        $r->{hz},
        $r->{epoch},
        $r->{mode},
        $r->{grid},
        $r->{lat},
        $r->{lng},
        $r->{park},
        $r->{org},
    ), "\n";
}

close $fh;

print "--- Processing Complete ---\n";
print "POTA records: $counts{pota}\n";
print "SOTA records: $counts{sota}\n";
print "WWFF records: $counts{wwff}\n";
print "WWFF source : $WWFF_URL\n";
print "Total unique spots written to $TMP: " . scalar(@out) . "\n";

move $TMP, $OUT or die "move failed $TMP -> $OUT: $!\n";
