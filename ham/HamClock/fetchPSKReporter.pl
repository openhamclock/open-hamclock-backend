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
# Non-blocking HTTP proxy. Forwards the HamClock query string to the
# pskr-mqtt-cache service and streams the response back unchanged.
#
# This version runs Mojo's IOLoop and streams the response body to
# stdout in chunks via syswrite(). Each chunk write reveals whether
# HamClock is still listening: a closed pipe returns undef + EPIPE,
# at which point we abort the upstream transaction.

use strict;
use warnings;

use CGI::Fast;        # Crucial for FastCGI persistence
use Mojo::UserAgent;
use Mojo::IOLoop;

# We do not want SIGPIPE to kill us — we want to detect EPIPE via syswrite's
# return value and act on it ourselves.
$SIG{PIPE} = 'IGNORE';

# —————————————————————————
# Configuration (Initialized ONCE on startup)
# —————————————————————————

my $host        = $ENV{PSKR_MQTT_CACHE_HOST} || 'pskr-mqtt-cache:5000';
my $SERVICE_URL = "http://$host/ham/HamClock";
my $ENDPOINT    = "$SERVICE_URL/fetchPSKReporter.pl";
my $TIMEOUT     = 12;

# Instantiate the UserAgent ONCE globally. 
# This allows Mojo to maintain a connection pool to $host across requests!
my $ua = Mojo::UserAgent->new
    ->connect_timeout(4)
    ->inactivity_timeout(8)
    ->request_timeout($TIMEOUT)
    ->max_redirects(0);

# —————————————————————————
# FastCGI Main Loop
# —————————————————————————

while (my $q = CGI::Fast->new) {
    # Per-request configuration
    my $qs  = $ENV{QUERY_STRING} || '';
    my $url = "$ENDPOINT?$qs";

    binmode(STDOUT);

    # Shared state for the IOLoop callbacks for THIS specific request.
    my $headers_sent = 0;   
    my $aborted      = 0;   

    my $original_ua = $ENV{HTTP_USER_AGENT} // 'OHB-Proxy/1.0';
    my $tx = $ua->build_tx(GET => $url, {'User-Agent' => $original_ua});

    # Stream upstream body to stdout chunk-by-chunk.
    $tx->res->content->unsubscribe('read')->on(read => sub {
        my ($content, $bytes) = @_;
        return if $aborted;

        if (!$headers_sent) {
            emit_headers($tx->res);
            $headers_sent = 1;
        }

        return unless length $bytes;

        my $written = syswrite(STDOUT, $bytes);
        if (!defined $written) {
            # Client gone (EPIPE). Cancel upstream transaction.
            $aborted = 1;
            $tx->res->error({message => "client write failed: $!"});
            Mojo::IOLoop->stop;
        }
    });

    # Start non-blocking transaction
    $ua->start($tx => sub {
        my ($ua, $tx) = @_;
        Mojo::IOLoop->stop;
    });

    # Run the loop for this single transaction
    Mojo::IOLoop->start;

    # Post-mortem handling for this request
    if ($aborted) {
        next; # Move on to the next FastCGI request
    }

    my $err = $tx->error;
    if ($err) {
        if (!$headers_sent) {
            my $msg = $err->{message} // 'unknown';
            print STDERR "fetchPSKReporter: upstream failed: $msg ($url)\n";
            my $body = "pskr-mqtt-cache unreachable: $msg\n";
            syswrite(STDOUT,
                "Status: 502 Bad Gateway\r\n" .
                "Content-Type: text/plain\r\n" .
                "\r\n" .
                $body);
        }
        next;
    }

    if (!$headers_sent) {
        emit_headers($tx->res);
        my $body = $tx->res->body // '';
        syswrite(STDOUT, $body) if length $body;
    }
}

exit;

sub emit_headers {
    my $res = shift;
    my $code = $res->code    // 502;
    my $msg  = $res->message // 'Unknown';
    my $hdr = "Status: $code $msg\r\n";

    my $headers = $res->headers->to_hash(1);
    for my $name (sort keys %$headers) {
        next if $name =~ /^(Transfer-Encoding|Connection|Content-Length|Client-)/i;

        my $out_name = ($name =~ /^X-2Z-Lengths$/i) ? 'X-2Z-lengths' : $name;

        my $values = $headers->{$name};
        $values = [$values] unless ref $values eq 'ARRAY';
        for my $v (@$values) {
            $hdr .= "$out_name: $v\r\n";
        }
    }

    $hdr .= "\r\n";
    syswrite(STDOUT, $hdr);
}
