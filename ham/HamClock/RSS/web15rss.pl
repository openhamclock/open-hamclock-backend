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

# web15rss.pl — client-facing, called by HamClock clients via OHB
# Reads only from local cache. Never fetches from network.
# Emits a single ISO-8859-1 text/plain response (CSI-compatible style).
# If a cache file is missing/unreadable, that source is silently skipped.
# If a line cannot be decoded/encoded cleanly, it is skipped (no CGI crash).

use strict;
use warnings;
use Encode qw(decode encode FB_CROAK FB_DEFAULT);

my $CACHE_DIR = '/opt/hamclock-backend/cache/rss';

# Source file encodings as written by your cache builders.
my @sources = (
    { name => 'arnewsline', encoding => 'UTF-8'      },
    { name => 'ng3k',       encoding => 'ISO-8859-1' },
    { name => 'hamweekly',  encoding => 'UTF-8'      },
);

# CGI header (CSI returns ISO-8859-1 for this endpoint)
print "Content-Type: text/plain; charset=ISO-8859-1\r\n";
print "Connection: close\r\n";
print "\r\n";

# IMPORTANT: one output encoding for the whole response stream
binmode(STDOUT, ':raw');

for my $src (@sources) {
    my $path = "$CACHE_DIR/$src->{name}.txt";
    next unless -f $path && -r $path;

    # Read raw bytes to avoid implicit decode exceptions during <$fh>
    open my $fh, '<:raw', $path or next;

    while (my $raw = <$fh>) {
        # Normalize line ending in raw bytes first
        $raw =~ s/\r?\n\z//;

        # Decode according to source's declared encoding.
        # If decode fails (e.g., partial write / malformed bytes), skip line.
        my $text = eval { decode($src->{encoding}, $raw, FB_CROAK) };
        next if !defined $text;

        # Encode final wire output as ISO-8859-1 (CSI-compatible).
        # If a char can't be represented, replace conservatively instead of dying.
        my $out = eval { encode('ISO-8859-1', $text, FB_DEFAULT) };
        next if !defined $out;

        print $out, "\n";
    }

    close $fh;
}

exit 0;
