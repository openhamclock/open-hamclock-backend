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
#  esats.pl
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

my %params;
for my $pair (split /&/, $ENV{QUERY_STRING} // '') {
    my ($k, $v) = split /=/, $pair, 2;
    $params{$k} = $v // '';
}

open my $fh, '<', '/opt/hamclock-backend/htdocs/ham/HamClock/esats/esats.txt' or die "Cannot open TLE file: $!";
my $data = do { local $/; <$fh> };
close $fh;

if (exists $params{tlename}) {
    my $name = $params{tlename};
    my @blocks = ($data =~ /^\Q$name\E\n(?:.*\n){2}/gm);
    print join '', @blocks;
} else {
    # getall= or anything else just dumps everything
    print $data;
}
