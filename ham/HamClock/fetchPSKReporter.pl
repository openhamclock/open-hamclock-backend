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

use Mojo::UserAgent;
use Mojo::IOLoop;

# We do not want SIGPIPE to kill us — we want to detect EPIPE via syswrite's
# return value and act on it ourselves.
$SIG{PIPE} = 'IGNORE';

# —————————————————————————
# Configuration
# —————————————————————————

my $host        = $ENV{PSKR_MQTT_CACHE_HOST} || 'pskr-mqtt-cache:5000';
my $SERVICE_URL = "http://$host/ham/HamClock";
my $ENDPOINT    = "$SERVICE_URL/fetchPSKReporter.pl";
my $TIMEOUT     = 12;

# —————————————————————————
# Forward query string verbatim.
# —————————————————————————

my $qs  = $ENV{QUERY_STRING} || $ARGV[0] || '';
my $url = "$ENDPOINT?$qs";

binmode(STDOUT);

# Shared state for the IOLoop callbacks.
my $headers_sent = 0;   # have we already emitted CGI headers to stdout?
my $aborted      = 0;   # set when we cancel due to client disconnect

my $ua = Mojo::UserAgent->new
    ->connect_timeout(4)
    ->inactivity_timeout(8)
    ->request_timeout($TIMEOUT)
    ->max_redirects(0);

my $original_ua = $ENV{HTTP_USER_AGENT} // 'OHB-Proxy/1.0';
my $tx = $ua->build_tx(GET => $url, {'User-Agent' => $original_ua});

# Stream upstream body to stdout chunk-by-chunk. Each syswrite reveals
# whether the downstream client is still there.
$tx->res->content->unsubscribe('read')->on(read => sub {
    my ($content, $bytes) = @_;
    return if $aborted;

    # Send CGI headers on first chunk (which is also when upstream headers
    # are first available — Mojo populates them before firing 'read').
    if (!$headers_sent) {
        emit_headers($tx->res);
        $headers_sent = 1;
    }

    return unless length $bytes;   # final 0-byte event signalling EOF

    my $written = syswrite(STDOUT, $bytes);
    if (!defined $written) {
        # Client gone (EPIPE) or other write error. Cancel upstream so the
        # socket closes and the disconnect propagates to pskr-mqtt-cache.
        $aborted = 1;
        $tx->res->error({message => "client write failed: $!"});
        Mojo::IOLoop->stop;
    }
});

$ua->start($tx => sub {
    my ($ua, $tx) = @_;
    Mojo::IOLoop->stop;
});

Mojo::IOLoop->start;

# —————————————————————————
# Post-mortem
# —————————————————————————

if ($aborted) {
    exit 1;
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
    exit 1;
}

if (!$headers_sent) {
    emit_headers($tx->res);
    my $body = $tx->res->body // '';
    syswrite(STDOUT, $body) if length $body;
}

exit;

sub emit_headers {
    my $res = shift;
    my $code = $res->code    // 502;
    my $msg  = $res->message // 'Unknown';
    my $hdr = "Status: $code $msg\r\n";

    # Build the entire header block as one string and syswrite it to avoid
    # mixing buffered print with unbuffered syswrite.
    my $headers = $res->headers->to_hash(1);
    for my $name (sort keys %$headers) {
        next if $name =~ /^(Transfer-Encoding|Connection|Content-Length|Client-)/i;

        # HamClock-specific casing fix
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
