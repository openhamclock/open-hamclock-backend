#!/usr/bin/env perl
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
#  filter_amsat_active.pl
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
# filter_amsat_active.pl
# Reads a merged TLE cache built from AMSAT's daily Keplerian file and writes
# esats.txt containing ONLY the satellites listed in @SATS below, under the
# HamClock-facing names given there.
#
# Matching: by NORAD catalog number first, then by name (case/punctuation
# insensitive).  Satellites in @SATS that are not in the source are reported
# on STDERR and omitted; they appear automatically once AMSAT adds them.
#
# Env: ESATS_TLE_CACHE, ESATS_OUT        input / output paths
#      ESATS_WARN_DAYS  (7)              warn about elements older than this
#      ESATS_MAX_AGE_DAYS (0 = never)    drop elements older than this

use strict;
use warnings;
use Time::Local qw(timegm);

my $TLE_IN    = $ENV{ESATS_TLE_CACHE} // "/opt/hamclock-backend/tle/amsat-latest.txt";
my $TLE_OUT   = $ENV{ESATS_OUT}       // "/opt/hamclock-backend/htdocs/ham/HamClock/esats/esats.txt";
my $WARN_DAYS = $ENV{ESATS_WARN_DAYS}    // 7;
my $MAX_DAYS  = $ENV{ESATS_MAX_AGE_DAYS} // 0;

# [ output name, NORAD id (undef if unknown), alternate source names... ]
my @SATS = (
    ['AO-123',        61781, 'ASRTU-1'],
    ['AO-73',         39444, 'FUNCUBE-1'],
    ['AO-7',           7530, 'AO-07', 'OSCAR 7'],
    ['AO-91',         43017, 'RADFXSAT', 'FOX-1B'],
    ['ARICA-2',       68796, 'ARICA 2'],
    ['BALKAN-1',      undef],
    ['CO-128',        69912],
    ['CroCube',       62394],
    ['Erminaz-2U',    undef],
    ['FO-29',         24278, 'JAS-2'],
    ['GRBBeta',       60237],
    ['IO-86',         40931],
    ['ISS',           25544, 'ISS (ZARYA)'],
    ['TIANGONG',      48274, 'CSS (TIANHE-1)', 'CSS', 'TIANHE-1'],
    ['JAMX01',        undef, 'JAMX-01'],
    ['JO-97',         43803, 'JY1SAT'],
    ['KNACKSAT-2',    67683],
    ['KOSTKA',        undef],
    ['LASARsat',      62391],
    ['Luca',          67287, 'RS90S', 'LUCA (RS90S)'],   # Luca == RS90S
    ['Marina',        69920],
    ['OPTISAT',       undef],
    ['OTP-2',         63235],
    ['QO-100',        43700],                            # geostationary
    ['Replicator-2',  undef],
    ['RS-44',         44909],
    ['RS18S',         undef],
    ['RS38S',         57189, 'RS-38S'],
    ['RS40S',         57172, 'UMKA 1 (RS40S)'],
    ['RS57S',         57182],
    ['RS95S',         67291, 'RS95S (QMR-KWT-2)', 'QMR-KWT-2'],
    ['SO-50',         27607],
    ['SONATE-2',      59112],
    ['T.Microsat-1',  undef],
    ['TEVEL2-5',      63214],
    ['TEVEL2-9',      63237],
);

sub norm { my $s = uc(shift); $s =~ s/[^A-Z0-9]//g; return $s }

my (%by_norad, %by_name, @order);
for my $s (@SATS) {
    my ($out, $id, @alt) = @$s;
    push @order, $out;
    $by_norad{$id} = $out if defined $id;
    $by_name{ norm($_) } = $out for ($out, @alt);
}

open my $in, "<", $TLE_IN or die "Cannot open TLE file $TLE_IN: $!\n";
my @L = map { s/\r?\n$//r } <$in>;
close $in;

my $now = time;
my %best;
for (my $i = 0; $i + 2 <= $#L; $i++) {
    my ($n, $a, $b) = @L[$i, $i+1, $i+2];
    next unless $a =~ /^1\s/ && $b =~ /^2\s/ && $n !~ /^[12]\s/;
    my ($id) = $a =~ /^1\s+(\d+)/;
    next unless defined $id;
    $id =~ s/^0+(?=\d)//;
    $n  =~ s/^\s+|\s+$//g;
    my $out = $by_norad{$id} // $by_name{ norm($n) };
    if (defined $out) {
        my ($yy, $d) = (substr($a, 18, 2), substr($a, 20, 12));
        if ($d =~ /^\s*\d+\.\d+$/) {
            my $ep = timegm(0, 0, 0, 1, 0, 2000 + $yy) + ($d - 1) * 86400;
            $best{$out} = { ep => $ep, a => $a, b => $b }
                if !$best{$out} || $ep >= $best{$out}{ep};
        }
    }
    $i += 2;
}

open my $out, ">", $TLE_OUT or die "Cannot write $TLE_OUT: $!\n";
my (@missing, @stale, @dropped);
my $written = 0;
for my $name (@order) {
    my $e = $best{$name};
    unless ($e) { push @missing, $name; next }
    my $age = ($now - $e->{ep}) / 86400;
    if ($MAX_DAYS > 0 && $age > $MAX_DAYS) { push @dropped, sprintf("%s (%.0fd)", $name, $age); next }
    push @stale, sprintf("%s (%.1fd)", $name, $age) if $age > $WARN_DAYS;
    print $out "$name\n$e->{a}\n$e->{b}\n";
    $written++;
}
close $out;

print STDERR "Wrote $written of ", scalar(@order), " listed satellites to $TLE_OUT\n";
print STDERR "Not in source (omitted): ", join(", ", @missing), "\n" if @missing;
print STDERR "Elements older than ${WARN_DAYS}d: ", join(", ", @stale), "\n"   if @stale;
print STDERR "Dropped as too old (> ${MAX_DAYS}d): ", join(", ", @dropped), "\n" if @dropped;
