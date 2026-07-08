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
# HTTP proxy. Forwards the HamClock query string to the pskr-mqtt-cache
# service and streams the response back unchanged.
#
# Runs as a persistent FastCGI worker (CGI::Fast). A single hoisted
# Mojo::UserAgent keeps a keep-alive connection pool to the upstream across
# requests. The response body is streamed to stdout in chunks via syswrite();
# a closed pipe (client gone) returns undef + EPIPE, at which point we close
# the upstream connection to abort the transfer and propagate the disconnect
# to pskr-mqtt-cache.

use strict;
use warnings;

use CGI::Fast;        # FastCGI persistence
use Mojo::UserAgent;
use Mojo::IOLoop;

# We do not want SIGPIPE to kill us — we detect EPIPE via syswrite's return
# value and act on it ourselves.
$SIG{PIPE} = 'IGNORE';

# —————————————————————————
# Configuration (Initialized ONCE on startup)
# —————————————————————————

my $host         = $ENV{PSKR_MQTT_CACHE_HOST} || 'pskr-mqtt-cache:5000';
my $SERVICE_URL  = "http://$host/ham/HamClock";
my $ENDPOINT     = "$SERVICE_URL/fetchPSKReporter.pl";
my $TIMEOUT      = 12;
my $MAX_REQUESTS = 500;   # recycle this worker after N requests so a long-lived
                          # Perl process can't slowly bloat; the FastCGI manager
                          # respawns a fresh one.

# Instantiate the UserAgent ONCE globally so Mojo maintains a keep-alive
# connection pool to $host across requests. NOTE: a blocking $ua->start (below)
# runs on the UA's OWN ioloop, and that pool lives on that same loop, so pooling
# is preserved across requests.
my $ua = Mojo::UserAgent->new
    ->connect_timeout(4)
    ->inactivity_timeout(8)
    ->request_timeout($TIMEOUT)
    ->max_redirects(0);

# —————————————————————————
# FastCGI Main Loop
# —————————————————————————

my $reqs = 0;
while (my $q = CGI::Fast->new) {
    # Per-request configuration
    my $qs  = $ENV{QUERY_STRING} || '';
    my $url = "$ENDPOINT?$qs";

    binmode(STDOUT);

    # Per-request state for the streaming callback.
    my $headers_sent = 0;
    my $aborted      = 0;

    my $original_ua = $ENV{HTTP_USER_AGENT} // 'OHB-Proxy/1.0';
    my $tx = $ua->build_tx(GET => $url, {'User-Agent' => $original_ua});

    # Stream upstream body to stdout chunk-by-chunk.
    #
    # NOTE: this closure captures $tx and is stored inside $tx->res->content,
    # forming a reference cycle (content -> read subscriber -> $tx -> res ->
    # content). Perl is refcounted and will NOT collect a cycle, so in a
    # persistent worker this would leak one whole transaction per request. We
    # break it explicitly with unsubscribe('read') after the request completes.
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
            # Client gone (EPIPE). Close the upstream connection: this ends the
            # blocking start below promptly and sends a FIN to pskr-mqtt-cache so
            # it stops producing a response nobody is listening for.
            $aborted = 1;
            if (my $cid = $tx->connection) {
                $ua->ioloop->remove($cid);
            }
        }
    });

    # Blocking start. Read events still fire as bytes arrive (so the response is
    # streamed, not buffered), and it returns when the transaction finishes or
    # when we close the connection above. Using the UA's own private ioloop this
    # way — instead of hand-driving Mojo::IOLoop->start/stop with a persistent
    # completion callback — means there is no stale callback from one request
    # that can fire during the next.
    $ua->start($tx);

    # Break the read-callback -> $tx -> content reference cycle so this
    # transaction (and its buffers) are actually reclaimed. Runs on every path.
    $tx->res->content->unsubscribe('read');

    # Post-mortem handling for this request.
    if ($aborted) {
        # Client disconnected mid-stream; nothing left to send.
    }
    elsif (my $err = $tx->error) {
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
    }
    elsif (!$headers_sent) {
        # Complete response with no body (e.g. 0-byte 200): the read callback
        # never emitted headers, so do it here.
        emit_headers($tx->res);
        my $body = $tx->res->body // '';
        syswrite(STDOUT, $body) if length $body;
    }

    undef $tx;                              # free now, during the idle wait,
                                            # rather than at the next build_tx
    last if ++$reqs >= $MAX_REQUESTS;       # recycle worker; manager respawns it
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
