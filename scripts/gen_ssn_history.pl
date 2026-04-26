#!/usr/bin/env perl
# ============================================================
#
#   ██████╗ ██╗  ██╗██████╗
#  ██╔═══██╗██║  ██║██╔══██╗
#  ██║   ██║███████║██████╔╝
#  ██║   ██║██╔══██║██╔══██╗
#  ╚██████╔╝██║  ██║██████╔╝
#   ╚═════╝ ╚═╝  ╚═╝╚═════╝
#
#  Open HamClock Backend
#  gen_ssn_history.pl
#
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#
#  You should have received a copy of the GNU Affero General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# ============================================================
use strict;
use warnings;
use LWP::UserAgent;
use File::Copy qw(move);
use File::Basename qw(basename);

my $URL = 'https://www.sidc.be/SILSO/DATA/SN_m_tot_V2.0.csv';
my $OUT = '/opt/hamclock-backend/htdocs/ham/HamClock/ssn/ssn-history.txt';

my $THIS = basename($0);

my $ua = LWP::UserAgent->new(
    timeout => 20,
    agent   => 'hamclock-ssn-history/1.1'
);

my $res = $ua->get($URL);
unless ($res->is_success) {
    warn "$THIS: ERROR: failed to fetch SILSO monthly data: " . $res->status_line . "\n";
    exit 1;
}

my @rows;

for my $line (split /\n/, $res->decoded_content) {
    next if $line =~ /^\s*#/;

    # year;month;decimal_year;ssn;std;obs;prov
    my @f = split /;/, $line;
    next unless @f >= 4;

    my ($year, $month, $ssn) = (int($f[0]), int($f[1]), $f[3]);

    # HamClock cutoff
    next if $year < 1900;

    next unless defined $ssn && $ssn >= 0;

    # Keep Jan, Mar, May, Jul, Sep, Nov only
    next unless $month =~ /^(1|3|5|7|9|11)$/;

    # Decimal year: year + (month - 1) / 12
    my $decimal = sprintf("%.2f", $year + ($month - 1) / 12);

    push @rows, sprintf("%s %.1f", $decimal, $ssn);
}

unless (@rows) {
    warn "$THIS: ERROR: no data parsed from SILSO\n";
    exit 1;
}

# Skip write if content unchanged (preserve mtime accuracy for staleness checks)
if (-e $OUT) {
    open my $old, '<', $OUT or goto WRITE;
    my $existing = do { local $/; <$old> };
    close $old;
    my $new = join("\n", @rows) . "\n";
    if ($existing eq $new) {
        print "$THIS: no change in SSN data — touching $OUT to reset staleness clock\n";
        utime(undef, undef, $OUT);
        exit 0;
    }
}
WRITE:
# Atomic write
my $tmp = "$OUT.tmp";
open my $fh, '>', $tmp or do { warn "$THIS: ERROR: cannot write temp file: $!\n"; exit 1; };
print $fh "$_\n" for @rows;
close $fh;
move($tmp, $OUT) or do { warn "$THIS: ERROR: move failed: $!\n"; exit 1; };

print "$THIS: updated SSN history (" . scalar(@rows) . " rows)\n";
exit 0;
