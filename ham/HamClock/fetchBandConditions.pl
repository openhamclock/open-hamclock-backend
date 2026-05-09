#!/usr/bin/perl
#
# fetchBandConditions.pl - HamClock band conditions proxy to voacap-service
#
# Non-blocking HTTP proxy. Forwards the HamClock query string to
# voacap-service and streams the small text response back.
#
# Same disconnect-detection model as fetchVOACAPArea.pl — see that file
# for rationale. Band conditions has a smaller response (~2 KB) and a
# tighter timeout (45s) than the area maps, but uses identical machinery
# for consistency.
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

$SIG{PIPE} = 'IGNORE';

my $host        = $ENV{VOACAP_SERVICE_HOST} || 'voacap-service:8080';
my $SERVICE_URL = "http://$host";
my $ENDPOINT    = "$SERVICE_URL/fetchBandConditions";

# Timeout layers (shortest first):
#   Python subprocess(voacapl) = 30s   (voacap_service.py)
#   nginx uwsgi_read_timeout   = 45s   (nginx.conf)
#   This Mojo timeout          = 45s   <-- matches nginx so we give up together
#   lighttpd server.max-read-idle = 60s default
#   uWSGI harakiri             = 300s  (uwsgi.ini)
my $TIMEOUT = 45;

my $qs  = $ENV{QUERY_STRING} || $ARGV[0] || '';

# Append latest SSN from local file to the upstream request.
my $ssn = 0;
if (open(my $fh, '<', '/opt/hamclock-backend/htdocs/ham/HamClock/ssn/ssn-31.txt')) {
    my $last_line;
    while (my $line = <$fh>) {
        $last_line = $line if $line =~ /\S/;
    }
    close $fh;
    my @parts = split ' ', $last_line if $last_line;
    $ssn = $parts[3] if @parts >= 4;
}
$qs .= ($qs ? '&' : '') . "ssn=$ssn";
my $url = "$ENDPOINT?$qs";

binmode(STDOUT);

my $headers_sent = 0;
my $aborted      = 0;

my $ua = Mojo::UserAgent->new
    ->connect_timeout(5)
    ->request_timeout($TIMEOUT)
    ->max_redirects(0);

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

if ($aborted) {
    # HamClock gone — nothing useful to write. Just exit; lighttpd reaps us.
    exit 1;
}

my $err = $tx->error;
if ($err) {
    # Upstream failed. HamClock expects a specific zero-output format on
    # failure so its band-conditions panel shows blanks rather than an error.
    if (!$headers_sent) {
        print STDERR "fetchBandConditions: voacap-service error: ",
                     ($err->{message} // 'unknown'), " ($url)\n";
        emit_zero_output($qs);
    }
    exit 1;
}

if (!$headers_sent) {
    emit_headers($tx->res);
    my $body = $tx->res->body // '';
    syswrite(STDOUT, $body) if length $body;
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
