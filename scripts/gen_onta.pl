#!/usr/bin/env perl
# =============================================================================
#
#   #####   #     #  ######
#  #     #  #     #  #     #
#  #     #  #     #  #     #
#  #     #  #######  ######
#  #     #  #     #  #     #
#  #     #  #     #  #     #
#   #####   #     #  ######
#
#  Open HamClock Backend (OHB)
#  gen_onta.pl -- POTA / WWFF on-the-air spot aggregator
#
#  Part of the OHB project:
#  https://github.com/openhamclock/open-hamclock-backend/tree/main
#
#  Aggregates spots from POTA and WWFF. This script deduplicates
#  activations, resolves location data from cached reference CSVs, and
#  produces the onta.txt file consumed by HamClock.
#
#  onta_parks.txt NOTE: this side file is shared with gen_xonta.pl, which
#  contributes SOTA park->state entries on its own schedule. Since a
#  park's resolved state never changes, and POTA/WWFF references never
#  collide in shape with SOTA's "ASSOC/SUMMIT" ones, this script MERGES
#  its own freshly-resolved entries into whatever's already on disk
#  rather than overwriting the file wholesale -- otherwise, whichever of
#  the two scripts runs last would silently erase the other's
#  contribution. See merge_park_states() below.
#
#  WWFF NOTE: Per request from Mario, DL4MFM (https://www.cqgma.org),
#  the GMA WWFF API is rate limited to 1 req/min and 1440 req/day per
#  client. OHB has always been configured to run 30 req/hr or 720 reg/day.
#
#  *** Please do NOT set OHB_WWFF_URL to https://www.cqgma.org/... ***
#  *** on a self-install. That defeats the purpose of the mirror. ***
##
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
# =============================================================================

use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json);
use Time::Local;
use Text::CSV_XS;
use File::Copy qw(move);

my $POTA_URL = 'https://api.pota.app/spot';

# WWFF source: Managed locally by fetch_wwff_cache.pl.
my $WWFF_URL = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/wwff_spots.json';

my $OUT      = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/onta.txt';
my $TMP      = '/opt/hamclock-backend/htdocs/tmp/onta.txt.tmp';

# Shared side file: reference -> 2-letter state/province/country, kept
# apart from onta.txt so that file's format/consumers are completely
# undisturbed. Purely additive -- HamClock can ignore this file entirely
# and nothing changes. Also written to by gen_xonta.pl (SOTA) -- see the
# onta_parks.txt NOTE above and merge_park_states() below.
my $PARKS_OUT = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/onta_parks.txt';
my $PARKS_TMP = '/opt/hamclock-backend/htdocs/tmp/onta_parks.txt.tmp';

my $POTA_CSV = '/opt/hamclock-backend/cache/all_parks_ext.csv';
my $WWFF_CSV = '/opt/hamclock-backend/cache/wwff_parks.csv';

my %csv_generators = (
    $POTA_CSV => '/opt/hamclock-backend/scripts/update_pota_parks_cache.sh',
    $WWFF_CSV => '/opt/hamclock-backend/scripts/update_wwff_cache.pl',
);

# HamClock rejects callsigns longer than 12 characters
my $MAX_CALL  = 12;
# HamClock's ONTA age selector maxes out at 60 min (10/20/40/60), so it
# discards anything older regardless. Bound the feed at 65 min: just past
# HamClock's max so its selector stays the real filter, with ~5 min margin
# to cover the rebuild interval.
my $MAX_AGE_S = 3900;

# ---------------------------------------------------------------------------
# Classify a reference as POTA, SOTA, or WWFF. (SOTA no longer flows
# through this script -- see the SOTA NOTE above -- but the check stays
# here for parity/defensiveness in case a SOTA-shaped ref ever turns up
# in POTA/WWFF's own feeds.)
#
# WWFF references look like "ONFF-0001", "VKFF-1234", "S5FF-0001" -- a
# 1-4 character prefix (which may start with a digit, e.g. Croatia's
# "9A", Israel's "4X") followed by "FF-". SOTA references always
# contain a "/" ("S5/RG-053", "W7O/CG-041"). Anything else is POTA.
# ---------------------------------------------------------------------------
sub org_from_ref {
    my ($ref) = @_;
    return 'WWFF' if defined($ref) && $ref =~ /^[A-Z0-9]{1,4}FF-/i;
    return 'SOTA' if defined($ref) && $ref =~ m{/};     # e.g. W7O/NC-051
    return 'POTA';
}

# ---------------------------------------------------------------------------
# Ham callsign/association prefix -> ISO 3166-1 alpha-2 country/territory
# code. Keyed by the ACTUAL WWFF REFERENCE PREFIX (the text before "FF-"
# in a real reference like "RFF-0001"), extracted and validated against
# all 65,891 real references in a production wwff_directory.csv on
# 2026-09 -- NOT the directory's separate "dxcc" column, which is a
# DIFFERENT, more granular value and was the source of an earlier bug
# here: Russia's European (RA) and Asiatic (RA9) regions both use the
# bare reference prefix "R", Turkey's TA1/TA2 both use "TA", Malaysia's
# 9M2/9M8 both use "9M" -- a table keyed by "dxcc" values looks
# reasonable but silently never matches any real reference.
#
# A few reference prefixes are genuinely ambiguous in WWFF's own data --
# more than one country/territory shares the same bare prefix with no
# way to disambiguate from the reference alone:
#   - "F" is used for ALL French territories, not just mainland France
#     -- Guadeloupe, Martinique, Reunion, French Guiana, Corsica, and
#     the French Southern & Antarctic Lands all use bare "FFF-"
#     references (confirmed directly against the real data; unlike
#     SOTA, which keeps these as separate association prefixes).
#   - "HB" is used by both Switzerland (the large majority) and some
#     Liechtenstein parks (most Liechtenstein parks correctly use "HB0"
#     instead, which resolves separately -- but not all of them do).
#   - "G" and "VP" each span mainland UK/a UK overseas territory (South
#     Georgia, Falklands, Pitcairn, Turks & Caicos, Tristan da Cunha...),
#     each of which has its own real ISO code that the shared prefix
#     can't distinguish.
# All of these default to the overwhelming-majority country (FR, CH, GB)
# as a deliberate, documented simplification -- not a precise
# per-territory match. "1S" (Spratly Islands) is a disputed territory
# with no clean ISO code and is deliberately left OUT of this table
# rather than guessed -- it resolves to a blank state.
# ---------------------------------------------------------------------------
my %PREFIX_COUNTRY = (
    '3A' => 'MC',
    '3B' => 'MU',
    '3C' => 'GQ',
    '3D2' => 'FJ',
    '3DA' => 'SZ',
    '3V' => 'TN',
    '3W' => 'VN',
    '3X' => 'GN',
    '4J' => 'AZ',
    '4L' => 'GE',
    '4O' => 'ME',
    '4S' => 'LK',
    '4W' => 'TL',
    '4X' => 'IL',
    '5A' => 'LY',
    '5B' => 'CY',
    '5H' => 'TZ',
    '5N' => 'NG',
    '5R' => 'MG',
    '5T' => 'MR',
    '5U' => 'NE',
    '5V' => 'TG',
    '5W' => 'WS',
    '5X' => 'UG',
    '5Z' => 'KE',
    '6W' => 'SN',
    '6Y' => 'JM',
    '7O' => 'YE',
    '7P' => 'LS',
    '7Q' => 'MW',
    '7X' => 'DZ',
    '8P' => 'BB',
    '8R' => 'GY',
    '9A' => 'HR',
    '9G' => 'GH',
    '9H' => 'MT',
    '9J' => 'ZM',
    '9K' => 'KW',
    '9L' => 'SL',
    '9M' => 'MY',
    '9N' => 'NP',
    '9Q' => 'CD',
    '9U' => 'BI',
    '9V' => 'SG',
    '9X' => 'RW',
    'A2' => 'BW',
    'A5' => 'BT',
    'A6' => 'AE',
    'AN' => 'AQ',
    'AP' => 'PK',
    'BV' => 'TW',
    'BY' => 'CN',
    'C3' => 'AD',
    'C5' => 'GM',
    'C6' => 'BS',
    'C9' => 'MZ',
    'CE' => 'CL',
    'CN' => 'MA',
    'CO' => 'CU',
    'CP' => 'BO',
    'CT' => 'PT',
    'CU' => 'PT',
    'CX' => 'UY',
    'CY' => 'CA',
    'D2' => 'AO',
    'D4' => 'CV',
    'D6' => 'KM',
    'DL' => 'DE',
    'DU' => 'PH',
    'E3' => 'ER',
    'E5' => 'CK',
    'E7' => 'BA',
    'EA' => 'ES',
    'EI' => 'IE',
    'EK' => 'AM',
    'EL' => 'LR',
    'EP' => 'IR',
    'ER' => 'MD',
    'ES' => 'EE',
    'ET' => 'ET',
    'EW' => 'BY',
    'EX' => 'KG',
    'EY' => 'TJ',
    'EZ' => 'TM',
    'F' => 'FR',
    'G' => 'GB',
    'GD' => 'IM',
    'GI' => 'GB',
    'GJ' => 'JE',
    'GM' => 'GB',
    'GU' => 'GG',
    'GW' => 'GB',
    'H4' => 'SB',
    'HA' => 'HU',
    'HB' => 'CH',
    'HB0' => 'LI',
    'HC' => 'EC',
    'HH' => 'HT',
    'HI' => 'DO',
    'HK' => 'CO',
    'HL' => 'KR',
    'HP' => 'PA',
    'HR' => 'HN',
    'HS' => 'TH',
    'HZ' => 'SA',
    'I' => 'IT',
    'J2' => 'DJ',
    'J6' => 'LC',
    'J7' => 'DM',
    'JA' => 'JP',
    'JT' => 'MN',
    'JY' => 'JO',
    'K' => 'US',
    'LA' => 'NO',
    'LU' => 'AR',
    'LX' => 'LU',
    'LY' => 'LT',
    'LZ' => 'BG',
    'OA' => 'PE',
    'OD' => 'LB',
    'OE' => 'AT',
    'OH' => 'FI',
    'OK' => 'CZ',
    'OM' => 'SK',
    'ON' => 'BE',
    'OZ' => 'DK',
    'P2' => 'PG',
    'P4' => 'AW',
    'P5' => 'KP',
    'PA' => 'NL',
    'PY' => 'BR',
    'PZ' => 'SR',
    'R' => 'RU',
    'S2' => 'BD',
    'S5' => 'SI',
    'S7' => 'SC',
    'S9' => 'ST',
    'SM' => 'SE',
    'SP' => 'PL',
    'ST' => 'SD',
    'SU' => 'EG',
    'SV' => 'GR',
    'T2' => 'TV',
    'T3' => 'KI',
    'T5' => 'SO',
    'T8' => 'PW',
    'TA' => 'TR',
    'TF' => 'IS',
    'TG' => 'GT',
    'TI' => 'CR',
    'TJ' => 'CM',
    'TL' => 'CF',
    'TN' => 'CG',
    'TR' => 'GA',
    'TT' => 'TD',
    'TU' => 'CI',
    'TY' => 'BJ',
    'TZ' => 'ML',
    'UF' => 'GE',
    'UK' => 'UZ',
    'UN' => 'KZ',
    'UR' => 'UA',
    'V2' => 'AG',
    'V3' => 'BZ',
    'V4' => 'KN',
    'V5' => 'NA',
    'V6' => 'FM',
    'V7' => 'MH',
    'V8' => 'BN',
    'VE' => 'CA',
    'VK' => 'AU',
    'VP' => 'GB',
    'VR' => 'HK',
    'VU' => 'IN',
    'XE' => 'MX',
    'XT' => 'BF',
    'XU' => 'KH',
    'XW' => 'LA',
    'XY' => 'MM',
    'YA' => 'AF',
    'YB' => 'ID',
    'YJ' => 'VU',
    'YK' => 'SY',
    'YL' => 'LV',
    'YN' => 'NI',
    'YO' => 'RO',
    'YS' => 'SV',
    'YU' => 'RS',
    'YV' => 'VE',
    'Z2' => 'ZW',
    'Z3' => 'MK',
    'ZA' => 'AL',
    'ZB' => 'GI',
    'ZD' => 'SH',
    'ZF' => 'KY',
    'ZL' => 'NZ',
    'ZP' => 'PY',
    'ZS' => 'ZA',
);

# Prefixes we've already warned about, so a busy feed doesn't spam the
# log with the same unmapped prefix over and over.
my %warned_prefix;

sub prefix_country {
    my ($prefix) = @_;
    return '' unless length $prefix;
    $prefix = uc $prefix;
    for my $len (reverse 1 .. length $prefix) {
        my $try = substr($prefix, 0, $len);
        return $PREFIX_COUNTRY{$try} if exists $PREFIX_COUNTRY{$try};
    }
    unless ($warned_prefix{$prefix}) {
        warn "resolve_state: no country mapping for prefix '$prefix' -- add it to \%PREFIX_COUNTRY\n";
        $warned_prefix{$prefix} = 1;
    }
    return '';
}

# ---------------------------------------------------------------------------
# Sanitize a string field from upstream JSON before it enters the output
# line. Upstream APIs occasionally return callsigns/modes/refs containing
# embedded newlines, tabs, commas, or stray whitespace (e.g. Parks'n'Peaks
# has returned "TF3EK\n/P" as actCallsign), which corrupts the CSV-style
# onta.txt file. Strips control chars, collapses internal whitespace,
# removes commas, and trims edges. Returns '' for undef input.
# ---------------------------------------------------------------------------
sub clean_field {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/[\x00-\x1F\x7F]+/ /g;   # drop control chars (incl. \n, \r, \t)
    $v =~ s/,+/ /g;                  # commas would break the CSV
    $v =~ s/\s+/ /g;                 # collapse runs of whitespace
    $v =~ s/^\s+|\s+$//g;            # trim
    return $v;
}

# ---------------------------------------------------------------------------
# Sanitize a frequency field before numeric use. Upstream WWFF/GMA API has
# been observed to prefix QRG values with stray junk, e.g. ": 5354.0" or
# "p: 14308.", which numifies to 0 in Perl and silently fails the
# "$freq > 0" sanity check further down -- discarding an otherwise valid
# spot. Strip anything that isn't a digit, a decimal point, or a leading
# minus sign, then let the caller re-validate the result.
# ---------------------------------------------------------------------------
sub clean_freq {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/[^0-9.\-]//g;
    return $v;
}

# ---------------------------------------------------------------------------
# Load a reference lookup CSV into a hash keyed by reference string.
# Required columns: reference, latitude, longitude, grid
# Optional column (first match wins, case-sensitive to match each source's
# own header spelling): locationDesc, state, region -- whatever subdivision
# info the source happens to publish. POTA's all_parks_ext.csv has
# "locationDesc" (eg "US-ME", or "US-DC,US-MD,US-WV" for multi-state parks).
# WWFF's wwff_parks.csv has "state" (e.g. "K-ME", "VK-NSW", or a bare
# "S5"/"9A" for countries without subdivisions). If none of these columns
# exist in a given CSV, state is simply left blank for every entry from
# that source -- this is not an error.
# ---------------------------------------------------------------------------
my @LOC_COLS = qw(locationDesc state region);

sub load_lookup {
    my ($path) = @_;
    my %park;

    return %park unless -f $path;

    open my $fh, '<:encoding(UTF-8)', $path or do {
        warn "Cannot read $path: $!\n";
        return %park;
    };

    my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });

    my $header = $csv->getline($fh);
    unless ($header && @$header) {
        warn "Empty or unreadable header in $path\n";
        close $fh;
        return %park;
    }

    my %idx;
    for my $i (0 .. $#$header) {
        my $k = $header->[$i] // next;
        $k =~ s/^"|"$//g;
        $idx{$k} = $i;
    }

    for my $need (qw(reference latitude longitude grid)) {
        unless (exists $idx{$need}) {
            warn "Missing '$need' column in $path\n";
            close $fh;
            return %park;
        }
    }

    my ($loc_col) = grep { exists $idx{$_} } @LOC_COLS;
    if ($loc_col) {
        print "Using '$loc_col' column for state/region from $path\n";
    } else {
        print "No location column found in $path -- state will be blank for this source\n";
    }

    # Optional 'active' column (POTA's all_parks_ext.csv has one; WWFF's
    # own status filtering already happens in update_wwff_cache.pl, so
    # wwff_parks.csv never has this column). Skip inactive/retired/test
    # entries -- e.g. POTA publishes a literal "K-TEST" placeholder park
    # with active=0, locationDesc="None", which previously produced a
    # bogus resolved "state" (substr("None",0,2) -> "NO") and got stuck
    # permanently in onta_parks.txt since that file only merges forward.
    my $i_active = $idx{active};

    while (my $row = $csv->getline($fh)) {
        if (defined $i_active) {
            my $active = $row->[$i_active] // '';
            $active =~ s/^"|"$//g;
            next if $active eq '0' || lc($active) eq 'false' || lc($active) eq 'no';
        }

        my $ref = $row->[$idx{reference}] // next;
        $ref =~ s/^"|"$//g;

        $park{$ref} = {
            lat  => ($row->[$idx{latitude}]  // ''),
            lng  => ($row->[$idx{longitude}] // ''),
            grid => ($row->[$idx{grid}]      // ''),
            loc  => ($loc_col ? ($row->[$idx{$loc_col}] // '') : ''),
        };
    }

    close $fh;
    return %park;
}

# ---------------------------------------------------------------------------
# Merge this run's freshly-resolved park->state entries into whatever's
# already on disk at $path, rather than overwriting it. onta_parks.txt is
# fed by two independent scripts on independent schedules (this one for
# POTA/WWFF, gen_xonta.pl for SOTA); a wholesale overwrite by either one
# would erase the other's contribution. A park's resolved state never
# changes once known, so accumulating entries across runs (rather than
# only keeping "currently active" ones, the way onta.txt itself works) is
# the correct behavior here, not staleness. This run's values win on any
# key collision, since they're the freshest resolution for whichever
# references this script itself just saw.
# ---------------------------------------------------------------------------
sub merge_park_states {
    my ($path, $new) = @_;   # $new: hashref of park => state resolved this run
    my %merged;

    if (open my $fh, '<:encoding(UTF-8)', $path) {
        while (my $line = <$fh>) {
            chomp $line;
            next if $line =~ /^#/ || !length($line);
            my ($park, $state) = split /,/, $line, 2;
            next unless defined($park) && defined($state) && length($park) && length($state);
            $merged{$park} = $state;
        }
        close $fh;
    }

    $merged{$_} = $new->{$_} for keys %$new;
    return %merged;
}

# ---------------------------------------------------------------------------
# Fetch a resource that may be HTTP(S), file://, or a bare local path.
# Returns the body string on success, undef on failure.
# ---------------------------------------------------------------------------
sub fetch_source {
    my ($url, $ua, $label) = @_;

    # Local file path or file:// URL: read directly, no HTTP traffic
    if ($url =~ m{^file://(.+)$} || $url =~ m{^(/.+)$}) {
        my $path = $1;
        unless (-f $path) {
            warn "$label local file not found: $path\n";
            return undef;
        }
        open my $fh, '<', $path or do {
            warn "$label cannot read $path: $!\n";
            return undef;
        };
        local $/;
        my $body = <$fh>;
        close $fh;
        return $body;
    }

    # HTTP(S)
    my $resp = $ua->get($url);
    unless ($resp->is_success) {
        warn "$label fetch failed: " . $resp->status_line . "\n";
        return undef;
    }
    return $resp->decoded_content;
}

foreach my $file (keys %csv_generators) {
    unless (-e $file) {
        my $script = $csv_generators{$file};
        print "Missing $file. Running $script...\n";

        # Execute the specific script
        system("perl $script");

        # Verify the script actually created the file
        if ($? != 0 || !-e $file) {
            print "Error: Failed to generate $file using $script (Exit code: $?). Continuing.\n";
        }
    }
}
my %pota_lookup = load_lookup($POTA_CSV);
my %wwff_lookup = load_lookup($WWFF_CSV);

# Merge into one hash; POTA takes precedence over WWFF for any ref that
# somehow appears in both sources.
my %park_lookup = (%wwff_lookup, %pota_lookup);

my $ua = LWP::UserAgent->new(
    timeout => 10,
    agent   => 'OHB/1.1 (+https://github.com/openhamclock/open-hamclock-backend)',
);

my $now = time();
my %best;   # dedup key -> row hashref
my %counts = ( pota => 0, wwff => 0 );

# ---------------------------------------------------------------------------
# Helper: attempt to resolve location for a park/summit reference.
# Returns (grid, lat, lng) — all empty/zero if not found.
# ---------------------------------------------------------------------------
sub resolve_location {
    my ($ref) = @_;
    return ('', 0, 0) unless $ref && exists $park_lookup{$ref};
    return (
        $park_lookup{$ref}{grid} // '',
        $park_lookup{$ref}{lat}  // 0,
        $park_lookup{$ref}{lng}  // 0,
    );
}

# ---------------------------------------------------------------------------
# Helper: attempt to resolve a 2-letter state/province/country code for a
# park reference.
#
# Behavior is branched by org, because POTA and WWFF each encode location
# differently in their respective cache CSVs:
#
#  - POTA: locationDesc is "ISO2-SUBDIV" (e.g. "US-ME", "GB-ENG",
#    "VE-D"). The country part is always a real ISO 3166-1 alpha-2
#    code. The subdivision part varies in length by country (1 to 4
#    letters) -- only trust it as a 2-letter state/province code when
#    it actually is one; otherwise fall back to the country. (Blindly
#    taking the first 2 characters of the subdivision silently produces
#    wrong/colliding codes for e.g. Australia: "NSW" -> "NS", the same
#    code POTA uses for Nova Scotia.)
#
#  - WWFF: the reference itself carries a ham callsign-style prefix
#    ("VKFF-0001"), not an ISO code, so it's translated via
#    %PREFIX_COUNTRY. WWFF's cache additionally carries a real
#    subdivision for the US/Canada ("K-ME", "VE-BC", and even
#    non-2-letter ones like "VK-NSW" for Australia) which is preferred
#    over the country when it's a genuine 2-letter code.
# ---------------------------------------------------------------------------
sub resolve_state {
    my ($ref) = @_;
    return '' unless $ref;

    my $org = org_from_ref($ref);
    my $loc = (exists $park_lookup{$ref}) ? ($park_lookup{$ref}{loc} // '') : '';
    my ($first) = length($loc) ? (split /,/, $loc)[0] : ();
    $first //= '';

    if ($org eq 'POTA') {
        return '' unless length $first;
        my ($country, $sub) = ($first =~ /^([^-]+)-(.+)$/) ? ($1, $2) : ($first, '');
        $sub =~ s/^\s+|\s+$//g if length $sub;
        return uc($sub) if length($sub) == 2;
        return uc($country) if length($country) == 2;
        return '';
    }

    # WWFF (and, defensively, a SOTA-shaped ref though none should reach
    # this script anymore): derive the country from the reference's own
    # prefix, since that's reliable regardless of what the cache CSV
    # carries.
    my $assoc_prefix = '';
    if ($ref =~ m{^([A-Za-z0-9]+)/}) {
        $assoc_prefix = $1;
    } elsif ($ref =~ /^([A-Za-z0-9]{1,4})FF-/i) {
        $assoc_prefix = $1;
    }
    my $country = length($assoc_prefix) ? prefix_country($assoc_prefix) : '';

    if (length $first) {
        if ($first =~ /^[^-]+-(.+)$/) {
            # WWFF's carried-through "state" column: "K-ME", "VE-BC",
            # "VK-NSW". Only trust the part after the dash if it's a
            # real 2-letter code (Australia mixes "WA" with 3-4 letter
            # codes like "NSW"/"QLD" -- don't truncate those).
            my $sub = $1;
            $sub =~ s/^\s+|\s+$//g;
            return uc($sub) if length($sub) == 2;
        } elsif (($country eq 'US' || $country eq 'CA') && length($first) == 2) {
            return uc($first);
        }
    }

    return $country if length $country;
    return '';
}

# ---------------------------------------------------------------------------
# Source 1: POTA  (https://api.pota.app/spot)
# Fields: activator, frequency (kHz), mode, reference, spotTime (ISO8601 UTC)
# ---------------------------------------------------------------------------
{
    my $body = fetch_source($POTA_URL, $ua, 'POTA');
    if (defined $body) {
        my $spots = eval { decode_json($body) };
        if ($@) {
            warn "POTA JSON parse failed: $@\n";
        } elsif (ref $spots eq 'ARRAY') {
            for my $s (@$spots) {
                next unless ref $s eq 'HASH';

                my $call = clean_field($s->{activator}); next unless length $call;
                next if length($call) > $MAX_CALL;
                my $freq = $s->{frequency} // next;   # kHz
                my $mode = clean_field($s->{mode});
                my $park = clean_field($s->{reference});
                my $time = $s->{spotTime}  // next;

                my ($Y,$m,$d,$H,$M,$S) =
                    $time =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/
                    or next;

                my $epoch = timegm($S,$M,$H,$d,$m-1,$Y);
                next if ($now - $epoch) > $MAX_AGE_S;

                my $hz = int((0 + $freq) * 1000);
                next unless $hz > 0 && $hz <= 1_300_000_000;  # sanity: max ~1.3 GHz

                my $org = org_from_ref($park);

                my ($grid, $lat, $lng) = resolve_location($park);

                # Skip if HamClock would reject it (no location data)
                next unless $grid || ($lat != 0 && $lng != 0);

                my $state = resolve_state($park);

                my $key = join('|', $call, $park, $mode, $hz, $org);

                if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
                    $best{$key} = {
                        call  => $call,
                        hz    => $hz,
                        epoch => $epoch,
                        mode  => $mode,
                        grid  => $grid,
                        lat   => $lat,
                        lng   => $lng,
                        park  => $park,
                        org   => $org,
                        state => $state,
                    };
                    $counts{pota}++;
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Source 2: WWFF — Read from the local cache file populated by
# fetch_wwff_cache.pl.
# Fields: ACTIVATOR, QRG (MHz), MODE, REF, LAT, LON, DATE ("YYYYMMDD"),
#         TIME ("HHMM" UTC)
# Location is embedded in each spot — no cache lookup needed.
#
# NOTE: most genuine WWFF-network spots come through with MODE == "" --
# only the small subset of GMA "self-spot" records happen to carry a mode
# string. We no longer require a mode to be present (POTA/SOTA don't
# either), and QRG is sanitized before numeric use since the upstream API
# has been observed to prefix it with stray junk (e.g. ": 5354.0" or
# "p: 14308.") that would otherwise numify to 0 and get silently dropped.
# ---------------------------------------------------------------------------
{
    my $body = fetch_source($WWFF_URL, $ua, 'WWFF');
    if (defined $body) {
        my $data = eval { decode_json($body) };
        if ($@) {
            warn "WWFF JSON parse failed: $@\n";
        } else {
        my $spots = $data->{RCD} // [];
        for my $s (@$spots) {
            next unless ref $s eq 'HASH';

            my $call = uc(clean_field($s->{ACTIVATOR}));
            next unless length $call;
            next if length($call) > $MAX_CALL;

            my $freq = clean_freq($s->{QRG});   # kHz, sanitized
            my $mode = uc(clean_field($s->{MODE}));
            # NOTE: intentionally NOT requiring a non-empty mode here --
            # see comment above the WWFF block.

            my $park = clean_field($s->{REF}); next unless length $park;
            my $lat  = $s->{LAT}  // next;
            my $lon  = $s->{LON}  // next;
            my $date = $s->{DATE} // next;   # YYYYMMDD
            my $time = $s->{TIME} // next;   # HHMM

            next unless length($freq) && $freq > 0;
            my $hz = int($freq * 1000);      # kHz -> Hz
            next unless $hz > 0 && $hz <= 1_300_000_000;

            next unless $date =~ /^(\d{4})(\d{2})(\d{2})$/ ;
            my ($Y, $m, $d) = ($1, $2, $3);
            next unless $time =~ /^(\d{2})(\d{2})$/;
            my ($H, $M) = ($1, $2);

            my $epoch = eval { timegm(0, $M, $H, $d, $m-1, $Y) } or next;
            next if ($now - $epoch) > $MAX_AGE_S;

            next unless length($lat) && length($lon);
            next unless $lat =~ /^-?\d+\.?\d*$/ && $lon =~ /^-?\d+\.?\d*$/;

            # Compute 4-char Maidenhead grid from embedded coordinates
            use POSIX qw(floor);
            my $grid = do {
                my $alon = $lon + 180.0;
                my $alat = $lat + 90.0;
                my $fl = floor($alon / 20);
                my $fla = floor($alat / 10);
                my $sl = floor(($alon - $fl * 20) / 2);
                my $sla = floor($alat - $fla * 10);
                sprintf('%s%s%d%d',
                    chr(ord('A') + $fl),
                    chr(ord('A') + $fla),
                    $sl, $sla);
            };

            my $key = join('|', $call, $park, $mode, $hz, 'WWFF');

            if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
                $best{$key} = {
                    call  => $call,
                    hz    => $hz,
                    epoch => $epoch,
                    mode  => $mode,
                    grid  => $grid,
                    lat   => $lat,
                    lng   => $lon,
                    park  => $park,
                    org   => 'WWFF',
                    state => resolve_state($park),
                };
                $counts{wwff}++;
            }
        }
        } # end JSON parse else
    }
}

# ---------------------------------------------------------------------------
# Sort newest-first, cap, write output
# ---------------------------------------------------------------------------
my @out = sort { $b->{epoch} <=> $a->{epoch} } values %best;

open my $fh, '>', $TMP or die "Cannot write temp file $TMP: $!\n";
print $fh "#call,Hz,unix,mode,grid,lat,lng,park,org\n";

for my $r (@out) {
    print $fh join(',',
        $r->{call},
        $r->{hz},
        $r->{epoch},
        $r->{mode},
        $r->{grid},
        $r->{lat},
        $r->{lng},
        $r->{park},
        $r->{org},
    ), "\n";
}

close $fh;

# ---------------------------------------------------------------------------
# Shared side file: park reference -> 2-letter state/province/country.
# Merged with gen_xonta.pl's SOTA contribution rather than overwritten --
# see merge_park_states() and the onta_parks.txt NOTE at the top.
# ---------------------------------------------------------------------------
my %park_states;
for my $r (@out) {
    next unless length $r->{state};
    $park_states{$r->{park}} = $r->{state};
}

my %merged = merge_park_states($PARKS_OUT, \%park_states);

open my $pfh, '>', $PARKS_TMP or die "Cannot write temp file $PARKS_TMP: $!\n";
print $pfh "#park,state\n";
for my $park (sort keys %merged) {
    print $pfh join(',', $park, $merged{$park}), "\n";
}
close $pfh;

move $PARKS_TMP, $PARKS_OUT or die "move failed $PARKS_TMP -> $PARKS_OUT: $!\n";

print "--- Processing Complete ---\n";
print "POTA records: $counts{pota}\n";
print "WWFF records: $counts{wwff}\n";
print "WWFF source : $WWFF_URL\n";

move $TMP, $OUT or die "move failed $TMP -> $OUT: $!\n";

print "Total unique spots written to $OUT: " . scalar(@out) . "\n";
print "Total park/state entries written to $PARKS_OUT: " . scalar(keys %merged) . " (this run resolved " . scalar(keys %park_states) . ")\n";
