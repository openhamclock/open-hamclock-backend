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

use strict;
use warnings;

use Mojolicious::Lite;
use Mojo::UserAgent;

app->log->level('info');

# —————————————————————————
# Configuration
# —————————————————————————
my $pskr_host   = $ENV{PSKR_MQTT_CACHE_HOST} || 'pskr-mqtt-cache:5000';
my $voacap_host = $ENV{VOACAP_SERVICE_HOST}  || 'voacap-service:8080';

# Connection Pools for each upstream target
my $ua_pskr = Mojo::UserAgent->new
    ->connect_timeout(4)
    ->inactivity_timeout(8)
    ->request_timeout(12)
    ->max_redirects(0);

my $ua_band = Mojo::UserAgent->new
    ->connect_timeout(5)
    ->request_timeout(45)
    ->max_redirects(0);

my $ua_voacap = Mojo::UserAgent->new
    ->connect_timeout(5)
    ->request_timeout(300)
    ->max_redirects(0);

# —————————————————————————
# Routes
# —————————————————————————
get '/ham/HamClock/fetchPSKReporter.pl' => sub {
    my $c = shift;
    proxy_request($c, "http://$pskr_host/ham/HamClock/fetchPSKReporter.pl", 0);
};

get '/ham/HamClock/fetchBandConditions.pl' => sub {
    my $c = shift;
    proxy_request($c, "http://$voacap_host/ham/HamClock/fetchBandConditions.pl", 1);
};

get '/ham/HamClock/fetchVOACAPArea.pl' => sub {
    my $c = shift;
    proxy_request($c, "http://$voacap_host/ham/HamClock/fetchVOACAPArea.pl", 0);
};

get '/ham/HamClock/fetchVOACAP-TOA.pl' => sub {
    my $c = shift;
    proxy_request($c, "http://$voacap_host/ham/HamClock/fetchVOACAP-TOA.pl", 0);
};

get '/ham/HamClock/fetchVOACAP-MUF.pl' => sub {
    my $c = shift;
    proxy_request($c, "http://$voacap_host/ham/HamClock/fetchVOACAP-MUF.pl", 0);
};

app->start;

# —————————————————————————
# Helper functions
# —————————————————————————

sub get_ssn {
    my $ssn = 71;
    my $ssn_file = '/opt/hamclock-backend/htdocs/ham/HamClock/ssn/ssn-31.txt';
    if (open(my $fh, '<', $ssn_file)) {
        my $last_line;
        while (my $line = <$fh>) {
            $last_line = $line if $line =~ /\S/;
        }
        close $fh;
        if ($last_line) {
            my @parts = split ' ', $last_line;
            $ssn = $parts[3] if @parts >= 4;
        }
    }
    return $ssn;
}

sub proxy_request {
    my ($c, $endpoint, $is_band_conditions) = @_;

    my $qs = $c->req->url->query->to_string // '';

    # Append latest SSN for voacap endpoints
    if ($is_band_conditions || $endpoint =~ /fetchVOACAP/) {
        my $ssn = get_ssn();
        $qs .= ($qs ? '&' : '') . "ohb-ssn=$ssn";
    }

    my $url = "$endpoint?$qs";

    # Pick the appropriate UA with predefined timeouts
    my $ua = $is_band_conditions ? $ua_band
           : ($endpoint =~ /fetchPSK/ ? $ua_pskr : $ua_voacap);

    my $original_ua = $c->req->headers->user_agent // 'OHB-Proxy/1.0';
    my $tx = $ua->build_tx(GET => $url, {'User-Agent' => $original_ua});

    my $headers_sent = 0;
    my $aborted      = 0;

    # Detect downstream client disconnect
    $c->tx->on(finish => sub {
        return if $aborted;
        $aborted = 1;
        if (my $conn = $tx->connection) {
            $ua->ioloop->remove($conn);
        }
    });

    # Stream body from upstream response
    $tx->res->content->unsubscribe('read')->on(read => sub {
        my ($content, $bytes) = @_;
        return if $aborted;

        if (!$headers_sent) {
            $c->res->code($tx->res->code);
            $c->res->message($tx->res->message);

            my $headers = $tx->res->headers->to_hash(1);
            for my $name (keys %$headers) {
                next if $name =~ /^(Transfer-Encoding|Connection|Content-Length|Client-)/i;
                my $out_name = ($name =~ /^X-2Z-Lengths$/i) ? 'X-2Z-lengths' : $name;
                my $values = $headers->{$name};
                $values = [$values] unless ref $values eq 'ARRAY';
                for my $v (@$values) {
                    $c->res->headers->add($out_name => $v);
                }
            }
            $headers_sent = 1;
        }

        if (length $bytes) {
            $c->write($bytes);
        }
    });

    # Start non-blocking request
    $ua->start($tx => sub {
        my ($ua, $tx) = @_;
        return if $aborted;

        my $err = $tx->error;
        if ($err) {
            if (!$headers_sent) {
                if ($is_band_conditions) {
                    emit_zero_response($c, $qs, $err->{message} // 'unknown', $url);
                } else {
                    app->log->error("Upstream error for $url: " . ($err->{message} // 'unknown'));
                    $c->res->code(502);
                    $c->res->headers->content_type('text/plain');
                    $c->write("Upstream error: " . ($err->{message} // 'unknown') . "\n");
                }
                $headers_sent = 1;
            }
        }
        $c->finish;
    });
}

sub emit_zero_response {
    my ($c, $qs, $err_msg, $url) = @_;
    app->log->error("fetchBandConditions: voacap-service error: $err_msg ($url)");

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

    my $out = "$zero_row\n" .
        sprintf("%dW,%s,TOA>%s,%s,S=%d\n",
                $pow, $mode_label, $toa, $path_label, $ssn);
    for my $h (1..23) {
        $out .= "$h $zero_row\n";
    }
    $out .= "0 $zero_row\n";

    $c->res->code(200);
    $c->res->headers->content_type('text/plain; charset=ISO-8859-1');
    $c->write($out);
}
