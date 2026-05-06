#!/usr/bin/perl
#
# fetchVOACAP-MUF.pl - HamClock VOACAP MUF proxy to voacap-service
#
# Thin HTTP proxy that forwards the HamClock query string to the voacap-service
# container and streams the response back unchanged. voacap-service handles all
# VOACAP execution, concurrency, and output formatting; HamClock sees identical
# wire-protocol output.
#
# Configuration (environment variables):
#   VOACAP_SERVICE_URL  Base URL of the voacap-service
#                       Default: http://voacap-service:8080
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
my $ENDPOINT    = "$SERVICE_URL/fetchVOACAP-MUF.pl";

# Timeout layers (shortest first):
#   Python subprocess(voacapl) = 120s   (area_map.py)
#   nginx uwsgi_read_timeout   = 300s   (nginx.conf)
#   This LWP timeout           = 300s   <-- matches nginx so we give up together
#   lighttpd server.max-read-idle = 300s (54-voacap-cgi-timeouts.conf)
#   uWSGI harakiri             = 300s   (uwsgi.ini)
my $TIMEOUT = 300;

# —————————————————————————
# Forward query string verbatim — voacap-service handles validation and
# returns 400 with a clear message if anything is malformed.
# —————————————————————————

my $qs  = $ENV{QUERY_STRING} || $ARGV[0] || '';
my $ua  = LWP::UserAgent->new(timeout => $TIMEOUT);
my $url = $qs ? "$ENDPOINT?$qs" : $ENDPOINT;
my $res = $ua->get($url);

# LWP returns code 0 for client-side failures (connection refused, DNS,
# its own timeout). Treat those as 502 Bad Gateway with a plain-text body
# so the operator can see what happened. For everything else — including
# upstream 4xx — forward the response through unchanged so the client
# gets voacap-service's actual error message.
if ($res->code == 0) {
    print STDERR "fetchVOACAP-MUF: voacap-service unreachable: ",
                 $res->status_line, " ($url)\n";
    print "Status: 502 Bad Gateway\r\n";
    print "Content-Type: text/plain\r\n\r\n";
    print "voacap-service unreachable: ", $res->status_line, "\n";
    exit 1;
}

binmode(STDOUT);

# 1. Status line (forwarded from upstream, including 4xx/5xx).
print "Status: " . $res->code . " " . $res->message . "\r\n";

# 2. Forward upstream headers, with two adjustments:
#    - HamClock client expects the lowercase 'l' in X-2Z-lengths; LWP's
#      header normalization Title-Cases it. Force it back.
#    - Strip hop-by-hop and content-encoding/length headers that lighttpd's
#      CGI handler will recompute or that would break the proxied connection.
my $header_block = $res->headers->as_string("\r\n");
$header_block =~ s/X-2Z-Lengths/X-2Z-lengths/g;

foreach my $line (split(/\r\n/, $header_block)) {
    next if $line =~ /^(Transfer-Encoding|Connection|Content-Length|Client-)/i;
    print "$line\r\n";
}

# 3. End headers, write body.
print "\r\n";
print $res->content;

exit 0;
