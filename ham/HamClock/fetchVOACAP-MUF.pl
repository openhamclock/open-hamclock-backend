#!/usr/bin/perl
#
# fetchVOACAP-MUF.pl - HamClock VOACAP MUF proxy to voacap-service
#
# Non-blocking HTTP proxy. Forwards the HamClock query string to the
# voacap-service container and streams the response back unchanged.
#
# WHY NON-BLOCKING:
#   HamClock's client-side fetch timeout is short (~2s). voacap-service
#   takes 5-30s to render an area map. With a blocking LWP client the CGI
#   sat inside ->get() and never noticed that HamClock had hung up; the
#   socket pile-up in CLOSE_WAIT and the wasted voacapl CPU only ended
#   when the upstream response finally arrived. With ~150 concurrent
#   retries that is a major resource sink.
#
#   This version runs Mojo's IOLoop and streams the response body to
#   stdout in chunks via syswrite(). Each chunk write reveals whether
#   HamClock is still listening: a closed pipe returns undef + EPIPE,
#   at which point we abort the upstream transaction. Aborting closes
#   our socket to nginx, which closes nginx's socket to uWSGI, which
#   triggers voacap-service's cancellable runner.
#
# LIMITATION:
#   Linux pipe semantics make it impossible to detect a closed reader
#   without attempting a real write. So during the "voacapl is computing,
#   no body bytes yet" window we cannot detect HamClock leaving. Once
#   the first body chunk arrives, detection is immediate. In practice
#   this still cuts CLOSE_WAIT lifetime from ~30s to milliseconds for
#   any request that produces a body.
#
# Configuration (environment variables):
#   VOACAP_SERVICE_URL  Base URL of voacap-service.
#                       Default: http://voacap-service:8080
#
# License: AGPLv3

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

my $host        = $ENV{VOACAP_SERVICE_HOST} || 'voacap-service:8080';
my $SERVICE_URL = "http://$host";
my $ENDPOINT    = "$SERVICE_URL/fetchVOACAP-MUF.pl";

# Hard upper bound on the proxied request. Matches voacap-service's
# uWSGI harakiri ceiling so legitimate slow maps still complete.
my $TIMEOUT = 300;

# —————————————————————————
# Forward query string verbatim. voacap-service handles validation.
# —————————————————————————

my $qs  = $ENV{QUERY_STRING} || $ARGV[0] || '';

# Append latest SSN from local file to the upstream request.
# Use 71 as a nominal default if the file is missing or invalid.
my $ssn = 71;
if (open(my $fh, '<', '/opt/hamclock-backend/htdocs/ham/HamClock/ssn/ssn-31.txt')) {
    my $last_line;
    while (my $line = <$fh>) {
        $last_line = $line if $line =~ /\S/;
    }
    close $fh;
    my @parts = split ' ', $last_line if $last_line;
    $ssn = $parts[3] if @parts >= 4;
}
$qs .= ($qs ? '&' : '') . "ohb-ssn=$ssn";
my $url = "$ENDPOINT?$qs";

binmode(STDOUT);

# Shared state for the IOLoop callbacks.
my $headers_sent = 0;   # have we already emitted CGI headers to stdout?
my $aborted      = 0;   # set when we cancel due to client disconnect

my $ua = Mojo::UserAgent->new
    ->connect_timeout(5)
    ->request_timeout($TIMEOUT)
    ->max_redirects(0);

#my $tx = $ua->build_tx(GET => $url);
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
        # socket closes and the disconnect propagates to voacap-service.
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
    # Client gave up. Upstream is cancelled; lighttpd will reap us.
    exit 1;
}

my $err = $tx->error;
if ($err) {
    # Upstream connect/read failed. If we haven't sent headers yet, send 502.
    if (!$headers_sent) {
        my $msg = $err->{message} // 'unknown';
        print STDERR "fetchVOACAP-MUF: upstream failed: $msg ($url)\n";
        my $body = "voacap-service unreachable: $msg\n";
        syswrite(STDOUT,
            "Status: 502 Bad Gateway\r\n" .
            "Content-Type: text/plain\r\n" .
            "\r\n" .
            $body);
    }
    exit 1;
}

# Edge case: a successful response with zero body (e.g. an upstream 4xx with
# empty body). The read handler may not have fired with any non-zero chunk,
# so headers were never emitted. Emit them now.
if (!$headers_sent) {
    emit_headers($tx->res);
    my $body = $tx->res->body // '';
    syswrite(STDOUT, $body) if length $body;
}

exit 0;

# —————————————————————————
# Header forwarding
# —————————————————————————
#
# Two adjustments versus a verbatim copy:
#   - HamClock expects lowercase 'l' in X-2Z-lengths. Mojo's headers object
#     preserves the case it was given over the wire, but to_hash() normalises
#     by canonical key. We force the lowercase variant on output.
#   - Strip hop-by-hop and Content-Length / Transfer-Encoding headers; the
#     CGI gateway will recompute these and our forwarded values can confuse
#     lighttpd (especially Transfer-Encoding: chunked which it strips for us).

sub emit_headers {
    my $res = shift;

    my $code = $res->code    // 502;
    my $msg  = $res->message // 'Unknown';

    # Build the entire header block as one string and syswrite it. We avoid
    # `print` here because the body is written via syswrite (for disconnect
    # detection) — mixing buffered print with unbuffered syswrite on the
    # same fd lets body bytes reach the kernel before the buffered headers
    # are flushed, scrambling the response.
    my $hdr = "Status: $code $msg\r\n";

    # Use to_hash(1) to get arrayref values for multi-valued headers.
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
