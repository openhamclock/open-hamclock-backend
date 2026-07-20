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
use HTTP::Tiny;
use JSON::PP;

my $UA = HTTP::Tiny->new(
    timeout => 8,
    agent   => "HamClock-Spot/1.0"
);

# -------------------------
# Per-network spot posters
# -------------------------
# Each takes the already-validated %spot fields and returns (1, "") on success
# or (0, "reason") on failure. Add a new entry here + in %posters to support
# another activation network -- everything upstream of dispatch() is generic.
# N.B. every poster is responsible for setting its own network's "reporting
# software" field to "HamClock" -- we never trust the client for that field,
# same as we don't trust it to identify the spotter as anyone but themselves.

sub post_pota {
    my (%spot) = @_;

    my $url = "https://api.pota.app/spot/";
    my $body = encode_json({
        activator => $spot{call},
        spotter   => $spot{spotter},
        frequency => $spot{khz},
        reference => $spot{ref},
        mode      => $spot{mode} // "",
        source    => "HamClock",
        comments  => $spot{comment} // "",
    });

    my $resp = $UA->post($url, {
        headers => {
            "Content-Type" => "application/json",
            "Accept"       => "application/json, text/plain, */*",
        },
        content => $body,
    });

    return (1, "") if $resp->{success};
    return (0, "POTA: " . ($resp->{status} // "?") . " " . ($resp->{reason} // "error"));
}

# Networks we don't yet relay to. Rather than silently drop the spot or crash,
# say so plainly so the op knows to (for now) spot it directly on that network.
sub post_unsupported {
    my (%spot) = @_;
    return (0, "$spot{org} spotting not yet supported by this backend");
}

my %posters = (
    'POTA' => \&post_pota,

    # known networks onta.txt can label a spot with, not yet relayed anywhere --
    # route them to post_unsupported() so the op gets a clear, specific answer
    # instead of the generic "unknown org" (which reads like a bad request, not
    # a missing feature). TODO: api2.sota.org.uk and parksnpeaks.org (WWFF) both
    # need an authenticated login flow for posting, unlike POTA's open endpoint.
    'SOTA' => \&post_unsupported,
    'WWFF' => \&post_unsupported,
    'GMA'  => \&post_unsupported,
    'IOTA' => \&post_unsupported,
);

# -------------------------
# Parse QUERY_STRING
# -------------------------
my %q;
if ($ENV{QUERY_STRING}) {
    for (split /&/, $ENV{QUERY_STRING}) {
        my ($k,$v) = split /=/, $_, 2;
        next unless defined $k;
        $v //= '';
        $v =~ tr/+/ /;
        $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $q{$k} = $v;
    }
}

hc_output(dispatch(%q));

exit;

# -------------------------
# Validate then hand off to the right network's poster
# -------------------------
sub dispatch {
    my (%q) = @_;

    my $org = uc($q{org} // '');
    return "error=missing or unknown org" unless $org && exists $posters{$org};

    my $call = uc($q{call} // '');
    return "error=missing activator call" unless $call =~ /^[A-Z0-9\/]{2,15}$/;

    my $ref = uc($q{ref} // '');
    return "error=missing reference" unless length($ref) >= 2 && length($ref) <= 20;

    my $khz = $q{khz} // '';
    return "error=bad frequency" unless $khz =~ /^\d+(\.\d+)?$/ && $khz > 0;

    my $spotter = uc($q{spotter} // '');
    return "error=missing spotter call" unless $spotter =~ /^[A-Z0-9\/]{2,15}$/;

    my $mode = uc($q{mode} // '');
    my $comment = $q{comment} // '';
    $comment = substr($comment, 0, 100);   # generous but bounded

    my ($ok, $why) = $posters{$org}->(
        org => $org, call => $call, ref => $ref, khz => $khz,
        spotter => $spotter, mode => $mode, comment => $comment,
    );

    return $ok ? "ok=1" : "error=$why";
}

# -------------------------
# Output (HamClock format)
# -------------------------
sub hc_output {
    my ($line) = @_;
    print <<'HEADER';
HTTP/1.0 200 Ok
Content-Type: text/plain; charset=ISO-8859-1
Connection: close

HEADER
    print "$line\n";
}
