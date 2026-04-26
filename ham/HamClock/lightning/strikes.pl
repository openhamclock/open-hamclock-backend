#!/usr/bin/perl -w

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

# strikes — filtered Blitzortung strike data for HamClock
#
# Called by HamClock as:
#   /ham/HamClock/lightning/strikes?lat=X&lon=Y&radius=N
#
# Reads the global cache written by blitzortung_daemon.py, filters to
# the user's DE location and radius, computes age at request time, and
# returns plain text one strike per line:
#   lat,lon,age_seconds
#
# Data attribution: Blitzortung.org (CC BY-SA 4.0)

use strict;
use warnings;
use JSON;

my $CACHE_FILE = '/opt/hamclock-backend/tmp/lightning_global.json';
my $MAX_AGE    = 900;   # seconds — must match LIGHTNING_MAX_AGE in lightning.cpp

# ---- parse query string --------------------------------------------------
my %q;
for my $pair (split /&/, ($ENV{QUERY_STRING} // '')) {
    my ($k, $v) = split /=/, $pair, 2;
    $q{$k} = $v if defined $k && defined $v;
}

my $lat    = (defined $q{lat}    && $q{lat}    =~ /^[+-]?\d{1,3}(\.\d+)?$/) ? $q{lat}+0    : undef;
my $lon    = (defined $q{lon}    && $q{lon}    =~ /^[+-]?\d{1,3}(\.\d+)?$/) ? $q{lon}+0    : undef;
my $radius = (defined $q{radius} && $q{radius} =~ /^\d{1,5}$/)              ? $q{radius}+0 : 500;
my $maxage = (defined $q{maxage} && $q{maxage} =~ /^\d{1,5}$/)              ? $q{maxage}+0 : $MAX_AGE;

print "Content-Type: text/plain\r\n\r\n";

# Return empty if no location or cache not yet written
unless (defined $lat && defined $lon && -f $CACHE_FILE) {
    exit;
}

# ---- read cache ----------------------------------------------------------
my $data = eval {
    open my $fh, '<', $CACHE_FILE or die "open: $!";
    local $/;
    decode_json(<$fh>);
};
if ($@ || !$data || !$data->{strikes}) {
    exit;
}

# ---- filter and output ---------------------------------------------------
my $now_ms = time() * 1000;
my $lat1   = $lat * 3.14159265358979 / 180;

for my $s (@{$data->{strikes}}) {
    # Age in whole seconds at time of this request
    my $age_s = int(($now_ms - $s->{strikeTime}) / 1000);
    next if $age_s < 0 || $age_s > $maxage;

    # Haversine distance in km
    my $dlat = ($s->{lat} - $lat) * 3.14159265358979 / 180;
    my $dlon = ($s->{lon} - $lon) * 3.14159265358979 / 180;
    my $lat2 = $s->{lat} * 3.14159265358979 / 180;
    my $a    = sin($dlat/2)**2 + cos($lat1) * cos($lat2) * sin($dlon/2)**2;
    my $km   = 6371 * 2 * atan2(sqrt($a), sqrt(1-$a));

    next if $km > $radius;

    printf("%.4f,%.4f,%d\n", $s->{lat}, $s->{lon}, $age_s);
}
