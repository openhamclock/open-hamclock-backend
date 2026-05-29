#!/usr/bin/env perl
use strict;
use warnings;
use CGI qw(:standard);
use HTTP::Tiny;
use URI::Escape qw(uri_escape);

# Thin OHB CGI shim. This must never talk to wspr.live.
# It only forwards HamClock-compatible params to the local cache container.
my $base = $ENV{WSPR_CACHE_URL} || 'http://wspr-live-cache:5001/ham/HamClock/fetchWSPR.pl';
my $q = CGI->new;

my @allowed = qw(ofcall bycall ofgrid bygrid band maxage);
my @pairs;
for my $k (@allowed) {
    my $v = $q->param($k);
    next unless defined $v && length $v;
    $v =~ s/[^A-Za-z0-9_\-\/\.]+//g;
    if ($k eq 'maxage') {
        $v = int($v);
        $v = 86400 if $v > 86400;
        $v = 1 if $v < 1;
    }
    push @pairs, uri_escape($k) . '=' . uri_escape($v);
}

my $url = $base . (@pairs ? '?' . join('&', @pairs) : '');
my $res = HTTP::Tiny->new(timeout => 10)->get($url, { headers => { 'User-Agent' => 'OHB-fetchWSPR-cache-shim/1.0' } });

print "Content-Type: text/plain\r\n";
print "Cache-Control: no-store\r\n";
print "X-WSPR-Shim: local-cache-only\r\n";
print "\r\n";

if ($res->{success}) {
    print $res->{content};
} else {
    print "# WSPR cache unavailable; no upstream fallback from CGI\n";
    print "# status=$res->{status} reason=$res->{reason}\n";
}
