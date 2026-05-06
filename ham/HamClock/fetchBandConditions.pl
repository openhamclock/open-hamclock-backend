#!/usr/bin/perl
#
# fetchBandConditions.pl - HamClock band conditions proxy to voacap-service
#
# Replaces the original VOACAP-calling implementation with a thin HTTP proxy
# that forwards all query parameters to the voacap-service container and
# streams the response back to HamClock unchanged.
#
# The voacap-service handles all VOACAP execution, concurrency, and output
# formatting. This script is a drop-in replacement — HamClock sees identical
# wire protocol output.
#
# Query parameters (all required, passed through verbatim):
# YEAR, MONTH, RXLAT, RXLNG, TXLAT, TXLNG, PATH, POW, MODE, TOA
# SSN (optional - if omitted, voacap-service uses ssn-31.txt or estimates)
#
# Configuration (environment variables):
# VOACAP_SERVICE_URL Base URL of the voacap-service
# Default: http://voacap-service:8080
#
# Author: Open HamClock Backend (OHB) project
# License: AGPLv3

use strict;
use warnings;
use LWP::UserAgent;

# —————————————————————————
# Configuration
# —————————————————————————

my $SERVICE_URL = $ENV{VOACAP_SERVICE_URL} || 'http://voacap-service:8080';
my $ENDPOINT = "$SERVICE_URL/fetchBandConditions";

# Timeout layers (shortest first):
#   Python subprocess(voacapl)  = 30s   (voacap_service.py)
#   nginx uwsgi_read_timeout    = 45s   (nginx.conf)
#   This LWP timeout            = 45s   <-- matches nginx so we give up together
#   lighttpd server.max-read-idle ~ 60s (default)
#   uWSGI harakiri              = 300s  (uwsgi.ini)
# 15s of slack over the 30s subprocess lets Python's TimeoutExpired handler
# fire first and return a clean error rather than nginx/LWP severing the call.
my $TIMEOUT = 45;

# —————————————————————————
# Pass query string through verbatim — no parsing, no validation needed here.
# voacap-service returns 400 with a clear message if params are missing.
# —————————————————————————

my $qs = $ENV{QUERY_STRING} || $ARGV[0] || '';

my $ua = LWP::UserAgent->new(timeout => $TIMEOUT);
my $url = $qs ? "$ENDPOINT?$qs" : $ENDPOINT;
my $res = $ua->get($url);

if ($res->is_success) {
	print $res->decoded_content;
} else {
	# Emit zero output so HamClock degrades gracefully rather than showing
	# an error, then log the failure to stderr for the OHB operator.
	print STDERR "fetchBandConditions: voacap-service error: ",
	$res->status_line, " ($url)\n";
	emit_zero_output($qs);
	exit 1;
}

exit 0;

# —————————————————————————
# Fallback zero output — keeps HamClock happy if the service is unreachable.
# Parses just enough from the query string to echo params correctly.
# —————————————————————————

sub emit_zero_output {
	my ($qs) = @_;
	my %p;
	for my $pair (split /&/, $qs) {
		my ($k, $v) = split /=/, $pair, 2;
		$p{$k} = $v if defined $k;
	}
	my $pow = int($p{POW} || 100);
	my $mode = int($p{MODE} || 19);
	my $toa = $p{TOA} || '3';
	my $path = int($p{PATH} || 0);
	my $ssn = int($p{SSN} || 0);
	my $mode_label = $mode == 19 ? 'CW'
		: $mode == 14 ? 'FT8'
		: $mode == 15 ? 'FT4'
		: $mode == 17 ? 'RTTY'
		: $mode == 20 ? 'AM'
		: ($mode == 0 || $mode == 1) ? 'SSB'
		: "MODE$mode";
	my $path_label = $path ? 'LP' : 'SP';
	my $zero_row = join(',', ('0.00') x 9);
	print "$zero_row\n";
	printf "%dW,%s,TOA>%s,%s,S=%d\n", $pow, $mode_label, $toa, $path_label, $ssn;
	for my $h (1..23) { print "$h $zero_row\n" }
	print "0 $zero_row\n";
}
