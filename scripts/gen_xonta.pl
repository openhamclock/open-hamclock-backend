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
#  gen_xonta.pl -- "extra" xOTA spot aggregator (whatever Spothole actually
#  has live beyond POTA/SOTA/WWFF/IOTA)
#
#  Part of the OHB project:
#  https://github.com/openhamclock/open-hamclock-backend/tree/main
#
#  Sibling to gen_iota.pl -- same idea (query Spothole, since these programmes
#  don't have their own dedicated per-programme scripts the way POTA/WWFF
#  do in gen_onta.pl), REWRITTEN after live testing against the public
#  spothole.app API on 2026-08-19 showed the original per-SIG-filtered-request
#  design (one ?sig=X call per programme) was unreliable in two different ways:
#
#  onta_parks.txt NOTE: this side file (SOTA park -> state/country) is
#  shared with gen_onta.pl, which contributes POTA/WWFF entries on its own
#  schedule. Since a park's resolved state never changes, and SOTA
#  references never collide in shape with POTA/WWFF's, this script MERGES
#  its own freshly-resolved entries into whatever's already on disk rather
#  than overwriting the file wholesale -- otherwise, whichever of the two
#  scripts runs last would silently erase the other's contribution. See
#  merge_park_states() below (identical logic to gen_onta.pl's copy).
#
#  Writes xonta_spots.txt using the EXACT SAME line schema as onta.txt and
#  iota_spots.txt (call,Hz,unix,mode,grid,lat,lng,ref,org), so HamClock's
#  existing onta.txt parser can read it completely unmodified. Kept as a
#  separate, purely additive file -- same philosophy as iota_spots.txt --
#  so onta.txt itself and its consumers are undisturbed.
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
# =============================================================================

use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json);
use URI;
use Text::CSV_XS;
use File::Copy qw(move);

# Spothole API v2. See https://spothole.app/apidocs for schema (JS-rendered
# page -- easier in practice to just sample the live API, see header above).
my $SPOTHOLE_BASE = 'https://spothole.app/api/v2/spots';

# ---------------------------------------------------------------------------
# Orgs we actually want out of this one broad fetch.
# ---------------------------------------------------------------------------
my @TARGET_ORGS = qw(GMA LLOTA SOTA TOWERS WWBOTA);

# ---------------------------------------------------------------------------
# Orgs where the primary "does any sig_refs[] entry say sig=X" match is
# known to fail (blank sig field) but the spot data itself is genuinely
# present under a matching top-level "source". 
# ---------------------------------------------------------------------------
my %SOURCE_FALLBACK = (
    GMA => 'GMA',
);

my $OUT = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/xonta_spots.txt';
my $TMP = '/opt/hamclock-backend/htdocs/tmp/xonta_spots.txt.tmp';

# Shared side file with gen_onta.pl -- SOTA park->state entries are merged
# into the SAME onta_parks.txt gen_onta.pl writes for POTA/WWFF, not a
# separate file. See the onta_parks.txt NOTE in the header.
my $PARKS_OUT = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/onta_parks.txt';
my $PARKS_TMP = '/opt/hamclock-backend/htdocs/tmp/onta_parks.txt.tmp';

# ---------------------------------------------------------------------------
# Static SOTA summit reference data -- see the big SOTA comment in the
# header for why this exists and why it's preferred over Spothole's own
# per-spot location fields. Same file gen_onta.pl's SOTA block used to
# read, same generator script, just relocated here.
# ---------------------------------------------------------------------------
my $SOTA_CSV = '/opt/hamclock-backend/cache/sota_summits.csv';
my $SOTA_CSV_GENERATOR = '/opt/hamclock-backend/scripts/update_sota_cache.pl';

# ---------------------------------------------------------------------------
# Load a reference lookup CSV into a hash keyed by reference string.
# Required columns: reference, latitude, longitude, grid. Ported verbatim
# from gen_onta.pl's load_lookup(). sota_summits.csv now carries a
# "region" column (RegionName, via update_sota_cache.pl) that's used by
# resolve_sota_state() below.
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

    # Optional 'active' column -- see gen_onta.pl's identical comment.
    # sota_summits.csv doesn't have one today, so this is a no-op here,
    # kept only so both copies of load_lookup() stay in sync.
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

unless (-e $SOTA_CSV) {
    print "Missing $SOTA_CSV. Running $SOTA_CSV_GENERATOR...\n";
    system("perl $SOTA_CSV_GENERATOR");
    if ($? != 0 || !-e $SOTA_CSV) {
        print "Error: Failed to generate $SOTA_CSV using $SOTA_CSV_GENERATOR (Exit code: $?). Continuing.\n";
    }
}
my %sota_lookup = load_lookup($SOTA_CSV);

# ---------------------------------------------------------------------------
# Look up a SOTA summit's authoritative fixed position. Returns
# ('', undef, undef) if the summit isn't in the cached list -- caller
# falls back to Spothole's own per-spot location fields in that case.
# ---------------------------------------------------------------------------
sub resolve_sota_location {
    my ($ref) = @_;
    return ('', undef, undef) unless $ref && exists $sota_lookup{$ref};
    my $e = $sota_lookup{$ref};
    my $lat = $e->{lat};
    my $lng = $e->{lng};
    return (
        $e->{grid} // '',
        (defined($lat) && length($lat) ? $lat + 0 : undef),
        (defined($lng) && length($lng) ? $lng + 0 : undef),
    );
}

# ---------------------------------------------------------------------------
# Static LLOTA (Lagos y Lagunas On The Air) reference data, same pattern
# as the SOTA block above -- authoritative fixed lake/lagoon coordinates,
# preferred over Spothole's own per-spot location fields (LLOTA's own
# live spot feed carries none at all, per llota.py -- Spothole appears to
# backfill grid/lat/lon into spots itself from this same reference data,
# but we don't rely on that; we fetch and cache it directly).
#
# Unlike sota_summits.csv, this needs TWO extra fields (country_code AND
# region, not just one), so it gets its own small loader rather than
# reusing the generic load_lookup() above, which only carries a single
# optional location column. See update_llota_cache.pl for where
# country_code/region actually come from (present in every real record,
# but discarded by Spothole's own sig-ref-data provider for this
# programme) and resolve_llota_state() below for how they're used.
# ---------------------------------------------------------------------------
my $LLOTA_CSV = '/opt/hamclock-backend/cache/llota_references.csv';
my $LLOTA_CSV_GENERATOR = '/opt/hamclock-backend/scripts/update_llota_cache.pl';

sub load_llota_lookup {
    my ($path) = @_;
    my %refs;

    return %refs unless -f $path;

    open my $fh, '<:encoding(UTF-8)', $path or do {
        warn "Cannot read $path: $!\n";
        return %refs;
    };

    my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });
    my $header = $csv->getline($fh);
    unless ($header && @$header) {
        warn "Empty or unreadable header in $path\n";
        close $fh;
        return %refs;
    }

    my %idx;
    for my $i (0 .. $#$header) {
        my $k = $header->[$i] // next;
        $k =~ s/^"|"$//g;
        $idx{$k} = $i;
    }

    for my $need (qw(reference latitude longitude grid country_code region)) {
        unless (exists $idx{$need}) {
            warn "Missing '$need' column in $path\n";
            close $fh;
            return %refs;
        }
    }

    while (my $row = $csv->getline($fh)) {
        my $ref = $row->[$idx{reference}] // next;
        $ref =~ s/^"|"$//g;

        $refs{$ref} = {
            lat          => ($row->[$idx{latitude}]     // ''),
            lng          => ($row->[$idx{longitude}]    // ''),
            grid         => ($row->[$idx{grid}]         // ''),
            country_code => ($row->[$idx{country_code}] // ''),
            region       => ($row->[$idx{region}]       // ''),
        };
    }

    close $fh;
    return %refs;
}

unless (-e $LLOTA_CSV) {
    print "Missing $LLOTA_CSV. Running $LLOTA_CSV_GENERATOR...\n";
    system("perl $LLOTA_CSV_GENERATOR");
    if ($? != 0 || !-e $LLOTA_CSV) {
        print "Error: Failed to generate $LLOTA_CSV using $LLOTA_CSV_GENERATOR (Exit code: $?). Continuing.\n";
    }
}
my %llota_lookup = load_llota_lookup($LLOTA_CSV);

# ---------------------------------------------------------------------------
# Look up an LLOTA reference's authoritative fixed position. Returns
# ('', undef, undef) if the reference isn't in the cached list -- caller
# falls back to Spothole's own per-spot location fields in that case.
# ---------------------------------------------------------------------------
sub resolve_llota_location {
    my ($ref) = @_;
    return ('', undef, undef) unless $ref && exists $llota_lookup{$ref};
    my $e = $llota_lookup{$ref};
    my $lat = $e->{lat};
    my $lng = $e->{lng};
    return (
        $e->{grid} // '',
        (defined($lat) && length($lat) ? $lat + 0 : undef),
        (defined($lng) && length($lng) ? $lng + 0 : undef),
    );
}

# ---------------------------------------------------------------------------
# US state/territory and Canadian province full name -> 2-letter code,
# for LLOTA's "region" field. This is the SAME table as
# %STATE_NAME_TO_CODE used by resolve_sota_state() below -- defined here
# because LLOTA's setup comes first in the file; resolve_sota_state()
# references this same table by name once it's defined further down.
# ---------------------------------------------------------------------------
my %STATE_NAME_TO_CODE = (
    'alabama' => 'AL', 'alaska' => 'AK', 'arizona' => 'AZ', 'arkansas' => 'AR',
    'california' => 'CA', 'colorado' => 'CO', 'connecticut' => 'CT', 'delaware' => 'DE',
    'florida' => 'FL', 'georgia' => 'GA', 'hawaii' => 'HI', 'idaho' => 'ID',
    'illinois' => 'IL', 'indiana' => 'IN', 'iowa' => 'IA', 'kansas' => 'KS',
    'kentucky' => 'KY', 'louisiana' => 'LA', 'maine' => 'ME', 'maryland' => 'MD',
    'massachusetts' => 'MA', 'michigan' => 'MI', 'minnesota' => 'MN', 'mississippi' => 'MS',
    'missouri' => 'MO', 'montana' => 'MT', 'nebraska' => 'NE', 'nevada' => 'NV',
    'new hampshire' => 'NH', 'new jersey' => 'NJ', 'new mexico' => 'NM', 'new york' => 'NY',
    'north carolina' => 'NC', 'north dakota' => 'ND', 'ohio' => 'OH', 'oklahoma' => 'OK',
    'oregon' => 'OR', 'pennsylvania' => 'PA', 'rhode island' => 'RI', 'south carolina' => 'SC',
    'south dakota' => 'SD', 'tennessee' => 'TN', 'texas' => 'TX', 'utah' => 'UT',
    'vermont' => 'VT', 'virginia' => 'VA', 'washington' => 'WA', 'west virginia' => 'WV',
    'wisconsin' => 'WI', 'wyoming' => 'WY', 'district of columbia' => 'DC', 'puerto rico' => 'PR',
    # Canadian provinces/territories
    'alberta' => 'AB', 'british columbia' => 'BC', 'manitoba' => 'MB',
    'new brunswick' => 'NB', 'newfoundland and labrador' => 'NL', 'nova scotia' => 'NS',
    'ontario' => 'ON', 'prince edward island' => 'PE', 'quebec' => 'QC',
    'saskatchewan' => 'SK', 'northwest territories' => 'NT', 'nunavut' => 'NU',
    'yukon' => 'YT', 'yukon territory' => 'YT',
);

# ---------------------------------------------------------------------------
# Resolve a 2-letter state/province/country code for an LLOTA reference.
# country_code is already a real ISO code straight from LLOTA's own
# database -- occasionally with an ISO-3166-2-style subdivision suffix
# ("GB-SCT", "ES-CN"), only trusted when that suffix is exactly 2 letters
# (3-letter ones like "SCT"/"WLS"/"NIR" fall back to the base country
# instead of being used as-is or truncated, per this project's
# established rule against guessing at subdivision codes). For US/Canada
# specifically, "region" is checked for a real state/province -- either
# an already-2-letter value or a recognized full name -- since LLOTA's
# community-submitted data for those two countries loosely follows the
# same abbreviation convention POTA/WWFF use (loosely: mixed case, stray
# whitespace, and multi-value fields for lakes spanning more than one
# state, separated by either a comma or, rarely, a slash -- all handled
# below). Every other country's "region" is free-text description with
# no standard short code (Polish voivodeships, Spanish autonomous
# communities, English counties...) and isn't used for anything beyond
# the country level. Validated against all 8,482 real references in the
# live database on 2026-09: 100% resolve to at least a country, and all
# 1,101 real US/Canada entries resolve to a real state/province.
# ---------------------------------------------------------------------------
sub resolve_llota_state {
    my ($ref) = @_;
    return '' unless $ref && exists $llota_lookup{$ref};

    my $cc = $llota_lookup{$ref}{country_code} // '';
    return '' unless length $cc;

    my $base = $cc;
    if ($cc =~ /^([A-Za-z]+)-([A-Za-z0-9]+)$/) {
        my ($b, $sub) = (uc($1), $2);
        return uc($sub) if $sub =~ /^[A-Za-z]{2}$/;
        $base = $b;
    } else {
        $base = uc $cc;
    }

    if ($base eq 'US' || $base eq 'CA') {
        my $region = $llota_lookup{$ref}{region} // '';
        if (length $region) {
            my @parts = map { s/^\s+|\s+$//gr } split /[,\/]/, $region;
            for my $p (@parts) {
                return uc($p) if $p =~ /^[A-Za-z]{2}$/;
            }
            for my $p (@parts) {
                my $code = $STATE_NAME_TO_CODE{lc($p)};
                return $code if defined $code;
            }
        }
    }

    return $base;
}

# ---------------------------------------------------------------------------
# Ham callsign/association prefix -> ISO 3166-1 alpha-2 country code.
# Same table as gen_onta.pl's copy (kept duplicated rather than shared,
# since these are standalone cron scripts with no common module) -- see
# that script's comment for the full rationale and caveats. Extend as
# unmapped SOTA association prefixes show up (see the warning below).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Ham callsign/association prefix -> ISO 3166-1 alpha-2 country/territory
# code. Built from the FULL, REAL list of 227 unique SOTA association
# prefixes
# This matters because SOTA's
# own association codes frequently diverge from both ITU callsign
# prefixes and ISO country codes in ways that are easy to get wrong:
#   - Germany has TWO associations, "DL" (Alps) and "DM" (Central
#     Mountains) -- both -> DE. A prefix table built from ham-prefix
#     knowledge alone (DL is the well-known German ham prefix) misses DM
#     entirely, which is exactly the bug that prompted this rebuild.
#   - Switzerland's association is "HB", NOT "HB9" (the ham prefix).
#   - "HR" as a SOTA prefix is Honduras, NOT Croatia (Croatia's ISO code
#     is coincidentally "HR", used as this table's VALUE for prefix "9A"
#     -- a genuine, confusing collision between two different
#     namespaces that's easy to get backwards).
#   - The UK's Crown Dependencies each have their own ISO code, not GB:
#     Isle of Man ("GD") -> IM, Jersey ("GJ") -> JE, Guernsey ("GU") -> GG.
#   - French overseas territories each have their own ISO code, not FR:
#     Guadeloupe, Martinique, Reunion, Mayotte, French Polynesia, New
#     Caledonia, Wallis & Futuna, St Barthelemy, St Martin, St Pierre &
#     Miquelon (FG/FM/FR/FH/PYF/FK/FW/FJ/FS/FP respectively).
# the warning below will flag any prefix this table doesn't cover.
# ---------------------------------------------------------------------------
my %PREFIX_COUNTRY = (
    '3B8' => 'MU',
    '3DA' => 'SZ',
    '3Y' => 'BV',
    '4O' => 'ME',
    '4X' => 'IL',
    '4Z' => 'IL',
    '5B' => 'CY',
    '7P' => 'LS',
    '8P' => 'BB',
    '9A' => 'HR',
    '9H' => 'MT',
    '9M' => 'MY',
    '9V' => 'SG',
    'A6' => 'AE',
    'AL' => 'US',
    'BV' => 'TW',
    'C3' => 'AD',
    'C4' => 'CY',
    'CE' => 'CL',
    'CT' => 'PT',
    'CT3' => 'PT',
    'CU' => 'PT',
    'CX' => 'UY',
    'D4' => 'CV',
    'DL' => 'DE',
    'DM' => 'DE',
    'DU' => 'PH',
    'E5' => 'CK',
    'E7' => 'BA',
    'EA' => 'ES',
    'EI' => 'IE',
    'ER' => 'MD',
    'ES' => 'EE',
    'F' => 'FR',
    'FG' => 'GP',
    'FH' => 'YT',
    'FJ' => 'BL',
    'FK' => 'NC',
    'FM' => 'MQ',
    'FP' => 'PM',
    'FR' => 'RE',
    'FS' => 'MF',
    'FW' => 'WF',
    'G' => 'GB',
    'GD' => 'IM',
    'GI' => 'GB',
    'GJ' => 'JE',
    'GM' => 'GB',
    'GU' => 'GG',
    'GW' => 'GB',
    'HA' => 'HU',
    'HB' => 'CH',
    'HB0' => 'LI',
    'HI' => 'DO',
    'HL' => 'KR',
    'HR' => 'HN',
    'I' => 'IT',
    'IA' => 'IT',
    'IS0' => 'IT',
    'J8' => 'VC',
    'JA' => 'JP',
    'JW' => 'SJ',
    'JX' => 'SJ',
    'K' => 'US',
    'KH0' => 'MP',
    'KH2' => 'GU',
    'KH6' => 'US',
    'KH8' => 'AS',
    'KP4' => 'PR',
    'LA' => 'NO',
    'LU' => 'AR',
    'LX' => 'LU',
    'LY' => 'LT',
    'LZ' => 'BG',
    'N' => 'US',
    'OD' => 'LB',
    'OE' => 'AT',
    'OH' => 'FI',
    'OK' => 'CZ',
    'OM' => 'SK',
    'ON' => 'BE',
    'OY' => 'FO',
    'OZ' => 'DK',
    'P3' => 'CY',
    'P4' => 'AW',
    'PA' => 'NL',
    'PJ2' => 'CW',
    'PJ4' => 'BQ',
    'PJ5' => 'BQ',
    'PJ6' => 'BQ',
    'PJ7' => 'SX',
    'PP' => 'BR',
    'PQ' => 'BR',
    'PR8' => 'BR',
    'PS' => 'BR',
    'PT' => 'BR',
    'PY' => 'BR',
    'PYF' => 'PF',
    'PYT' => 'BR',
    'R3' => 'RU',
    'R9U' => 'RU',
    'S5' => 'SI',
    'S7' => 'SC',
    'SM' => 'SE',
    'SP' => 'PL',
    'SV' => 'GR',
    'TF' => 'IS',
    'TI' => 'CR',
    'TK' => 'FR',
    'UR' => 'UA',
    'UT' => 'UA',
    'V5' => 'NA',
    'VA' => 'CA',
    'VE' => 'CA',
    'VK' => 'AU',
    'VO' => 'CA',
    'VP0' => 'GS',
    'VP8' => 'FK',
    'VR' => 'HK',
    'VU' => 'IN',
    'VY' => 'CA',
    'W' => 'US',
    'XE' => 'MX',
    'XF4' => 'MX',
    'YB' => 'ID',
    'YL' => 'LV',
    'YO' => 'RO',
    'YU' => 'RS',
    'Z3' => 'MK',
    'ZA' => 'AL',
    'ZB2' => 'GI',
    'ZD' => 'SH',
    'ZL' => 'NZ',
    'ZS' => 'ZA',
);

my %warned_prefix;

sub _longest_prefix_match {
    my ($prefix, $table) = @_;
    return undef unless length $prefix;
    $prefix = uc $prefix;
    for my $len (reverse 1 .. length $prefix) {
        my $try = substr($prefix, 0, $len);
        return $table->{$try} if exists $table->{$try};
    }
    return undef;
}

sub prefix_country {
    my ($prefix) = @_;
    return '' unless length $prefix;
    $prefix = uc $prefix;
    my $c = _longest_prefix_match($prefix, \%PREFIX_COUNTRY);
    return $c if defined $c;
    unless ($warned_prefix{$prefix}) {
        warn "resolve_sota_state: no country mapping for prefix '$prefix' -- add it to \%PREFIX_COUNTRY\n";
        $warned_prefix{$prefix} = 1;
    }
    return '';
}

# ---------------------------------------------------------------------------
# US state/territory and Canadian province FULL NAME -> 2-letter code.
# Needed because SOTA's RegionName isn't consistently abbreviated: for# single-state associations (e.g. W7O = Oregon) it tends to already be a
# 2-letter code, but multi-state associations (e.g. W1 covers all of New
# England under one association) publish each summit's own region as a
# full descriptive name instead (e.g. "Connecticut", not "CT"). Matched
# case-insensitively after trimming, since RegionName's exact casing/
# whitespace isn't guaranteed. Uses the shared %STATE_NAME_TO_CODE table
# defined earlier (LLOTA's setup needed it first in file order, but it's
# the exact same US-state/Canada-province table either way -- see the
# comment there).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Resolve a 2-letter state/province/country code for a SOTA reference
# ("S5/RG-053", "W7O/CG-041"). Country comes from the association prefix
# (before the "/"), translated via %PREFIX_COUNTRY. sota_summits.csv's
# "region" column (RegionName) has no country prefix baked in at all, and
# its format varies per summit rather than per association -- observed
# forms in real data include:
#   - an already-2-letter code ("OR")
#   - "XX-Description" or "XX - Description" ("CO-Front Range",
#     "ID - Boise County", "NC-Central Mountains") -- the leading code
#     is real, the rest is just descriptive text
#   - a full state/province name with no code at all ("Connecticut",
#     "North Dakota") -- common for associations that span multiple
#     states (e.g. W1 covers all of New England as one association)
#   - a full descriptive foreign region name with no code to extract at
#     all ("Gorenjska", "Bayern (Mittelgebirge)") -- these fall back to
#     the country instead of being truncated into something wrong.
# All three US/Canada forms are tried in order; anything else falls back
# to the resolved country.
# ---------------------------------------------------------------------------
sub resolve_sota_state {
    my ($ref) = @_;
    return '' unless $ref;

    my ($assoc_prefix) = ($ref =~ m{^([A-Za-z0-9]+)/});
    my $country = (defined($assoc_prefix) && length($assoc_prefix))
        ? prefix_country($assoc_prefix) : '';

    my $region = (exists $sota_lookup{$ref}) ? ($sota_lookup{$ref}{loc} // '') : '';
    $region =~ s/^\s+|\s+$//g if length $region;

    if (length($region) && ($country eq 'US' || $country eq 'CA')) {
        return uc($region) if length($region) == 2;

        if ($region =~ /^([A-Za-z]{2})\s*-\s*\S/) {
            return uc($1);
        }

        my $code = $STATE_NAME_TO_CODE{lc($region)};
        return $code if defined $code;

        # Full name embedded in more descriptive text ("Connecticut
        # River", "East Wyoming") -- match on state/province name as a
        # whole word anywhere in the string. Restricted to MULTI-WORD
        # names only ("New Hampshire", "West Virginia", "Rhode
        # Island"...) -- single-word names are deliberately excluded
        # here because they're too likely to appear as part of an
        # unrelated place name and produce a confident-looking wrong
        # answer: "Mount Washington" is a well-known SOTA summit in New
        # Hampshire, not Washington state; the Ohio River borders WV/
        # KY/IN as much as it does Ohio. A single-word name is only
        # trusted as an exact whole-string match (the check above this
        # one), never as a substring.
        for my $name (sort { length($b) <=> length($a) }
                       grep { /\s/ } keys %STATE_NAME_TO_CODE) {
            if ($region =~ /\b\Q$name\E\b/i) {
                return $STATE_NAME_TO_CODE{$name};
            }
        }
    }

    return $country if length $country;
    return '';
}

# ---------------------------------------------------------------------------
# Reference prefix -> ISO 3166-1 alpha-2 country code, for the "Towers"
# programme (a.k.a. TOTA / WWTOTA -- naming is inconsistent between
# Spothole's own source list and the programme's own site, but the
# reference format confirms this is the right one: "OER-1003" matches
# Austria's listed prefix "OER" exactly). 
# ---------------------------------------------------------------------------
my %TOWERS_PREFIX_COUNTRY = (
    'OKR' => 'CZ',   # Czech Republic
    'OMR' => 'SK',   # Slovakia
    'DLR' => 'DE',   # Germany
    'OER' => 'AT',   # Austria
    'SPR' => 'PL',   # Poland
    'KPR' => 'PR',   # Puerto Rico
    'PAR' => 'NL',   # Netherlands
    'LUR' => 'AR',   # Argentina
    'HIR' => 'DO',   # Dominican Republic
    'EAR' => 'ES',   # Spain
    'CER' => 'CL',   # Chile
    'CTR' => 'PT',   # Portugal
    'LZR' => 'BG',   # Bulgaria
    'ONR' => 'BE',   # Belgium
    'GBR' => 'GB',   # United Kingdom
    'CUR' => 'PT',   # Azores (Portugal)
    '9MR' => 'MY',   # Malaysia
);

my %warned_towers_prefix;

# ---------------------------------------------------------------------------
# Resolve a 2-letter country code for a Towers/TOTA reference ("OER-1003").
# Unlike SOTA/WWFF/POTA, this programme has no sub-national subdivision
# in its reference or elsewhere Spothole exposes -- country is the best
# available granularity, so that's all this resolves to.
# ---------------------------------------------------------------------------
sub resolve_towers_state {
    my ($ref) = @_;
    return '' unless $ref;

    my ($prefix) = ($ref =~ /^([A-Za-z0-9]+)-/);
    return '' unless defined $prefix;
    $prefix = uc $prefix;

    return $TOWERS_PREFIX_COUNTRY{$prefix} if exists $TOWERS_PREFIX_COUNTRY{$prefix};

    unless ($warned_towers_prefix{$prefix}) {
        warn "resolve_towers_state: no country mapping for prefix '$prefix' -- add it to \%TOWERS_PREFIX_COUNTRY\n";
        $warned_towers_prefix{$prefix} = 1;
    }
    return '';
}

# ---------------------------------------------------------------------------
# Reference prefix -> ISO 3166-1 alpha-2 country code, for WWBOTA (World
# Wide Bunkers On The Air). References are SOTA-shaped ("B/9A-0001" --
# "B/" + ham prefix + "-" + number), so the country lives in the
# association-style prefix, same pattern as SOTA. Extracted and
# validated against all 31,425 real references in the official bunker
# database (https://api.wwbota.org/bunkers/?format=CSV, 2026-09),
# cross-checked against each reference's DXCC entity number in that
# same file -- not a hand-typed guess. 34 prefixes, 100% coverage.
# ---------------------------------------------------------------------------
my %WWBOTA_PREFIX_COUNTRY = (
    '9A' => 'HR', '9M' => 'MY', 'CA' => 'CA', 'CX' => 'UY', 'DL' => 'DE',
    'E7' => 'BA', 'EA' => 'ES', 'EI' => 'IE', 'ER' => 'MD', 'F' => 'FR',
    'G' => 'GB', 'GD' => 'IM', 'GI' => 'GB', 'GJ' => 'JE', 'GM' => 'GB',
    'GU' => 'GG', 'GW' => 'GB', 'HB' => 'CH', 'IT' => 'IT', 'LA' => 'NO',
    'LX' => 'LU', 'OE' => 'AT', 'OK' => 'CZ', 'ON' => 'BE', 'PA' => 'NL',
    'S5' => 'SI', 'SM' => 'SE', 'SP' => 'PL', 'US' => 'US', 'V6' => 'FM',
    'YO' => 'RO', 'YU' => 'RS', 'Z3' => 'MK', 'ZA' => 'AL',
);

my %warned_wwbota_prefix;

# ---------------------------------------------------------------------------
# Resolve a 2-letter country code for a WWBOTA reference ("B/9A-0001").
# Like Towers, no sub-national subdivision is available -- country only.
# ---------------------------------------------------------------------------
sub resolve_wwbota_state {
    my ($ref) = @_;
    return '' unless $ref;

    my ($prefix) = ($ref =~ m{^B/([A-Za-z0-9]+)-});
    return '' unless defined $prefix;
    $prefix = uc $prefix;

    return $WWBOTA_PREFIX_COUNTRY{$prefix} if exists $WWBOTA_PREFIX_COUNTRY{$prefix};

    unless ($warned_wwbota_prefix{$prefix}) {
        warn "resolve_wwbota_state: no country mapping for prefix '$prefix' -- add it to \%WWBOTA_PREFIX_COUNTRY\n";
        $warned_wwbota_prefix{$prefix} = 1;
    }
    return '';
}

# ---------------------------------------------------------------------------
# Reference prefix -> ISO 3166-1 alpha-2 country code, for GMA (Global
# Mountain Activity). GMA references are SOTA-shaped ("4L/SZ-001"), and
# mostly reuse SOTA's own association prefixes directly -- BUT GMA also
# has its own much larger, independent hill/mountain lists for several
# countries under GMA-specific prefixes with no SOTA equivalent (e.g.
# "DA" for Germany, 7,127 summits -- far more than SOTA's DL+DM combined
# -- and "OL" for the Czech Republic, 6,356 summits), PLUS a parallel "X"
# + <prefix> scheme (e.g. "XEA1", "XW7O", "XVK6") that mirrors an
# existing SOTA-style prefix under a separate numbering, apparently to
# avoid colliding with SOTA's own reference numbers for the same summit.
# resolve_gma_state() below tries a reference's prefix as-is first
# (checking both this table and the SOTA one above), then with a leading
# "X" stripped if that didn't match. This table holds only the
# GMA-specific prefixes with NO SOTA equivalent -- resolve_gma_state()
# falls through to the shared SOTA %PREFIX_COUNTRY table first for
# everything else. Each entry here was identified from real coordinates
# in the official GMA summit database
# (https://www.gma.rocks/download/summits.csv, 2026-09), not guessed
# from the prefix alone -- validated against all 31,939 real prefixed
# references in that file: 100% resolve.
# ---------------------------------------------------------------------------
my %GMA_ONLY_PREFIX_COUNTRY = (
    'DA'  => 'DE',   # Germany (GMA's own large hill list)
    'DB'  => 'DE',   # Germany
    'OL'  => 'CZ',   # Czech Republic (GMA's own large hill list)
    'SO'  => 'PL',   # Poland
    'EC'  => 'ES',   # Spain
    'EC6' => 'ES',   # Spain
    'EC8' => 'ES',   # Spain
    'HG'  => 'HU',   # Hungary
    'US'  => 'UA',   # Ukraine (Carpathians, Lviv oblast)
    'R2'  => 'RU',   # Russia (Kaliningrad Oblast)
    'R4'  => 'RU',   # Russia (Perm/Urals)
    'R5'  => 'RU',   # Russia (Crimea)
    'R6'  => 'RU',   # Russia (Krasnodar Krai)
    'ZT'  => 'ZA',   # South Africa
    'MW'  => 'GB',   # Wales
    'HK'  => 'CO',   # Colombia
    'M'   => 'GB',   # England
    'YP'  => 'RO',   # Romania
    'LB'  => 'NO',   # Norway
    'OP'  => 'BE',   # Belgium
    'PB'  => 'NL',   # Netherlands
    'PJM' => 'BQ',   # Bonaire (Dutch Caribbean)
    'SX'  => 'GR',   # Greece (Rhodes)
    'TC'  => 'TR',   # Turkey
    'ZM1' => 'NZ',   # New Zealand
    'ZM3' => 'NZ',   # New Zealand
    '6K'  => 'KR',   # South Korea
    'AX'  => 'AU',   # Australia
    'CQ'  => 'PT',   # Portugal
    'CS'  => 'PT',   # Portugal
    'MM'  => 'GB',   # Scotland
    'OF0' => 'AX',   # Aland Islands, Finland
    'OV'  => 'DK',   # Denmark
    'SA'  => 'SE',   # Sweden
    'YT'  => 'RS',   # Serbia
    '4L'  => 'GE',   # Georgia (Caucasus)
);

my %warned_gma_prefix;

sub resolve_gma_state {
    my ($ref) = @_;
    return '' unless $ref;

    my ($prefix) = ($ref =~ m{^([A-Za-z0-9]+)/});
    return '' unless defined $prefix;
    $prefix = uc $prefix;

    for my $try ($prefix, ($prefix =~ /^X(.+)$/ ? ($1) : ())) {
        my $c = _longest_prefix_match($try, \%PREFIX_COUNTRY);
        return $c if defined $c;
        $c = _longest_prefix_match($try, \%GMA_ONLY_PREFIX_COUNTRY);
        return $c if defined $c;
    }

    unless ($warned_gma_prefix{$prefix}) {
        warn "resolve_gma_state: no country mapping for prefix '$prefix' -- add it to \%GMA_ONLY_PREFIX_COUNTRY\n";
        $warned_gma_prefix{$prefix} = 1;
    }
    return '';
}

# ---------------------------------------------------------------------------
# Merge this run's freshly-resolved SOTA park->state entries into
# whatever's already on disk at $path (gen_onta.pl's own POTA/WWFF
# entries, most likely). Identical logic to gen_onta.pl's copy of this
# sub -- see that script's comment for the full rationale.
# ---------------------------------------------------------------------------
sub merge_park_states {
    my ($path, $new) = @_;
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

# HamClock rejects callsigns longer than 12 characters -- same bound gen_onta.pl/gen_iota.pl use
my $MAX_CALL = 12;

# Same reasoning as gen_onta.pl's MAX_AGE_S: HamClock's ONTA age selector maxes
# out at 60 min (10/20/40/60), so anything older is discarded client-side anyway.
# Bound the feed at 65 min so that selector stays the real filter, with ~5 min
# margin to cover this script's own run interval.
my $MAX_AGE_S = 3900;

# ---------------------------------------------------------------------------
# Sanitize a string field before it enters the output line. Same rules as
# gen_onta.pl's / gen_iota.pl's clean_field(): strip control chars, collapse
# whitespace, remove commas (they'd break the CSV-style output), trim edges.
# ---------------------------------------------------------------------------
sub clean_field {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/[\x00-\x1F\x7F]+/ /g;
    $v =~ s/,+/ /g;
    $v =~ s/\s+/ /g;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

my $ua = LWP::UserAgent->new(
    timeout => 20,
    agent   => 'OHB/1.1 (+https://github.com/openhamclock/open-hamclock-backend)',
);

my $now = time();
my %best;           # dedup key -> row hashref, same pattern as gen_iota.pl's %best
my %counts;          # org -> count, for the summary print at the end
my %sig_hits;        # org -> count matched via sig_refs (the "good" path)
my %fallback_hits;   # org -> count matched via source fallback (the "iffy" path)
my ($sota_csv_hits, $sota_spot_hits) = (0, 0);   # SOTA location source breakdown

# ---------------------------------------------------------------------------
# One broad request: no ?sig= filter at all, since that's the exact thing
# that silently drops GMA (and possibly others -- see header). We filter
# and classify locally instead.
# ---------------------------------------------------------------------------
my $uri = URI->new($SPOTHOLE_BASE);
$uri->query_form(
    needs_sig_ref       => 'true',    # still require SOME resolved sig_ref -- we just don't
                                       # trust its "sig" label alone anymore for every org
    needs_good_location => 'true',    # skip anything Spothole itself flags as poorly located
    allow_qrt           => 'false',  # drop spots already known to be QRT
    max_age             => $MAX_AGE_S,
    limit               => 2000,   # generous safety cap, not expected to be hit
);

my $resp = $ua->get($uri);
if (!$resp->is_success) {
    warn "xONTA fetch failed: " . $resp->status_line . "\n";
    exit 1;
}

my $spots = eval { decode_json($resp->decoded_content) };
if ($@) {
    warn "xONTA JSON parse failed: $@\n";
    exit 1;
}
unless (ref $spots eq 'ARRAY') {
    warn "xONTA response was not a JSON array\n";
    exit 1;
}

my %is_target = map { uc($_) => 1 } @TARGET_ORGS;

for my $s (@$spots) {
    next unless ref $s eq 'HASH';
    next if $s->{qrt};   # belt and suspenders, in case allow_qrt=false is ever loosened

    my $refs = $s->{sig_refs} // [];
    next unless ref $refs eq 'ARRAY' && @$refs;

    # Primary path: does any sig_refs[] entry carry a non-empty sig matching
    # one of our target orgs? If so that's an unambiguous, well-tagged match.
    my ($org, $sig_ref, $via_fallback);
    for my $r (@$refs) {
        next unless ref $r eq 'HASH';
        my $rsig = uc(clean_field($r->{sig}));
        if (length($rsig) && $is_target{$rsig}) {
            $org = $rsig;
            $sig_ref = $r;
            last;
        }
    }

    # Fallback path: no sig_refs[] entry had a usable sig, but this org is
    # explicitly configured to trust top-level "source" instead (see the
    # GMA caveat in the header -- this is a deliberately narrow allowance,
    # not a general substitute for proper sig tagging).
    if (!$org) {
        my $source = uc(clean_field($s->{source}));
        if (length($source) && exists $SOURCE_FALLBACK{$source} && @$refs == 1
            && ref $refs->[0] eq 'HASH') {
            $org = $SOURCE_FALLBACK{$source};
            $sig_ref = $refs->[0];
            $via_fallback = 1;
        }
    }

    next unless $org;

    my $call = clean_field($s->{dx_call});
    next unless length $call;
    next if length($call) > $MAX_CALL;

    my $freq = $s->{freq};   # already in Hz per Spothole's Spot schema
    next unless defined $freq && $freq > 0 && $freq <= 1_300_000_000;
    my $hz = int($freq);

    my $mode = clean_field($s->{mode});

    my $time = $s->{time};   # unix epoch seconds
    next unless defined $time;
    my $epoch = int($time);
    next if ($now - $epoch) > $MAX_AGE_S;

    my $ref = clean_field($sig_ref->{id});
    next unless length $ref;

    # For SOTA and LLOTA, the fixed reference position from our own cached
    # CSV is treated as authoritative and preferred over Spothole's own
    # per-spot location fields -- see the big SOTA comment in the header
    # for why (LLOTA is the same story: its live spot feed carries no
    # location at all, per llota.py). Falls back to Spothole's own
    # dx_grid/dx_latitude/dx_longitude (or the sig_ref's own location) if
    # the reference isn't in the cached list yet.
    my ($grid, $lat, $lng);
    if ($org eq 'SOTA') {
        my ($csv_grid, $csv_lat, $csv_lng) = resolve_sota_location($ref);
        if (length($csv_grid) || (defined($csv_lat) && defined($csv_lng))) {
            ($grid, $lat, $lng) = ($csv_grid, $csv_lat, $csv_lng);
            $sota_csv_hits++;
        }
    } elsif ($org eq 'LLOTA') {
        my ($csv_grid, $csv_lat, $csv_lng) = resolve_llota_location($ref);
        if (length($csv_grid) || (defined($csv_lat) && defined($csv_lng))) {
            ($grid, $lat, $lng) = ($csv_grid, $csv_lat, $csv_lng);
        }
    }
    if (!defined $grid) {
        # prefer the spot's own resolved dx_grid/lat/lng (what a map pane should use),
        # falling back to the sig_ref's own location if those are somehow blank
        $grid = clean_field($s->{dx_grid} // $sig_ref->{grid} // '');
        $lat  = $s->{dx_latitude}  // $sig_ref->{latitude};
        $lng  = $s->{dx_longitude} // $sig_ref->{longitude};
        $sota_spot_hits++ if $org eq 'SOTA';
    }

    # HamClock's onta.txt reader requires a grid OR a non-zero lat/lng pair
    next unless length($grid) || (defined($lat) && defined($lng) && ($lat != 0 || $lng != 0));
    $lat //= 0;
    $lng //= 0;

    my $key = join('|', $call, $ref, $mode, $hz, $org);

    if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
        $best{$key} = {
            call  => $call,
            hz    => $hz,
            epoch => $epoch,
            mode  => $mode,
            grid  => $grid,
            lat   => $lat,
            lng   => $lng,
            ref   => $ref,
            org   => $org,
            # SOTA, LLOTA, Towers/TOTA, WWBOTA, and GMA each have a
            # reference database or programme table to resolve a country
            # from (SOTA and LLOTA also get a real US/Canada state) --
            # see the header's STATE/COUNTRY RESOLUTION note.
            state => (
                $org eq 'SOTA'   ? resolve_sota_state($ref)   :
                $org eq 'LLOTA'  ? resolve_llota_state($ref)  :
                $org eq 'TOWERS' ? resolve_towers_state($ref) :
                $org eq 'WWBOTA' ? resolve_wwbota_state($ref) :
                $org eq 'GMA'    ? resolve_gma_state($ref)    :
                ''
            ),
        };
        $counts{$org}++;
        $via_fallback ? $fallback_hits{$org}++ : $sig_hits{$org}++;
    }
}

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
        $r->{ref},
        $r->{org},
    ), "\n";
}

close $fh;
move $TMP, $OUT or die "move failed $TMP -> $OUT: $!\n";

# ---------------------------------------------------------------------------
# Shared side file: SOTA park reference -> 2-letter state/province/country.
# ---------------------------------------------------------------------------
my %new_states;
for my $r (@out) {
    next unless length $r->{state};
    $new_states{$r->{ref}} = $r->{state};
}

my %merged = merge_park_states($PARKS_OUT, \%new_states);

open my $pfh, '>', $PARKS_TMP or die "Cannot write temp file $PARKS_TMP: $!\n";
print $pfh "#park,state\n";
for my $park (sort keys %merged) {
    print $pfh join(',', $park, $merged{$park}), "\n";
}
close $pfh;

move $PARKS_TMP, $PARKS_OUT or die "move failed $PARKS_TMP -> $PARKS_OUT: $!\n";

print "--- Processing Complete ---\n";
for my $org (@TARGET_ORGS) {
    printf "%-8s records: %d (via sig: %d, via source fallback: %d)\n",
        $org, ($counts{$org} // 0), ($sig_hits{$org} // 0), ($fallback_hits{$org} // 0);
}
printf "SOTA location source: %d from sota_summits.csv, %d from Spothole's own fields\n",
    $sota_csv_hits, $sota_spot_hits;
print "Total unique spots written to $OUT: " . scalar(@out) . "\n";
print "Total park/state entries in $PARKS_OUT: " . scalar(keys %merged) . " (this run resolved " . scalar(keys %new_states) . " SOTA/Towers/WWBOTA entries)\n";
