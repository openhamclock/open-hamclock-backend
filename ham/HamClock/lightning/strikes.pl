#!/usr/bin/perl -w
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
#  strikes.pl
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
#
# lightning/strikes.pl — Blitzortung strike data for HamClock
#
# With no params: returns all strikes worldwide
# With ?lat=X&lon=Y&radius=N: returns strikes within radius km of lat/lon

use strict;
use warnings;
use JSON;

my $CACHE_FILE = '/opt/hamclock-backend/tmp/lightning_global.json';
my $MAX_AGE    = 600;  # seconds - should match LIGHTNING_MAX_AGE in HamClock

my %q;
for my $pair (split /&/, ($ENV{QUERY_STRING} // '')) {
    my ($k, $v) = split /=/, $pair, 2;
    $q{$k} = $v if defined $k && defined $v;
}

my $lat    = (defined $q{lat}    && $q{lat}    =~ /^[+-]?\d{1,3}(\.\d+)?$/) ? $q{lat}+0    : undef;
my $lon    = (defined $q{lon}    && $q{lon}    =~ /^[+-]?\d{1,3}(\.\d+)?$/) ? $q{lon}+0    : undef;
my $radius = (defined $q{radius} && $q{radius} =~ /^\d{1,5}$/)              ? $q{radius}+0 : undef;
my $maxage = (defined $q{maxage} && $q{maxage} =~ /^\d+$/)                  ? $q{maxage}+0 : $MAX_AGE;

# Radius filter only applies when lat, lon AND radius are all provided
my $do_filter = (defined $lat && defined $lon && defined $radius && $radius > 0);

print "Content-Type: text/plain\r\n\r\n";

unless (-f $CACHE_FILE) {
    exit;
}

my $data = eval {
    open my $fh, '<', $CACHE_FILE or die;
    local $/;
    decode_json(<$fh>);
};
exit if $@ || !$data || !$data->{strikes};

my $now_ms = time() * 1000;
my $lat1   = $do_filter ? $lat * 3.14159265358979 / 180 : 0;

for my $s (@{$data->{strikes}}) {
    my $age_s = int(($now_ms - $s->{strikeTime}) / 1000);
    next if $age_s < 0 || $age_s > $maxage;

    if ($do_filter) {
        my $dlat = ($s->{lat} - $lat) * 3.14159265358979 / 180;
        my $dlon = ($s->{lon} - $lon) * 3.14159265358979 / 180;
        my $lat2 = $s->{lat} * 3.14159265358979 / 180;
        my $a    = sin($dlat/2)**2 + cos($lat1)*cos($lat2)*sin($dlon/2)**2;
        my $km   = 6371 * 2 * atan2(sqrt($a), sqrt(1-$a));
        next if $km > $radius;
    }

    printf("%.4f,%.4f,%d\n", $s->{lat}, $s->{lon}, $age_s);
}
