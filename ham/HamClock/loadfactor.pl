#!/usr/bin/perl
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
#  loadfactor.pl
#
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
#
# ============================================================
use strict;
use warnings;

# ---- CONFIGURE THIS ----
my $cores = 16;
# ------------------------

my $load = get_load_average();

printf "%.2f %d\n", $load, $cores;

sub get_load_average {
    if (-r '/proc/loadavg') {
        open my $fh, '<', '/proc/loadavg' or die "Cannot read /proc/loadavg: $!";
        my $line = <$fh>;
        close $fh;
        my ($one_min) = split /\s+/, $line;
        return $one_min + 0;
    }

    # macOS / BSD fallback
    my $out = `sysctl -n vm.loadavg 2>/dev/null`;
    if ($out =~ /\{\s*([\d.]+)/) {
        return $1 + 0;
    }

    # uptime fallback
    my $uptime = `uptime 2>/dev/null`;
    if ($uptime =~ /load averages?:\s*([\d.]+)/i) {
        return $1 + 0;
    }

    die "Cannot determine load average\n";
}
