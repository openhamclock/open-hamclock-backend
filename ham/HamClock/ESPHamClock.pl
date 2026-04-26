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
use CGI;

# --- Configuration ---
my $cache_dir    = "/opt/hamclock-backend/cache";

my $q = CGI->new;
# $q->keywords captures the $1 from the lighttpd rewrite (e.g., ESPHamClock.zip)
my ($query_file) = $q->keywords;
$query_file //= "";
my $user_agent = $q->user_agent() || "";

# 1. Determine the target filename
my $target_file = "";
my $content_type = 'application/zip';

if ($query_file eq "ESPHamClock-main.zip") {
    # Case 0: Explicit request for the main branch build
    $target_file = "ESPHamClock-main.zip";
} elsif ($query_file =~ /^ESPHamClock-V[\d\.]+(b\d+)?\.zip$/i) {
    # Case A: Specific version requested directly
    $target_file = $query_file;
} elsif ($query_file eq "ESPHamClock.zip") {
    # Case B: Generic request - Determine version from first line of .txt cache
    my $version_info_file;

    # Check if Agent indicates a beta user
    if ($user_agent =~ /^HamClock-.*\/.*b/i) {
        $version_info_file = "$cache_dir/HC_RELEASE-beta.txt";
    } else {
        $version_info_file = "$cache_dir/HC_RELEASE-stable.txt";
    }

    if (-e $version_info_file) {
        if (open(my $fh, '<', $version_info_file)) {
            my $version_line = <$fh>; # Read first line (the stripped version)
            close($fh);

            if ($version_line) {
                # \R handles all line ending types (\n, \r\n, etc.)
                $version_line =~ s/\R//g;
                # Constructs filename like ESPHamClock-V4.22.zip
                $target_file = "ESPHamClock-V$version_line.zip";
            }
        }
    }
} elsif ($query_file =~ /^ESPHamClock(-V3\.10)?\.ino\.bin$/i) {
    # Case C: ESP8266 binary request
    if ($user_agent eq "ESP8266-http-Update") {
        $target_file = "ESPHamClock-V3.10.ino.bin";
        $content_type = 'application/octet-stream';
    }
}

# 2. Check for file existence and serve
my $full_path = "$cache_dir/$target_file";

if ($target_file ne "" && -f $full_path) {
    my $filesize = -s $full_path;

    print $q->header(
        -type           => $content_type,
        -attachment     => $target_file,
        -content_length => $filesize,
    );

    open(my $fh, '<', $full_path) or die "Cannot open file: $!";
    binmode $fh;
    binmode STDOUT;

    my $buffer;
    # Stream in 4KB chunks for memory efficiency
    while (read($fh, $buffer, 4096)) {
        print $buffer;
    }
    close($fh);
} else {
    # 404 Error: Either $target_file was never set or the file is missing
    print $q->header(
        -status => '404 Not Found',
        -type   => 'text/plain'
    );
    print "404 Not Found: The requested version is not available on this server.\n";
}
