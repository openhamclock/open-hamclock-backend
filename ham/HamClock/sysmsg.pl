#!/usr/bin/env perl

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
use LWP::UserAgent;

my $alpha = $ENV{ALPHA_INSTALL} // '';

if ($alpha eq 'true') {
    # Serve the message from the local data file
    my $local_msg = '/opt/hamclock-backend/data/msg/sysmsg.txt';
    print "Content-Type: text/plain\r\n\r\n";
    if (-f $local_msg && open(my $fh, '<', $local_msg)) {
        print while <$fh>;
        close($fh);
    }
} else {
    # Pull (proxy) from the host provided in ALPHA_INSTALL
    my $host = $alpha || 'ohb.hamclock.app';
    $host =~ s|^https?://||;
    my $url = "http://$host/ham/HamClock/sysmsg.pl";

    my $ua = LWP::UserAgent->new(timeout => 5);
    $ua->agent($ENV{HTTP_USER_AGENT} // 'OHB-Proxy/1.0');
    my $resp = $ua->get($url);

    print "Content-Type: text/plain\r\n\r\n";
    if ($resp->is_success) {
        print $resp->decoded_content;
    }
}
