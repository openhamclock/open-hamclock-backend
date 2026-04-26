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
#  split_onta.pl
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
# split_onta.pl -- splits onta.txt into pota-activators.txt,
#                  sota-activators.txt, wwff-activators.txt

use strict;
use warnings;
use POSIX qw(strftime);
use File::Copy qw(move);
use File::Path qw(make_path);

my $ONTA   = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/onta.txt';
my $OUTDIR = '/opt/hamclock-backend/htdocs/ham/HamClock';

my %files = (
    POTA => "$OUTDIR/POTA/pota-activators.txt",
    SOTA => "$OUTDIR/SOTA/sota-activators.txt",
    WWFF => "$OUTDIR/WWFF/wwff-activators.txt",
);

my %headers = (
    POTA => "#call,Hz,iso-utc,mode,grid,lat,lng,park-id\n",
    SOTA => "#call,Hz,iso-utc,mode,grid,lat,lng,summit-code\n",
    WWFF => "#call,Hz,iso-utc,mode,grid,lat,lng,wwff-ref\n",
);

my %rows = ( POTA => [], SOTA => [], WWFF => [] );

# Create output subdirs if they don't exist
for my $org (keys %files) {
    make_path("$OUTDIR/$org") unless -d "$OUTDIR/$org";
}

open my $in, '<', $ONTA or die "Cannot read $ONTA: $!\n";

while (<$in>) {
    next if /^#/;
    chomp;
    my ($call, $hz, $epoch, $mode, $grid, $lat, $lng, $park, $org) =
        split /,/, $_, 9;
    next unless defined $org && exists $rows{$org};

    my $iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($epoch));

    push @{ $rows{$org} },
        join(',', $call, $hz, $iso, $mode, $grid, $lat, $lng, $park) . "\n";
}

close $in;

for my $org (keys %files) {
    my $tmp = $files{$org} . '.tmp';
    open my $fh, '>', $tmp or die "Cannot write $tmp: $!\n";
    print $fh $headers{$org};
    print $fh $_ for @{ $rows{$org} };
    close $fh;
    move $tmp, $files{$org} or die "move failed: $tmp -> $files{$org}: $!\n";
    printf "%s: %d spots\n", $org, scalar @{ $rows{$org} };
}
