#!/usr/bin/perl -w
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
