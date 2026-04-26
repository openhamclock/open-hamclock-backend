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
use LWP::UserAgent;
use URI;
use JSON::PP qw(decode_json);

# ---------------- Config ----------------
my $RBN_MAIN        = 'https://www.reversebeacon.net/main.php';
my $RBN_BASE        = 'https://www.reversebeacon.net/spots.php';
my $CACHE_FILE      = '/opt/hamclock-backend/cache/rbn_h_version.txt';
my $DEFAULT_MAXAGE  = 7200;   # seconds
my $DEFAULT_S       = 0;
my $DEFAULT_R       = 100;
my $TIMEOUT_SEC     = 20;
# ----------------------------------------

# --debug flag: print diagnostic info to STDERR instead of dying silently
my $DEBUG = (grep { $_ eq '--debug' } @ARGV) ? 1 : 0;

binmode STDOUT, ':encoding(ISO-8859-1)';

sub csv_error {
    my ($status, $msg) = @_;
    print header(-type => 'text/plain; charset=ISO-8859-1', -status => $status);
    print "ERROR: $msg\n";
    exit 0;
}

# --- Cache Helpers ---
sub get_cached_h {
    return undef unless -f $CACHE_FILE;
    open my $fh, '<', $CACHE_FILE or return undef;
    my $h = <$fh>;
    close $fh;
    $h =~ s/\s+//g;
    return $h;
}

sub save_cached_h {
    my $h = shift;
    open my $fh, '>', $CACHE_FILE or warn "Could not write cache: $!";
    if ($fh) { print $fh $h; close $fh; }
}

# ---------------------------------------------------------------------------
# Fetch the RBN main page and extract the current h= token from inline JS.
# Run with --debug to print the raw page to STDERR for inspection.
# ---------------------------------------------------------------------------
sub fetch_rbn_hash {
    my ($ua) = @_;

    my $resp = $ua->get($RBN_MAIN);
    unless ($resp->is_success) {
        warn "DEBUG: main.php fetch failed: " . $resp->status_line . "\n" if $DEBUG;
        return '';
    }

    my $html = $resp->decoded_content(charset => 'none');

    if ($DEBUG) {
        warn "DEBUG: main.php HTTP " . $resp->status_line . "\n";
        warn "DEBUG: main.php body (first 2000 chars):\n" . substr($html, 0, 2000) . "\n---\n";
    }

    # Pattern 1: window.RBN_version_hash = "9456de";  (current RBN site)
    if ($html =~ /RBN_version_hash\s*=\s*["']([0-9a-f]{4,})["']/) {
        warn "DEBUG: token found via RBN_version_hash: $1\n" if $DEBUG;
        return $1;
    }
    # Pattern 2: var h = '2aa296';  (older RBN site)
    if ($html =~ /\bvar\s+h\s*=\s*['"]([0-9a-f]{4,})['"]/) {
        warn "DEBUG: token found via var h: $1\n" if $DEBUG;
        return $1;
    }
    # Pattern 3: "h":"2aa296"
    if ($html =~ /"h"\s*:\s*"([0-9a-f]{4,})"/) {
        warn "DEBUG: token found via JSON h: $1\n" if $DEBUG;
        return $1;
    }
    # Pattern 4: ?h=2aa296 or &h=2aa296 in URLs
    if ($html =~ /[?&]h=([0-9a-f]{4,})/) {
        warn "DEBUG: token found via URL h=: $1\n" if $DEBUG;
        return $1;
    }

    warn "DEBUG: no token found in page\n" if $DEBUG;
    return '';   # could not find it
}

# Maidenhead (6-char) from lat/lon (decimal degrees)
sub latlon_to_maiden6 {
    my ($lat, $lon) = @_;
    return '' if !defined($lat) || !defined($lon);
    return '' if $lat !~ /^-?\d+(\.\d+)?$/ || $lon !~ /^-?\d+(\.\d+)?$/;

    my $A = $lon + 180.0;
    my $B = $lat +  90.0;

    return '' if $A < 0 || $A >= 360 || $B < 0 || $B > 180;

    my $field_lon  = int($A / 20);
    my $field_lat  = int($B / 10);

    my $rem_lon    = $A - ($field_lon * 20);
    my $rem_lat    = $B - ($field_lat * 10);

    my $square_lon = int($rem_lon / 2);
    my $square_lat = int($rem_lat / 1);

    $rem_lon = $rem_lon - ($square_lon * 2);
    $rem_lat = $rem_lat - ($square_lat * 1);

    my $sub_lon = int($rem_lon / (2.0 / 24.0));
    my $sub_lat = int($rem_lat / (1.0 / 24.0));

    my $Achr = chr(ord('A') + $field_lon);
    my $Bchr = chr(ord('A') + $field_lat);
    my $Echr = chr(ord('A') + $sub_lon);
    my $Fchr = chr(ord('A') + $sub_lat);

    return uc("$Achr$Bchr$square_lon$square_lat$Echr$Fchr");
}

# Mode heuristic: FT8/FT4 common dial freqs (Hz), else CW
sub guess_mode_from_hz {
    my ($hz) = @_;
    return 'CW' if !defined($hz) || $hz !~ /^\d+$/;

    my @ft8 = (
        1840000, 3573000, 5357000, 7074000, 10136000, 14074000,
        18100000, 21074000, 24915000, 28074000, 50313000, 144174000
    );
    my @ft4 = (
        3568000, 7047000, 10140000, 14080000, 18104000, 21140000, 28180000
    );

    my $tol = 2500;
    for my $f (@ft8) { return 'FT8' if abs($hz - $f) <= $tol; }
    for my $f (@ft4) { return 'FT4' if abs($hz - $f) <= $tol; }
    return 'CW';
}

# --------- Parse CGI inputs ----------
my @selectors = grep { defined param($_) && length(param($_)) }
                qw(ofcall bycall ofgrid bygrid);

csv_error(400, "Missing required parameter: one of ofcall, bycall, ofgrid, bygrid")
    if @selectors == 0;
csv_error(400, "Provide only ONE of: ofcall, bycall, ofgrid, bygrid")
    if @selectors > 1;

my $sel_name  = $selectors[0];
my $sel_value = param($sel_name);

my $maxage = param('maxage');
$maxage = $DEFAULT_MAXAGE if !defined($maxage) || $maxage eq '';
csv_error(400, "maxage must be integer seconds") if $maxage !~ /^\d+$/;
$maxage = int($maxage);

# --------- Build UA (browser-like headers help avoid 500s) ----------
my $ua = LWP::UserAgent->new(
    timeout      => $TIMEOUT_SEC,
    agent        => 'Mozilla/5.0 (compatible; fetchRBN/2.0)',
    cookie_jar   => {},   # accept session cookies from main.php
);
$ua->default_header('Accept'          => 'text/html,application/xhtml+xml,application/json,*/*;q=0.9');
$ua->default_header('Accept-Language' => 'en-US,en;q=0.9');
$ua->default_header('Referer'         => 'https://www.reversebeacon.net/main.php');

# --------- Obtain current h= token (Cache -> main.php) ----------
my $h_token = get_cached_h();
if (!$h_token) {
    warn "DEBUG: Cache miss, fetching from main.php\n" if $DEBUG;
    $h_token = fetch_rbn_hash($ua);
    save_cached_h($h_token) if $h_token;
}

# --------- Build query params to spots.php ----------
my %q = (
    ma => $maxage,
    s  => $DEFAULT_S,
    r  => $DEFAULT_R,
);
$q{h} = $h_token if $h_token;

if ($sel_name eq 'ofcall' || $sel_name eq 'bycall') {
    csv_error(400, "Invalid callsign format") if $sel_value !~ /^[A-Za-z0-9\/\-]+$/;
    my $call = uc($sel_value);

    if ($sel_name eq 'ofcall') {
        # spotted/DX station
        $q{cdx} = $call;
        # Do NOT send cde= at all when not filtering by spotter
    } else {
        # spotter/DE station
        $q{cde} = $call;
        # Do NOT send cdx= at all when not filtering by spotted
    }
}
elsif ($sel_name eq 'ofgrid' || $sel_name eq 'bygrid') {
    csv_error(400, "Grid filtering not implemented: RBN grid parameter names are unconfirmed.");
}
else {
    csv_error(400, "Unexpected selector parameter");
}

$q{lc} = 0;   # without lc=0, RBN returns only a baseline response with no spots

my $uri = URI->new($RBN_BASE);
$uri->query_form(%q);

# --------- Fetch JSON from spots.php ----------
# RBN spots.php is polling-based. Without lc=0 it only returns a baseline
# {lastid_c, now, ver_h}. Adding lc=0 returns all spots in the maxage window.
warn "DEBUG: fetching $uri\n" if $DEBUG;
my $resp = $ua->get($uri);

if (!$resp->is_success) {
    csv_error(502, "Upstream error: " . $resp->status_line
              . " (token=" . ($h_token||'none') . ", url=$uri)");
}

my $raw = $resp->decoded_content(charset => 'none');
if ($DEBUG) {
    warn "DEBUG: spots.php HTTP " . $resp->status_line . "\n";
    warn "DEBUG: spots.php body (first 500 chars): " . substr($raw, 0, 500) . "\n---\n";
}

if ($raw =~ /^\s*</) {
    csv_error(502, "Upstream returned HTML instead of JSON");
}

my $data;
eval { $data = decode_json($raw); 1 }
    or csv_error(502, "Non-JSON response: " . substr($raw, 0, 200));

# --------- Check for error 888 (Hash rotation) ----------
if ($data && $data->{error} && $data->{ver_h}) {
    warn "DEBUG: Hash expired, retrying with $data->{ver_h}\n" if $DEBUG;
    $h_token = $data->{ver_h};
    save_cached_h($h_token);
    
    $uri->query_form(%q, h => $h_token);
    $resp = $ua->get($uri);
    $raw = $resp->decoded_content(charset => 'none');
    eval { $data = decode_json($raw); 1 } or csv_error(502, "Retry failed");
}

my $spots     = $data->{spots}     || {};
my $call_info = $data->{call_info} || {};

# --------- Output CSV ----------
# Format: epoch_time,ofgrid,ofcall,degrid,decall,mode,hz,snr
print header(-type => 'text/plain; charset=ISO-8859-1', -status => 200);

for my $id (sort { $a <=> $b } keys %$spots) {
    my $a = $spots->{$id};
    next unless ref($a) eq 'ARRAY';

    # RBN spots.php array layout (observed):
    #   [0]=decall (spotter/DE), [1]=freq_kHz, [2]=cdx (spotted/DX),
    #   [3]=snr, ... [-1]=epoch_unix
    my $decall   = $a->[0] // '';
    my $freq_khz = $a->[1] // '';
    my $ofcall   = $a->[2] // '';
    my $snr      = $a->[3] // '';
    my $epoch    = $a->[-1] // '';

    # kHz -> Hz
    my $hz = '';
    if ($freq_khz =~ /^-?\d+(\.\d+)?$/) {
        $hz = int($freq_khz * 1000);
    }

    my $mode = guess_mode_from_hz($hz);

    # Grid squares from call_info lat/lon
    my $ofgrid = '';
    if ($ofcall && exists $call_info->{$ofcall}
            && ref($call_info->{$ofcall}) eq 'ARRAY') {
        my $lat = $call_info->{$ofcall}->[6];
        my $lon = $call_info->{$ofcall}->[7];
        $ofgrid = latlon_to_maiden6($lat, $lon);
    }

    my $degrid = '';
    if ($decall && exists $call_info->{$decall}
            && ref($call_info->{$decall}) eq 'ARRAY') {
        my $lat = $call_info->{$decall}->[6];
        my $lon = $call_info->{$decall}->[7];
        $degrid = latlon_to_maiden6($lat, $lon);
    }

    print join(',', $epoch, $ofgrid, $ofcall, $degrid, $decall, $mode, $hz, $snr) . "\n";
}
