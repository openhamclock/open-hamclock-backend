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
#  fetchRBN.pl
#
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
#
# ============================================================
use strict;
use warnings;

use CGI qw(param header);
use IO::Socket::INET;
use JSON::PP;
use Time::Local qw(timegm);

# ---------------- Config ----------------
my $DXSPIDER_HOST   = '44.32.64.9';
my $DXSPIDER_PORT   = 9000;
my $DEFAULT_MAXAGE  = 7200;
my $TIMEOUT_SEC     = 15;
my $CTY_FILE        = '/opt/hamclock-backend/htdocs/ham/HamClock/cty/cty_wt_mod-ll-dxcc.txt';
# ----------------------------------------

binmode STDOUT, ':encoding(ISO-8859-1)';

sub csv_error {
    my ($status, $msg) = @_;
    print header(-type => 'text/plain; charset=ISO-8859-1', -status => $status);
    print "ERROR: $msg\n";
    exit 0;
}

# Convert ISO-8601 "2026-05-10T20:14:00" (assumed UTC) to epoch seconds.
sub iso_to_epoch {
    my ($iso) = @_;
    return '' unless defined $iso;
    if ($iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        return timegm($6, $5, $4, $3, $2 - 1, $1 - 1900);
    }
    return '';
}

# 6-char Maidenhead from lat/lon (decimal degrees, east-positive).
sub latlon_to_maiden6 {
    my ($lat, $lon) = @_;
    return '' if !defined($lat) || !defined($lon);
    return '' if $lat !~ /^-?\d+(\.\d+)?$/ || $lon !~ /^-?\d+(\.\d+)?$/;

    my $A = $lon + 180.0;
    my $B = $lat +  90.0;
    return '' if $A < 0 || $A >= 360 || $B < 0 || $B > 180;

    my $field_lon = int($A / 20);
    my $field_lat = int($B / 10);
    my $rem_lon   = $A - ($field_lon * 20);
    my $rem_lat   = $B - ($field_lat * 10);

    my $sq_lon = int($rem_lon / 2);
    my $sq_lat = int($rem_lat / 1);
    $rem_lon  -= ($sq_lon * 2);
    $rem_lat  -= ($sq_lat * 1);

    my $sub_lon = int($rem_lon / (2.0 / 24.0));
    my $sub_lat = int($rem_lat / (1.0 / 24.0));

    return uc(
        chr(ord('A') + $field_lon) .
        chr(ord('A') + $field_lat) .
        $sq_lon . $sq_lat .
        chr(ord('A') + $sub_lon) .
        chr(ord('A') + $sub_lat)
    );
}

# Load the cty file into a hash: prefix/callsign => [lat, lon].
# Header treats the lon column as east-positive (positive = east, negative = west)
# despite the "lng+W" label, since spot-checks (e.g. 1A = Rome = +12.43) confirm.
my %CTY;
sub load_cty {
    my ($file) = @_;
    open my $fh, '<', $file or return 0;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;
        # whitespace-separated: prefix lat lon dxcc
        my @f = split ' ', $line;
        next unless @f >= 3;
        my ($pfx, $lat, $lon) = @f;
        next unless $lat =~ /^-?\d+(\.\d+)?$/ && $lon =~ /^-?\d+(\.\d+)?$/;
        $CTY{uc $pfx} = [ $lat + 0, $lon + 0 ];
    }
    close $fh;
    return 1;
}

# Longest-match prefix lookup: try the full call, then shorten until a hit.
sub call_to_grid {
    my ($call) = @_;
    return '' unless defined $call && length $call;
    $call = uc $call;

    # RBN skimmer callsigns often have a "-#" suffix (e.g. WC2L-#). Strip it.
    $call =~ s/-#$//;
    # Also strip any other "-suffix" (portable indicators like /P are usually
    # before any -; skimmer self-spots use -# or -1 etc.)
    $call =~ s/-\w+$//;

    # Try progressively shorter prefixes.
    for (my $len = length($call); $len >= 1; $len--) {
        my $key = substr($call, 0, $len);
        if (exists $CTY{$key}) {
            my ($lat, $lon) = @{ $CTY{$key} };
            return latlon_to_maiden6($lat, $lon);
        }
    }
    return '';
}

load_cty($CTY_FILE);  # silent failure ok; grids will just be empty

# --------- Parse CGI inputs ----------
my @selectors = grep { defined param($_) && length(param($_)) } qw(ofcall bycall ofgrid bygrid);
csv_error(400, "Missing required parameter: one of ofcall, bycall, ofgrid, bygrid") if @selectors == 0;
csv_error(400, "Provide only ONE of: ofcall, bycall, ofgrid, bygrid")                if @selectors > 1;

my $sel_name  = $selectors[0];
my $sel_value = param($sel_name);

my $maxage = param('maxage');
$maxage = $DEFAULT_MAXAGE if !defined($maxage) || $maxage eq '';
csv_error(400, "maxage must be integer seconds") if $maxage !~ /^\d+$/;
$maxage = int($maxage);

my $field;
if    ($sel_name eq 'ofcall') { $field = 'ofcall'; }
elsif ($sel_name eq 'bycall') { $field = 'bycall'; }
else {
    csv_error(400, "Grid filtering not supported by dxspider feed (use ofcall or bycall).");
}

csv_error(400, "Invalid callsign format") if $sel_value !~ /^[A-Za-z0-9\/\-]+$/;
my $call = uc($sel_value);

# --------- Send request (no mode = all modes) ----------
my $req = {
    field  => $field,
    data   => $call,
    maxage => $maxage + 0,
};

my $sock = IO::Socket::INET->new(
    PeerHost => $DXSPIDER_HOST,
    PeerPort => $DXSPIDER_PORT,
    Proto    => 'tcp',
    Timeout  => $TIMEOUT_SEC,
);
csv_error(502, "Could not connect to dxspider feed at $DXSPIDER_HOST:$DXSPIDER_PORT: $!") unless $sock;

$sock->autoflush(1);
print $sock encode_json($req) . "\n";

my $raw = '';
eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm $TIMEOUT_SEC;
    while (my $line = <$sock>) {
        $raw .= $line;
    }
    alarm 0;
};
close $sock;

csv_error(502, "Empty response from dxspider feed") unless length $raw;

my $data;
eval { $data = decode_json($raw); 1 } or csv_error(502, "Could not parse JSON from dxspider: $@");

csv_error(502, "dxspider feed returned status: " . ($data->{status} // 'unknown'))
    unless ($data->{status} // '') eq 'ok';

my $results = $data->{results} || [];

# Sort oldest first for stable output.
my @sorted = sort {
    ($a->{spotted_at} // '') cmp ($b->{spotted_at} // '')
} @$results;

# --------- Emit CSV in OHB format ----------
# Columns: epoch_time, ofgrid, ofcall, degrid, decall, mode, hz, snr
print header(-type => 'text/plain; charset=ISO-8859-1', -status => 200);

for my $spot (@sorted) {
    next unless ref $spot eq 'HASH';

    my $epoch  = iso_to_epoch($spot->{spotted_at});
    my $ofcall = $spot->{dx_call}      // '';
    my $decall = $spot->{spotter_call} // '';

    # DX-end grid: prefer what dxspider sent (FT4/FT8 carry it), fall back to cty lookup.
    my $ofgrid = $spot->{grid} // '';
    $ofgrid = call_to_grid($ofcall) if $ofgrid eq '';

    # Spotter grid: cty lookup on the skimmer call.
    my $degrid = call_to_grid($decall);

    my $smode  = uc($spot->{mode} // '');
    my $snr    = $spot->{snr_db};
    $snr = '' unless defined $snr;

    my $hz = '';
    my $khz = $spot->{frequency_khz};
    if (defined $khz && $khz =~ /^-?\d+(\.\d+)?$/) {
        $hz = int($khz * 1000);
    }

    print join(',', $epoch, $ofgrid, $ofcall, $degrid, $decall, $smode, $hz, $snr) . "\n";
}

exit 0;
