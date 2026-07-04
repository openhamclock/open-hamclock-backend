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
use CGI;

my $q = CGI->new;
my $cache_dir = "/opt/hamclock-backend/cache";
my $GIT_VERSION_FILE = '/opt/hamclock-backend/git.version';

# 1. Validate parameter count and identify flags (case-insensitive)
my @params = $q->param;

# If query string has no '=' (e.g. ?hamclock), CGI.pm treats it as keywords
if (scalar @params == 1 && $params[0] eq 'keywords') {
    @params = $q->keywords;
}

@params = grep { $_ ne '' } @params;

# Ignore unknown parameters by filtering to only keep known ones (case-insensitive)
@params = grep { /^open-hamclock-backend$/i || /^hamclock$/i } @params;

my $has_ohb = grep { /^open-hamclock-backend$/i } @params;
my $has_hc  = grep { /^hamclock$/i } @params;

# 1. Validate parameter count
if (scalar @params > 1) {
    print $q->header(-type => 'text/plain', -status => '400 Bad Request');
    print "ERROR: Multiple parameters are not allowed.\n";
    exit;
}

# 2. Handle specific version requests for the OHB backend
if ($has_ohb) {
    if (-f $GIT_VERSION_FILE) {
        if (open(my $fh, '<', $GIT_VERSION_FILE)) {
            local $/; # Slurp mode
            my $content = <$fh>;
            close($fh);
            print $q->header('text/plain');
            print $content;
        } else {
            print $q->header(-type => 'text/plain', -status => '500 Internal Server Error');
            print "ERROR: Could not read $GIT_VERSION_FILE: $!\n";
        }
    } else {
        print $q->header(-type => 'text/plain', -status => '404 Not Found');
        print "ERROR: Version file not found.\n";
    }
    exit;
}

# 3. Block unrecognized single parameters
if (scalar @params == 1 && !$has_hc && !$has_ohb) {
    print $q->header(-type => 'text/plain', -status => '400 Bad Request');
    print "ERROR: Invalid parameter: $params[0]\n";
    exit;
}

# 4. Default functionality: Parse User-Agent and proceed
my $ua_string = $q->user_agent() || "";

# Check for legacy ESPHamClock clients first
my $is_esp = ($ua_string =~ /ESPHamClock/i);

# Existing version extraction for standard clients
my ($client_ver) = $ua_string =~ m|HamClock-.*?/([\d\.b]+)|i;

# 2. Get the current Stable version number
my $stable_ver_num = "";
my $stable_path = "$cache_dir/HC_RELEASE-stable.txt";
if (-f $stable_path) {
    open(my $fh, '<', $stable_path) or die $!;
    $stable_ver_num = <$fh>;
    close($fh);
    $stable_ver_num =~ s/\s+//g; # Clean up whitespace/newlines
}

# 3. Determine Offer Type
my $offer_type = "stable";

if ($is_esp) {
    # Targeted edit for ESP clients: force version 3.10
    $offer_type = "3.10";
} elsif ($client_ver && $client_ver =~ /b/i) {
    # Extract numeric base: "4.22b01" -> "4.22"
    my ($base_ver) = $client_ver =~ /^([\d\.]+)/;

    # Logic: Only stay on beta if base_ver > stable_ver_num
    if ($base_ver && $stable_ver_num) {
        if (version_cmp($base_ver, $stable_ver_num) > 0) {
            $offer_type = "beta";
        } else {
            $offer_type = "stable";
        }
    }
}

# 4. Output the file
my $final_path = "$cache_dir/HC_RELEASE-$offer_type.txt";

# Print header (required for CGI)
print $q->header('text/plain');

if (-f $final_path) {
    open(my $fh, '<', $final_path) or die $!;
    local $/;
    my $content = <$fh>;
    close($fh);

    # If this is the ESP version, ensure it points to the specific zip
    if ($is_esp) {
        $content =~ s/ESPHamClock-V[\d\.]+\.zip/ESPHamClock-V3.10.zip/g;
    }

    print $content;
} else {
    print "Unknown\n";
}

# Robust version comparison: returns 1 if v1 > v2, -1 if v1 < v2, 0 if equal
sub version_cmp {
    my ($v1, $v2) = @_;
    my @a = split(/\./, $v1);
    my @b = split(/\./, $v2);
    while (@a || @b) {
        my $curr_a = shift @a || 0;
        my $curr_b = shift @b || 0;
        return 1  if $curr_a > $curr_b;
        return -1 if $curr_a < $curr_b;
    }
    return 0;
}
exit;
