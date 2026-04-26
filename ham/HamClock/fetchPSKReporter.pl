#!/usr/bin/perl

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

# fetchPSKReporter.pl — HamClock backend PSKReporter proxy
#
# Proxies requests to the pskr-mqtt-cache service 
#
# CGI parameters:
#   bygrid   — filter by sender grid prefix     (e.g. EL97 or EL97ab)
#   ofgrid   — filter by receiver grid prefix   (e.g. EL97 or EL97ab)
#   bycall   — filter by sender callsign        (e.g. W4BLD)
#   ofcall   — filter by receiver callsign      (e.g. KO4AQF)
#   maxage   — return spots newer than this many seconds (default 900, max 86400)
#
# Output format (one spot per line):
#   flowStartSeconds,senderLocator,senderCallsign,receiverLocator,receiverCallsign,mode,frequency,sNR

use strict;
use warnings;
use CGI;
use LWP::UserAgent;
use URI;

my $CACHE_SERVICE = "http://pskr-mqtt-cache:5000";
my $TIMEOUT       = 10;   # seconds

my $q = CGI->new;

my $bygrid = uc($q->param('bygrid') // '');
my $ofgrid = uc($q->param('ofgrid') // '');
my $bycall = uc($q->param('bycall') // '');
my $ofcall = uc($q->param('ofcall') // '');

my $maxage = $q->param('maxage');
$maxage = 900 if (!defined $maxage || $maxage eq '');
$maxage =~ s/\D//g;
$maxage = int($maxage || 900);
$maxage = 60    if $maxage < 60;
$maxage = 86400 if $maxage > 86400;

print $q->header(-type => 'text/plain; charset=ISO-8859-1');

if (!$bygrid && !$ofgrid && !$bycall && !$ofcall) {
    print "Error: at least one of bygrid, ofgrid, bycall, or ofcall is required.\n";
    exit;
}

sub valid_grid {
    my ($g) = @_;
    return 0 if !defined $g || $g eq '';
    return ($g =~ /^[A-R]{2}[0-9]{2}([A-X]{2})?$/) ? 1 : 0;
}

sub valid_call {
    my ($c) = @_;
    return 0 if !defined $c || $c eq '';
    return ($c =~ /^[A-Z0-9\/]{3,15}$/) ? 1 : 0;
}

if ($bygrid && !valid_grid($bygrid)) {
    print "Error: invalid bygrid locator.\n";
    exit;
}
if ($ofgrid && !valid_grid($ofgrid)) {
    print "Error: invalid ofgrid locator.\n";
    exit;
}
if ($bycall && !valid_call($bycall)) {
    print "Error: invalid bycall callsign.\n";
    exit;
}
if ($ofcall && !valid_call($ofcall)) {
    print "Error: invalid ofcall callsign.\n";
    exit;
}

my $uri = URI->new("$CACHE_SERVICE/spots");
$uri->query_form(
    ($bygrid ? (bygrid => $bygrid) : ()),
    ($ofgrid ? (ofgrid => $ofgrid) : ()),
    ($bycall ? (bycall => $bycall) : ()),
    ($ofcall ? (ofcall => $ofcall) : ()),
    maxage => $maxage,
);

my $ua = LWP::UserAgent->new(timeout => $TIMEOUT);
my $resp = $ua->get($uri->as_string);

if ($resp->is_success) {
    print $resp->decoded_content;
} else {
    print STDERR sprintf("pskr-cache error: %s %s\n", $resp->code, $resp->message);
    print "Error: spot cache unavailable — please try again shortly.\n";
}

exit;
