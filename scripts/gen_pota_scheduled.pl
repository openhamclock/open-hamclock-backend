#!/usr/bin/env perl
# =============================================================================
#
#   ██████╗  ██████╗ ████████╗ █████╗
#  ██╔══██╗██╔═══██╗╚══██╔══╝██╔══██╗
#  ██████╔╝██║   ██║   ██║   ███████║
#  ██╔═══╝ ██║   ██║   ██║   ██╔══██║
#  ██║     ╚██████╔╝   ██║   ██║  ██║
#  ╚═╝      ╚═════╝    ╚═╝   ╚═╝  ╚═╝
#
#  Open HamClock Backend (OHB)
#  gen_pota_scheduled.pl -- POTA planned/scheduled activations, rolling window
#
#  Part of the OHB project:
#  https://github.com/openhamclock/open-hamclock-backend/tree/main
#
#  Fetches https://api.pota.app/activation (the full, unpaginated,
#  undocumented feed of activator-submitted planned activations -- both
#  discrete one-off plans AND open-ended "standing intent" declarations
#  that can span months) and reduces it to a rolling window suitable for
#  a HamClock pane in the style of Weekend Contests: pota_scheduled.txt.
#
#  Deliberately minimal fields: activator, park reference, start/end
#  epoch, frequencies. Park name and state/province are NOT included --
#  onta_parks.txt (written by gen_onta.pl / gen_xonta.pl) already maps
#  reference -> state, and POTA's own park CSV (see gen_onta.pl's
#  $POTA_CSV / update_pota_parks_cache.sh) has the name. No need to carry
#  either one again in this file.
#
#  DESIGN NOTES
#  ------------
#  * The upstream feed has NO pagination and NO window/date filter param
#    -- every run downloads the entire future backlog (hundreds of rows,
#    stretching a year-plus out) regardless of $WINDOW_DAYS. All windowing
#    happens locally, after the fetch.
#
#  * Two very different row shapes coexist in the same feed:
#      - Discrete plans: startDate/endDate cover 1-3 days, startTime/
#        endTime are a real single activation window.
#          e.g. N8XQM, US-3517, 2026-09-11 to 2026-09-13, 12:00-23:00
#      - Standing intent: startDate/endDate span months, startTime/
#        endTime describe a DAILY recurring window, not one continuous
#        activation.
#          e.g. K2AYE, US-3812, 2026-02-15 to 2026-10-10, 20:25-18:59
#    A plain "does [startDate,endDate] overlap my window" filter lets
#    every standing-intent row bleed into EVERY week's pane forever,
#    which defeats the point of a "this week" view (cp. Weekend
#    Contests, which only ever shows things with a real end).
#    MAX_SPAN_DAYS below excludes rows whose span exceeds it. This is a
#    judgment call, not a POTA-documented distinction -- tune it.
#
#  * A row can legitimately have startDate before the window (an
#    already-underway multi-day activation, e.g. one that began last
#    week and runs through this week) -- that's kept on purpose: it's
#    still active NOW, not stale. $ONLY_FUTURE_START below can flip
#    this off if the pane should instead read strictly as "starts this
#    week" rather than "is happening this week".
#
#  * Some rows have endTime before startTime on the SAME endDate/
#    startDate (observed upstream, e.g. start 11:30 end 01:30 same
#    day) -- this isn't an overnight-rollover window (those use a
#    later endDate), it's malformed submitter data. Dropped as $bad.
#
#  * Upstream has been observed to contain literal duplicate submissions
#    (same activator/park/date/time resubmitted several times with
#    different scheduledActivitiesId). Deduped below.
#
#  * All times upstream are UTC (unauthenticated, no tz field is given;
#    this matches POTA's own site behavior, which displays/accepts
#    schedule times in UTC).
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
# =============================================================================

use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json);
use Time::Local qw(timegm);
use File::Copy qw(move);

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
my $POTA_URL = 'https://api.pota.app/activation';

# Shared with gen_onta.pl / gen_xonta.pl / split_onta.pl -- this script
# only ADDS its own file (pota_scheduled.txt) here, it never touches
# onta.txt or onta_parks.txt, so no locking/merge coordination with
# those scripts is needed (cp. gen_onta.pl's merge_park_states() flock
# dance, which is about two scripts sharing ONE file, not this case).
my $OUTDIR = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA';
my $OUT    = "$OUTDIR/pota_scheduled.txt";
my $TMP    = "/opt/hamclock-backend/htdocs/tmp/pota_scheduled.txt.$$.tmp";

# Rolling window: "next N days" from the start of today (UTC), not from
# the exact current second -- so the whole window is stable for the rest
# of today's runs and doesn't creep as the day goes on.
my $WINDOW_DAYS = 7;

# Exclude "standing intent" rows whose declared span exceeds this many
# days -- see DESIGN NOTES above. Raise this if you'd rather show
# long-running declarations too (they'll then show up in every week's
# window for as long as they're active); lower it to be stricter about
# only showing genuinely discrete plans.
my $MAX_SPAN_DAYS = 21;

# If true, only keep rows whose startEpoch is still in the future (i.e.
# a strict "starts this week" pane). If false (default), also keep
# already-underway activations whose end still falls in the window
# (a "happening this week" pane, including in-progress multi-day ones).
# See DESIGN NOTES above.
my $ONLY_FUTURE_START = 0;

# HamClock-style sanity caps (mirrors gen_onta.pl's $MAX_CALL)
my $MAX_CALL = 12;
my $MAX_REF  = 16;    # POTA references are short (e.g. "US-13576"); generous cap
my $MAX_FREQ = 64;    # frequencies field is free text (e.g. "160m - 6m", "14074 7074")

# ---------------------------------------------------------------------------
# Sanitize a string field from upstream JSON before it enters the output
# file. Upstream has been observed to contain embedded commas, CJK
# full-width punctuation, and very long comments -- see the CN-* rows in
# the raw feed. Strips control chars, collapses whitespace, removes
# commas (this is a comma-delimited file), trims, and caps length.
# Mirrors gen_onta.pl's clean_field().
# ---------------------------------------------------------------------------
sub clean_field {
    my ($v, $maxlen) = @_;
    return '' unless defined $v;
    $v =~ s/[\x00-\x1F\x7F]+/ /g;    # control chars incl. \n \r \t
    $v =~ s/,+/ /g;                   # commas break the CSV
    $v =~ s/\s+/ /g;                  # collapse whitespace
    $v =~ s/^\s+|\s+$//g;             # trim
    $v = substr($v, 0, $maxlen) if defined($maxlen) && length($v) > $maxlen;
    return $v;
}

# ---------------------------------------------------------------------------
# Parse a "YYYY-MM-DD" + "HH:MM" pair (both UTC) into a Unix epoch.
# Returns undef on anything malformed rather than dying -- one bad row
# upstream shouldn't take down the whole feed.
# ---------------------------------------------------------------------------
sub parse_epoch {
    my ($date, $time) = @_;
    return undef unless defined($date) && defined($time);
    my ($Y, $Mo, $D) = $date =~ /^(\d{4})-(\d{2})-(\d{2})$/ or return undef;
    my ($H, $Mi)     = $time =~ /^(\d{2}):(\d{2})$/         or return undef;
    my $epoch = eval { timegm(0, $Mi, $H, $D, $Mo - 1, $Y) };
    return undef if $@;
    return $epoch;
}

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------
my $ua = LWP::UserAgent->new(
    timeout => 20,
    agent   => 'OHB/1.1 (+https://github.com/openhamclock/open-hamclock-backend)',
);

my $resp = $ua->get($POTA_URL);
unless ($resp->is_success) {
    die "POTA scheduled-activations fetch failed: " . $resp->status_line . "\n";
}

# IMPORTANT: use ->content (raw bytes), not ->decoded_content. LWP's
# decoded_content() already charset-decodes the body into Perl's
# internal Unicode string when the response declares charset=utf-8 (as
# this API does). decode_json() itself expects to be the one doing that
# decoding, from raw UTF-8 bytes -- handing it an already-decoded string
# makes it double-decode, silently mangling every non-ASCII character
# (accents, CJK, etc.) into U+FFFD replacement chars. ->content sidesteps
# this: it's the raw byte string decode_json() actually wants.
my $rows = eval { decode_json($resp->content) };
if ($@) {
    die "POTA scheduled-activations JSON parse failed: $@\n";
}
unless (ref $rows eq 'ARRAY') {
    die "POTA scheduled-activations: unexpected JSON shape (not an array)\n";
}

# ---------------------------------------------------------------------------
# Window bounds: start of today (UTC) through start of today + N days.
# ---------------------------------------------------------------------------
my @gm = gmtime(time());
my $today_start = timegm(0, 0, 0, $gm[3], $gm[4], $gm[5]);
my $window_start = $today_start;
my $window_end   = $today_start + $WINDOW_DAYS * 86400;

# ---------------------------------------------------------------------------
# Filter, sanitize, dedup
# ---------------------------------------------------------------------------
my %best;   # dedup key -> row hashref
my %counts = ( seen => 0, kept => 0, dup => 0, too_long => 0, bad => 0 );

for my $r (@$rows) {
    next unless ref $r eq 'HASH';
    $counts{seen}++;

    my $call = clean_field($r->{activator}, $MAX_CALL);
    next unless length $call;

    my $ref  = clean_field($r->{reference}, $MAX_REF);
    next unless length $ref;

    my $start_epoch = parse_epoch($r->{startDate}, $r->{startTime});
    my $end_epoch   = parse_epoch($r->{endDate},   $r->{endTime});
    unless (defined($start_epoch) && defined($end_epoch)) {
        $counts{bad}++;
        next;
    }

    # Malformed upstream data: endTime before startTime on the SAME
    # date isn't an overnight-rollover window (those carry a later
    # endDate) -- it's a submitter mistake. Drop rather than publish a
    # negative-duration row. See DESIGN NOTES.
    if ($end_epoch < $start_epoch) {
        $counts{bad}++;
        next;
    }

    # window overlap test, at the DATE level (time-of-day within a
    # multi-day span is a daily recurring window, not literal)
    next if $end_epoch   < $window_start;
    next if $start_epoch > $window_end;

    # optionally require the activation to not have started yet -- see
    # $ONLY_FUTURE_START above
    if ($ONLY_FUTURE_START) {
        next if $start_epoch < time();
    }

    # exclude standing-intent rows whose declared span is implausibly
    # long for a "this week" pane -- see DESIGN NOTES at top of file
    my $span_days = ($end_epoch - $start_epoch) / 86400;
    if ($span_days > $MAX_SPAN_DAYS) {
        $counts{too_long}++;
        next;
    }

    my $freqs = clean_field($r->{frequencies}, $MAX_FREQ);

    # dedup key: identical submissions differing only by
    # scheduledActivitiesId (observed upstream -- see DESIGN NOTES).
    # NOTE: this is an EXACT match on date/time strings -- near-duplicate
    # submissions that differ by a minute or two (observed upstream for
    # some prolific activators) will NOT collapse. See prior discussion;
    # tightening this further risks hiding genuinely distinct same-day
    # activations at the same park.
    my $key = join('|', $call, $ref, $r->{startDate} // '', $r->{endDate} // '',
                         $r->{startTime} // '', $r->{endTime} // '');

    if (exists $best{$key}) {
        $counts{dup}++;
        # keep whichever duplicate has the more informative frequencies
        # field (comment is no longer carried, so this is the only
        # remaining "richness" signal to break the tie on)
        next if length($best{$key}{freqs}) >= length($freqs);
    }

    $best{$key} = {
        start => $start_epoch,
        end   => $end_epoch,
        call  => $call,
        ref   => $ref,
        freqs => $freqs,
    };
}

my @out = sort { $a->{start} <=> $b->{start} } values %best;
$counts{kept} = scalar @out;

# ---------------------------------------------------------------------------
# Write atomically: tmp file in same filesystem, then rename over the
# published file -- so a client polling mid-write never sees a partial
# file. Same pattern as gen_onta.pl.
# ---------------------------------------------------------------------------
system('mkdir', '-p', $OUTDIR) == 0
    or die "Cannot mkdir $OUTDIR: $!\n";
system('mkdir', '-p', '/opt/hamclock-backend/htdocs/tmp') == 0
    or die "Cannot mkdir /opt/hamclock-backend/htdocs/tmp: $!\n";

open my $fh, '>:encoding(UTF-8)', $TMP or die "Cannot write temp file $TMP: $!\n";
print $fh "#call,ref,startEpoch,endEpoch,freqs\n";
for my $r (@out) {
    print $fh join(',',
        $r->{call},
        $r->{ref},
        $r->{start},
        $r->{end},
        $r->{freqs},
    ), "\n";
}
close $fh;

move $TMP, $OUT or die "move failed $TMP -> $OUT: $!\n";

print "POTA scheduled activations: seen=$counts{seen} kept=$counts{kept} "
    . "dup=$counts{dup} too_long(>$MAX_SPAN_DAYS d)=$counts{too_long} bad=$counts{bad}\n";
print "Window: " . gmtime($window_start) . " UTC through " . gmtime($window_end) . " UTC\n";
print "Wrote $OUT\n";
