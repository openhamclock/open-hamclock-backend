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
use HTTP::Tiny;
use JSON::PP;
use Fcntl qw(:flock);
use File::Path qw(make_path);

my %weather_apis = (
    'weather.gov' => {
        'func' => \&weather_gov,
        'attrib' => 'weather.gov',
    }, 'open-meteo.com' => {
        'func' => \&open_meteo,
        'attrib' => 'open-meteo.com',
        'apikey' => $ENV{'OPEN_METEO_API_KEY'} // "",
    }, 'openweathermap.org' => {
        'func' => \&open_weather,
        'attrib' => 'openweathermap.org',
        'apikey' => $ENV{'OPEN_WEATHER_API_KEY'} // "",
    },
);

my $UA = HTTP::Tiny->new(
    timeout => 5,
    agent   => "HamClock-NOAA/1.1"
);

# -------------------------
# Cache config
# -------------------------
# Requests are frequently for the same location within seconds (multiple
# HamClocks in the same house/club, or one HamClock polling DE+DX every
# few seconds), so a coarse, short-TTL disk cache removes almost all
# duplicate upstream calls without needing a DB or daemon.
my $CACHE_DIR = '/opt/hamclock-backend/cache/hamclock-wx-cache/';
my $WX_TTL    = $ENV{'WX_CACHE_TTL'} // 600;   # 10 min: matches OWM/Open-Meteo update cadence
my $TZ_TTL    = $ENV{'TZ_CACHE_TTL'} // 3600;  # 1 hr: DST offset doesn't change more often than this

# -------------------------
# Barometer trend config
# -------------------------
# Trend is derived from a small local history of pressure_hPa readings we
# already collect for the main WX display -- NOT from an extra upstream API
# call. This is what makes it cheap: it piggybacks on the existing $WX_TTL
# polling instead of querying the weather provider again.
my $TREND_WINDOW_SECS    = $ENV{'WX_TREND_WINDOW_SECS'} // 10800; # 3 hr: standard METAR/aviation pressure-tendency period
my $TREND_STEADY_HPA     = $ENV{'WX_TREND_STEADY_HPA'}  // 1.0;   # +/- this much over the window still reads as "steady"
my $TREND_MIN_SAMPLE_GAP = 300;                                   # don't log more than 1 sample/5 min even if polled harder

eval { make_path($CACHE_DIR) unless -d $CACHE_DIR; };

# -------------------------
# Parse QUERY_STRING
# -------------------------
my %q;
if ($ENV{QUERY_STRING}) {
    for (split /&/, $ENV{QUERY_STRING}) {
        my ($k,$v) = split /=/, $_, 2;
        next unless defined $k;
        $v //= '';
        $v =~ tr/+/ /;
        $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $q{$k} = $v;
    }
}

my ($lat,$lng) = @q{qw(lat lng)};

# -------------------------
# Defaults
# -------------------------
my %wx = (
    city             => "",
    temperature_c    => -999,
    pressure_hPa     => -999,
    pressure_chg     => -999,
    humidity_percent => -999,
    dewpoint         => -999,
    wind_speed_mps   => 0,
    wind_dir_name    => "N",
    clouds           => "",
    conditions       => "",
    attribution      => "",
    timezone         => 0,
);

# -------------------------
# Get the weather
# -------------------------
if (defined $lat && defined $lng && looks_like_coord($lat) && looks_like_coord($lng)) {

    # Timezone: try DST-aware sources in order, fall back to longitude approximation.
    # approx_timezone_seconds() is intentionally last -- it has no DST awareness.
    $wx{timezone} = get_timezone_secs($lat, $lng);

    # Weather: serve from cache if fresh; otherwise fetch and repopulate cache.
    get_weather_cached($lat, $lng, \%wx);

    # Barometer trend: like timezone, this is computed fresh every request
    # (not tied to $WX_TTL) since it's just a local file read/append, not an
    # upstream call.
    $wx{pressure_chg} = get_pressure_trend($lat, $lng, $wx{pressure_hPa});
}

hc_output(%wx);

exit;

# -------------------------
# Weather with caching + stale-on-error fallback
# -------------------------
sub get_weather_cached {
    my ($lat, $lng, $wx) = @_;
    my $file = cache_key('wx', $lat, $lng);

    my $cached = cache_get($file, $WX_TTL);
    if ($cached) {
        %$wx = (%$wx, %$cached);
        $wx->{_cache} = 'hit';
        return;
    }

    # Cache miss/stale: try live sources.
    my $ok = $weather_apis{'openweathermap.org'}->{'func'}->($lat, $lng, $wx);
    $ok = $weather_apis{'open-meteo.com'}->{'func'}->($lat, $lng, $wx) unless $ok;

    if ($ok) {
        # Cache everything needed to reconstruct the response, but not the
        # timezone or pressure_chg -- those are computed fresh every request
        # from their own local state, not tied to $WX_TTL.
        my %to_cache = %$wx;
        delete $to_cache{timezone};
        delete $to_cache{pressure_chg};
        cache_set($file, \%to_cache);
    } else {
        # Both live sources failed -- serve stale cache instead of -999s if we have it.
        my $stale = cache_get($file, 2**31);
        if ($stale) {
            %$wx = (%$wx, %$stale);
            $wx->{_cache} = 'stale';
        }
    }
}

# -------------------------
# Output (HamClock format)
# -------------------------
sub hc_output {
    my (%wx) = @_;
    print <<'HEADER';
HTTP/1.0 200 Ok
Content-Type: text/plain; charset=ISO-8859-1
Connection: close

HEADER

    print <<"BODY";
city=$wx{city}
temperature_c=$wx{temperature_c}
pressure_hPa=$wx{pressure_hPa}
pressure_chg=$wx{pressure_chg}
humidity_percent=$wx{humidity_percent}
dewpoint=$wx{dewpoint}
wind_speed_mps=$wx{wind_speed_mps}
wind_dir_name=$wx{wind_dir_name}
clouds=$wx{clouds}
conditions=$wx{conditions}
attribution=$wx{attribution}
timezone=$wx{timezone}
BODY
}

# -------------------------
# Timezone: DST-aware lookup (cached)
# -------------------------

# Try sources in order until one succeeds.
# Returns UTC offset in seconds, DST-aware where possible.
sub get_timezone_secs {
    my ($lat, $lng) = @_;

    my $file = cache_key('tz', $lat, $lng);
    my $cached = cache_get($file, $TZ_TTL);
    return $cached->{offset} if $cached && defined $cached->{offset};

    # 1. Open-Meteo timezone API -- free, no key, returns IANA name + utc_offset_seconds (DST-aware)
    my $tz = _tz_open_meteo($lat, $lng);

    # 2. TimeZoneDB -- free tier, key optional, returns DST-aware offset
    $tz = _tz_timezonedb($lat, $lng) unless defined $tz;

    if (defined $tz) {
        cache_set($file, { offset => $tz });
        return $tz;
    }

    # 3. Longitude approximation -- no DST, last resort. Not cached, since it's
    # cheap to compute and we want a real lookup to win as soon as one succeeds.
    return approx_timezone_seconds($lng);
}

# Open-Meteo timezone endpoint: completely free, no API key required.
# Returns utc_offset_seconds which is DST-aware (reflects current wall-clock offset).
sub _tz_open_meteo {
    my ($lat, $lng) = @_;
    my $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lng"
            . "&timezone=auto&forecast_days=0&hourly=temperature_2m&forecast_hours=1";
    my $resp = $UA->get($url);
    return undef unless $resp->{success};
    my $data = eval { decode_json($resp->{content}) };
    return undef if $@ || ref($data) ne 'HASH';
    return undef unless defined $data->{utc_offset_seconds};
    return int($data->{utc_offset_seconds});
}

# TimeZoneDB free tier: returns DST-aware offset.
# Requires TIMEZONEDB_API_KEY env var; skipped if not set.
sub _tz_timezonedb {
    my ($lat, $lng) = @_;
    my $key = $ENV{'TIMEZONEDB_API_KEY'} // '';
    return undef unless $key;
    my $url = "http://api.timezonedb.com/v2.1/get-time-zone"
            . "?key=$key&format=json&by=position&lat=$lat&lng=$lng";
    my $resp = $UA->get($url);
    return undef unless $resp->{success};
    my $data = eval { decode_json($resp->{content}) };
    return undef if $@ || ref($data) ne 'HASH';
    return undef unless ($data->{status} // '') eq 'OK';
    return undef unless defined $data->{gmtOffset};
    return int($data->{gmtOffset});
}

# -------------------------
# Barometer trend (rising / steady / falling)
# -------------------------
# HamClock's WXInfo.pressure_chg is a signed byte; the client only looks at
# its sign to pick the up/steady/down arrow graphic. So all we owe it is:
#   negative = falling, 0 = steady, positive = rising, -999 = unknown.
#
# We derive this from a small local log of pressure_hPa readings for this
# location (same 0.1-degree bucket as the weather cache) instead of calling
# the weather provider again. Each request appends the current reading
# (throttled to 1 per $TREND_MIN_SAMPLE_GAP) and prunes anything older than
# $TREND_WINDOW_SECS, then compares "now" to the oldest sample still in the
# window (~3 hours back, the standard aviation pressure-tendency period).
sub get_pressure_trend {
    my ($lat, $lng, $pressure_hPa) = @_;
    return -999 unless defined $pressure_hPa && $pressure_hPa != -999;

    my $file = cache_key('ptrend', $lat, $lng);
    my $hist = pressure_history_get($file);
    my $now  = time();

    push @$hist, [$now, $pressure_hPa + 0]
        if !@$hist || ($now - $hist->[-1][0]) >= $TREND_MIN_SAMPLE_GAP;

    my $cutoff = $now - $TREND_WINDOW_SECS - $TREND_MIN_SAMPLE_GAP;
    @$hist = grep { $_->[0] >= $cutoff } @$hist;
    pressure_history_set($file, $hist);

    # Oldest sample that's at least ~$TREND_WINDOW_SECS old.
    my $target = $now - $TREND_WINDOW_SECS;
    my $past;
    for my $s (@$hist) {
        $past = $s if $s->[0] <= $target && (!$past || $s->[0] > $past->[0]);
    }
    return 0 unless $past;   # not enough history yet -- call it steady, not a guess

    my $delta = $pressure_hPa - $past->[1];
    return 0 if abs($delta) < $TREND_STEADY_HPA;
    return $delta > 0 ? 1 : -1;
}

sub pressure_history_get {
    my ($file) = @_;
    return [] unless -f $file;
    open(my $fh, '<', $file) or return [];
    flock($fh, LOCK_SH);
    local $/;
    my $json = <$fh>;
    close($fh);
    my $data = eval { decode_json($json) };
    return ($@ || ref($data) ne 'ARRAY') ? [] : $data;
}

sub pressure_history_set {
    my ($file, $hist) = @_;
    my $tmp = "$file.tmp.$$";
    my $ok = eval {
        open(my $fh, '>', $tmp) or die "open: $!";
        flock($fh, LOCK_EX);
        print $fh encode_json($hist);
        close($fh);
        rename($tmp, $file) or die "rename: $!";
        1;
    };
    unlink($tmp) if !$ok && -f $tmp;
}

# -------------------------
# Alternative weather APIs
# -------------------------
sub weather_gov {
    my ($lat, $lng, $wx) = @_;
    my $p = $UA->get("https://api.weather.gov/points/$lat,$lng");
    if ($p->{success}) {
        my $pd = eval { decode_json($p->{content}) };

        if ($pd && $pd->{properties}) {

            # City from relativeLocation
            my $rl = $pd->{properties}->{relativeLocation}->{properties};
            $wx->{city} = $rl->{city} if $rl && $rl->{city};

            # Stations URL
            my $stations_url = $pd->{properties}->{observationStations};
            my $s = $UA->get($stations_url);

            if ($s->{success}) {
                my $sd = eval { decode_json($s->{content}) };
                for my $station (@{ $sd->{features} }) {
                    if ($station->{properties}->{stationIdentifier}) {
                        my $stationIdentifier = $station->{properties}->{stationIdentifier};
                        my $o = $UA->get(
                            "https://api.weather.gov/stations/$stationIdentifier/observations/latest"
                        );

                        if ($o->{success}) {
                            my $od = eval { decode_json($o->{content}) };
                            my $p = $od->{properties};

                            $wx->{temperature_c}    = val($p->{temperature}->{value});
                            $wx->{humidity_percent} = val($p->{relativeHumidity}->{value});
                            $wx->{dewpoint}         = val($p->{dewpoint}->{value});
                            $wx->{dewpoint}         = calculate_dew_point($wx->{temperature_c}, $wx->{humidity_percent});
                            $wx->{wind_speed_mps}   = val($p->{windSpeed}->{value});
                            $wx->{wind_dir_name}    = deg_to_cardinal(val($p->{windDirection}->{value}));

                            if (defined $p->{seaLevelPressure}->{value}) {
                                $wx->{pressure_hPa} =
                                    sprintf("%.0f", $p->{seaLevelPressure}->{value} / 100);
                            }

                            $wx->{conditions}  = $p->{textDescription} // "";
                            $wx->{clouds}      = $p->{textDescription} // "";
                            $wx->{attribution} = $weather_apis{'weather.gov'}->{'attrib'};
                            last;
                        }
                    }
                }
            }
        }
    }
}

sub open_meteo {
    my ($lat, $lng, $wx) = @_;
    my $base_url = "https://api.open-meteo.com/v1/forecast";
    my $get_lat_lng = "?latitude=$lat&longitude=$lng";
    my $get_params =
            "&current=temperature_2m"
            .",relative_humidity_2m"
            .",wind_speed_10m"
            .",wind_direction_10m"
            .",pressure_msl"
            .",weather_code"
            .",dew_point_2m"
            .",cloud_cover"
            ;
    my $get_units ="&wind_speed_unit=ms";

    my $p = $UA->get($base_url.$get_lat_lng.$get_params.$get_units);
    if ($p->{success}) {
        my $pd = eval { decode_json($p->{content}) };
        $wx->{temperature_c}    = val($pd->{current}->{temperature_2m});
        $wx->{humidity_percent} = val($pd->{current}->{relative_humidity_2m});
        $wx->{dewpoint}         = val($pd->{current}->{dew_point_2m});
        $wx->{wind_speed_mps}   = val($pd->{current}->{wind_speed_10m});
        $wx->{wind_dir_name}    = deg_to_cardinal(val($pd->{current}->{wind_direction_10m}));
        $wx->{clouds}           = val($pd->{current}->{cloud_cover});
        $wx->{conditions}       = get_wmo_description(val($pd->{current}->{weather_code}));
        $wx->{pressure_hPa}     = val($pd->{current}->{pressure_msl});
        $wx->{attribution} = $weather_apis{'open-meteo.com'}->{'attrib'};
        return 1;
    } else {
        $wx->{conditions} = $p->{reason};
        return 0;
    }
}

sub open_weather {
    my ($lat, $lng, $wx) = @_;
    my $base_url = "https://api.openweathermap.org/data/2.5/weather";
    my $get_lat_lng = "?lat=$lat&lon=$lng";
    my $get_api = "&appid=$weather_apis{'openweathermap.org'}->{'apikey'}";
    my $get_params = "&units=metric";

    my $p = $UA->get($base_url.$get_lat_lng.$get_api.$get_params);
    if ($p->{success}) {
        my $pd = eval { decode_json($p->{content}) };
        $wx->{city}             = $pd->{name} // "";
        $wx->{temperature_c}    = val($pd->{main}->{temp});
        $wx->{humidity_percent} = val($pd->{main}->{humidity});
        $wx->{dewpoint}         = calculate_dew_point($wx->{temperature_c}, $wx->{humidity_percent});
        $wx->{wind_speed_mps}   = val($pd->{wind}->{speed});
        $wx->{wind_dir_name}    = deg_to_cardinal(val($pd->{wind}->{deg}));
        $wx->{clouds}           = val($pd->{clouds}->{all});
        $wx->{conditions}       = $pd->{weather}[0]->{description};
        $wx->{pressure_hPa}     = val($pd->{main}->{sea_level});
        $wx->{attribution}      = $weather_apis{'openweathermap.org'}->{'attrib'};

        # OWM returns a DST-aware timezone offset -- prefer it over our lookup
        if (defined $pd->{timezone}) {
            $wx->{timezone} = int($pd->{timezone});
        }

        return 1;
    } else {
        return 0;
    }
}

# -------------------------
# Cache helpers
# -------------------------

# Round lat/lng to 0.1 degree (~11km) so nearby/duplicate requests share a
# cache entry. This is finer than typical station spacing, so it doesn't
# meaningfully reduce accuracy.
sub cache_key {
    my ($prefix, $lat, $lng) = @_;
    my $rlat = sprintf("%.1f", $lat + 0);
    my $rlng = sprintf("%.1f", $lng + 0);
    # "_" as separator (never appears in a formatted number) avoids a
    # visually-ambiguous "--" run for negative coordinates, e.g.
    # wx_46.9_-96.8.json instead of wx-46.9--96.8.json. Purely cosmetic:
    # the old "-"-joined form was already collision-free since %.1f always
    # yields exactly one digit after the decimal point, so the separator's
    # position was never actually ambiguous to the code -- only to a human
    # skimming `ls`.
    return "${CACHE_DIR}/${prefix}_${rlat}_${rlng}.json";
}

sub cache_get {
    my ($file, $ttl) = @_;
    return undef unless -f $file;
    my @st = stat($file);
    return undef unless @st;
    my $age = time() - $st[9];
    return undef if $age > $ttl;

    open(my $fh, '<', $file) or return undef;
    flock($fh, LOCK_SH);
    local $/;
    my $json = <$fh>;
    close($fh);

    my $data = eval { decode_json($json) };
    return undef if $@ || ref($data) ne 'HASH';
    return $data;
}

sub cache_set {
    my ($file, $data) = @_;
    my $tmp = "$file.tmp.$$";
    my $ok = eval {
        open(my $fh, '>', $tmp) or die "open: $!";
        flock($fh, LOCK_EX);
        print $fh encode_json($data);
        close($fh);
        rename($tmp, $file) or die "rename: $!";
        1;
    };
    unlink($tmp) if !$ok && -f $tmp;
}

# Basic sanity check so we don't create cache files from garbage query params.
sub looks_like_coord {
    my ($v) = @_;
    return defined($v) && $v =~ /^-?\d+(\.\d+)?$/;
}

# -------------------------
# Helpers
# -------------------------
sub val {
    my ($v) = @_;
    return -999 unless defined $v;
    return sprintf("%.2f",$v);
}

sub deg_to_cardinal {
    my ($deg) = @_;
    return "N" unless defined $deg;
    my @d = qw(N NE E SE S SW W NW);
    return $d[int((($deg % 360)+22.5)/45)%8];
}

sub calculate_dew_point {
    my ($temp_c, $humidity) = @_;
    my $a = 17.27;
    my $b = 237.7;
    my $alpha = (($a * $temp_c) / ($b + $temp_c)) + log($humidity/100.0);
    return ($b * $alpha) / ($a - $alpha);
}

# Last-resort fallback: pure longitude math, no DST awareness.
sub approx_timezone_seconds {
    my ($lng) = @_;
    return 0 unless defined $lng;
    my $hours = int(($lng / 15) + ($lng >= 0 ? 0.5 : -0.5));
    return $hours * 3600;
}

sub get_wmo_description {
    my ($code) = @_;
    return 'Clear'           if $code == 0;
    return 'Partly Cloudy'   if $code >= 1  && $code <= 3;
    return 'Hazy/Dusty'      if $code >= 4  && $code <= 9;
    return 'Foggy'           if $code == 10 || ($code >= 40 && $code <= 49);
    return 'Drizzle'         if $code >= 50 && $code <= 59;
    return 'Rain'            if $code >= 60 && $code <= 65;
    return 'Freezing Rain'   if $code >= 66 && $code <= 67;
    return 'Snow'            if ($code >= 68 && $code <= 69) || ($code >= 70 && $code <= 79);
    return 'Rain Showers'    if $code >= 80 && $code <= 82;
    return 'Snow Showers'    if $code >= 85 && $code <= 86;
    return 'Thunderstorm'    if $code >= 95 && $code <= 99;
    return 'Unknown Code';
}
