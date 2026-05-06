#!/usr/bin/perl
#
# fetchVOACAPArea.pl - HamClock VOACAP DE/DX REL proxy to voacap-service
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
$| = 1; # Enable autoflush for streaming large BMPs

my $SERVICE_URL = $ENV{VOACAP_SERVICE_URL} || 'http://voacap-service:8080';
my $ENDPOINT    = "$SERVICE_URL/fetchVOACAP-MUF.pl";

# Replicating proxy timeouts
my $READ_TIMEOUT  = 300; 
my $WRITE_TIMEOUT = 360; 

# —————————————————————————
# Global Safety Timeout
# —————————————————————————
local $SIG{ALRM} = sub { die "Error: Script Timeout\n" };
alarm($READ_TIMEOUT + $WRITE_TIMEOUT);

# —————————————————————————
# Pass query string through verbatim
# —————————————————————————
my $qs = $ENV{QUERY_STRING} || $ARGV[0] || '';
my $url = $qs ? "$ENDPOINT?$qs" : $ENDPOINT;

my $ua = LWP::UserAgent->new(timeout => $READ_TIMEOUT);
my $headers_sent = 0;

# Use :content_cb to stream the BMP chunk-by-chunk to save memory
my $res = $ua->get($url, ':content_cb' => sub {
    my ($chunk, $res, $proto) = @_;

    if (!$headers_sent) {
        binmode(STDOUT);

        # 1. Print the status first
        print "Status: " . $res->code . " " . $res->message . "\r\n";

        # 2. Get all headers as one big string block
        my $header_block = $res->headers->as_string("\r\n");

        # 3. HARDCODED FIX: 
        $header_block =~ s/X-2Z-Lengths/X-2Z-lengths/g;

        # 4. Filter headers
        foreach my $line (split(/\r\n/, $header_block)) {
            next if $line =~ /^(Transfer-Encoding|Connection|Content-Length|Client-)/i;
            print "$line\r\n";
        }

        # 5. End headers
        print "\r\n";
        $headers_sent = 1;
    }

    # Stream the actual BMP data
    print $chunk;
});
