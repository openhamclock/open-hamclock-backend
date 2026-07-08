#!/usr/bin/perl
#
# fetchBandConditions.pl - HamClock band conditions proxy to voacap-service
#
# HTTP proxy. Forwards the HamClock query string to voacap-service and
# streams the small text response back.
#
# Runs as a persistent FastCGI worker (CGI::Fast) with one hoisted
# Mojo::UserAgent keeping a keep-alive pool to voacap-service. Same
# disconnect-detection model as fetchVOACAPArea.pl — see that file for
# rationale. Band conditions has a smaller response (~2 KB) and a tighter
# timeout (45s) than the area maps, but uses identical machinery for
# consistency.
#
# Configuration (environment variables):
#   VOACAP_SERVICE_URL  Base URL of voacap-service.
#                       Default: http://voacap-service:8080
#
# License: AGPLv3

use strict;
use warnings;

use CGI::Fast;        # Crucial for FastCGI persistence
use Mojo::UserAgent;
use Mojo::IOLoop;

$SIG{PIPE} = 'IGNORE';

my $host        = $ENV{VOACAP_SERVICE_HOST} || 'voacap-service:8080';
my $SERVICE_URL = "http://$host/ham/HamClock";
my $ENDPOINT    = "$SERVICE_URL/fetchBandConditions.pl";

# Timeout layers (shortest first):
#   Python subprocess(voacapl) = 30s   (voacap_service.py)
#   nginx uwsgi_read_timeout   = 45s   (nginx.conf)
#   This Mojo timeout          = 45s   <-- matches nginx so we give up together
#   lighttpd server.max-read-idle = 60s default
#   uWSGI harakiri             = 300s  (uwsgi.ini)
#
# NOTE: intentionally only request_timeout, NOT inactivity_timeout. voacapl
# runs as a subprocess and can be SILENT for tens of seconds before emitting
# the whole ~2 KB result in one burst, so an idle timeout would kill valid slow
# predictions. (The PSK shim can afford a short inactivity_timeout because its
# upstream is a cache that streams promptly; this one cannot.)
my $TIMEOUT      = 45;
my $MAX_REQUESTS = 500;   # recycle this worker after N requests so a long-lived
                          # Perl process can't slowly bloat; the FastCGI manager
                          # respawns a fresh one.

# Instantiate the UserAgent ONCE globally so Mojo maintains a keep-alive pool to
# voacap-service across requests. The blocking $ua->start (below) runs on the
# UA's own ioloop, where that pool lives, so pooling survives across requests.
my $ua = Mojo::UserAgent->new
    ->connect_timeout(5)
    ->request_timeout($TIMEOUT)
    ->max_redirects(0);

# —————————————————————————
# FastCGI Main Loop
# —————————————————————————

my $reqs = 0;
while (my $q = CGI::Fast->new) {
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
        # NOTE: `my @x = ... if COND` is undefined behavior in Perl and, in a
        # long-lived FastCGI worker, can leave @parts holding a PREVIOUS
        # request's value when this file is empty. Guard explicitly instead.
        if (defined $last_line) {
            my @parts = split ' ', $last_line;
            $ssn = $parts[3] if @parts >= 4;
        }
    }
    $qs .= ($qs ? '&' : '') . "ohb-ssn=$ssn";
    my $url = "$ENDPOINT?$qs";

    binmode(STDOUT);

    my $headers_sent = 0;
    my $aborted      = 0;

    my $tx = $ua->build_tx(GET => $url);

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
            # blocking start below promptly and sends a FIN to voacap-service so
            # it stops working on a response nobody is listening for.
            $aborted = 1;
            if (my $cid = $tx->connection) {
                $ua->ioloop->remove($cid);
            }
        }
    });

    # Blocking start on the UA's own ioloop. Read events still fire as bytes
    # arrive (so the response is streamed, not buffered), and it returns when the
    # transaction finishes or when we close the connection above. Driving it this
    # way instead of hand-rolling Mojo::IOLoop->start/stop with a persistent
    # completion callback means no stale callback from one request can fire
    # during the next.
    $ua->start($tx);

    # Break the read-callback -> $tx -> content reference cycle so this
    # transaction (and its buffers) are actually reclaimed. Runs on every path.
    $tx->res->content->unsubscribe('read');

    if ($aborted) {
        # HamClock gone mid-stream — nothing left to write.
    }
    elsif (my $err = $tx->error) {
        # Upstream failed. HamClock expects a specific zero-output format on
        # failure so its band-conditions panel shows blanks rather than an error.
        if (!$headers_sent) {
            print STDERR "fetchBandConditions: voacap-service error: ",
                         ($err->{message} // 'unknown'), " ($url)\n";
            emit_zero_output($qs);
        }
    }
    elsif (!$headers_sent) {
        emit_headers($tx->res);
        my $body = $tx->res->body // '';
        syswrite(STDOUT, $body) if length $body;
    }

    undef $tx;                              # free now, during the idle wait
    last if ++$reqs >= $MAX_REQUESTS;       # recycle worker; manager respawns it
}

exit 0;

# —————————————————————————
# Header forwarding (same logic as the other shims)
# —————————————————————————

sub emit_headers {
    my $res = shift;

    my $code = $res->code    // 502;
    my $msg  = $res->message // 'Unknown';

    # Build entire header block as one string and syswrite it. See
    # fetchVOACAPArea.pl for the rationale (mixing print + syswrite on the
    # same fd reorders bytes).
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

# —————————————————————————
# Fallback zero-output for upstream failures.
# Keeps HamClock's band-conditions panel happy when voacap-service is down.
# —————————————————————————

sub emit_zero_output {
    my ($qs) = @_;
    my %p;
    for my $pair (split /&/, $qs) {
        my ($k, $v) = split /=/, $pair, 2;
        $p{$k} = $v if defined $k;
    }
    my $pow  = int($p{POW} || 100);
    my $mode = int($p{MODE} || 19);
    my $toa  = $p{TOA} || '3';
    my $path = int($p{PATH} || 0);
    my $ssn  = int($p{SSN} || 0);

    my $mode_label =
          $mode == 19 ? 'CW'
        : $mode == 14 ? 'FT8'
        : $mode == 15 ? 'FT4'
        : $mode == 17 ? 'RTTY'
        : $mode == 20 ? 'AM'
        : ($mode == 0 || $mode == 1) ? 'SSB'
        : "MODE$mode";
    my $path_label = $path ? 'LP' : 'SP';
    my $zero_row = join(',', ('0.00') x 9);

    # Build the whole response as one string and syswrite (consistent with
    # the rest of this script — see emit_headers for rationale).
    my $out =
        "Status: 200 OK\r\n" .
        "Content-Type: text/plain; charset=ISO-8859-1\r\n\r\n" .
        "$zero_row\n" .
        sprintf("%dW,%s,TOA>%s,%s,S=%d\n",
                $pow, $mode_label, $toa, $path_label, $ssn);
    for my $h (1..23) {
        $out .= "$h $zero_row\n";
    }
    $out .= "0 $zero_row\n";
    syswrite(STDOUT, $out);
}
