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
#  filter_amsat_active.pl
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
# ============================================================
# filter_amsat_active.pl
# Filters the Celestrak TLE file to satellites defined in the ALIAS map
# (i.e., those shown on HamClock's satellite map), and writes esats.txt
# with friendly AMSAT names.

use strict;
use warnings;

my $TLE_IN    = $ENV{ESATS_TLE_CACHE} // "/opt/hamclock-backend/tle/tles.txt";
my $TLE_OUT   = $ENV{ESATS_OUT}       // "/opt/hamclock-backend/htdocs/ham/HamClock/esats/esats.txt";

# AMSAT name => { tle => Celestrak name, out => friendly output name }
# Keys are uppercased. Only needed when AMSAT and Celestrak names differ.
# 'out' is what gets written to esats.txt.
# Entries with empty 'tle' are skipped (not in Celestrak feeds).
my %ALIAS = (
    # --- Classic / legacy ---
    'AO-10'             => { tle => 'PHASE 3B (AO-10)',       out => 'AO-10'      },
    'AO-7'              => { tle => 'OSCAR 7 (AO-7)',          out => 'AO-7'       },
    'AO-7[A]'           => { tle => 'OSCAR 7 (AO-7)',          out => 'AO-7'       },
    'AO-7[B]'           => { tle => 'OSCAR 7 (AO-7)',          out => 'AO-7'       },

    # --- Active FM / linear transponder satellites ---
    'AO-27'             => { tle => 'EYESAT A (AO-27)',        out => 'AO-27'      },
    'AO-73'             => { tle => 'FUNCUBE-1 (AO-73)',       out => 'AO-73'      },
    'AO-85'             => { tle => 'FOX-1A (AO-85)',          out => 'AO-85'      },
    'AO-91'             => { tle => 'RADFXSAT (FOX-1B)',       out => 'AO-91'      },
    'AO-95'             => { tle => 'FOX-1CLIFF (AO-95)',      out => 'AO-95'      },
    'AO-123'            => { tle => 'ASRTU-1 (AO-123)',        out => 'AO-123'     },
    'AO-123_[FM]'       => { tle => 'ASRTU-1 (AO-123)',        out => 'AO-123'     },
    'AO-123_[SSTV]'     => { tle => 'ASRTU-1 (AO-123)',        out => 'AO-123'     },
    'FO-29'             => { tle => 'JAS-2 (FO-29)',           out => 'FO-29'      },
    'FO-29_[V/U]'       => { tle => 'JAS-2 (FO-29)',           out => 'FO-29'      },
    'JO-97'             => { tle => 'JY1SAT (JO-97)',          out => 'JO-97'      },
    'SO-50'             => { tle => 'SAUDISAT 1C (SO-50)',     out => 'SO-50'      },
    'SO-50_[FM]'        => { tle => 'SAUDISAT 1C (SO-50)',     out => 'SO-50'      },
    'SO-125'            => { tle => 'HADES-ICM',               out => 'SO-125'     },
    'SO-125_[FM]'       => { tle => 'HADES-ICM',               out => 'SO-125'     },
    'IO-86_[FM]'        => { tle => '',                        out => ''           },  # not in Celestrak
    'PO-101'            => { tle => 'DIWATA-2B',               out => 'PO-101'     },
    'PO-101_[FM]'       => { tle => 'DIWATA-2B',               out => 'PO-101'     },

    # --- Linear / SSB transponders ---
    'RS-44'             => { tle => 'RS-44 & BREEZE-KM R/B',  out => 'RS-44'      },
    'RS-44_[V/U]'       => { tle => 'RS-44 & BREEZE-KM R/B',  out => 'RS-44'      },

    # --- ISS (multiple modes, all map to same TLE) ---
    'ISS'               => { tle => 'ISS (ZARYA)',             out => 'ISS'        },
    'ISS-DATA'          => { tle => 'ISS (ZARYA)',             out => 'ISS'        },
    'ISS-FM'            => { tle => 'ISS (ZARYA)',             out => 'ISS'        },
    'ISS APRS'          => { tle => 'ISS (ZARYA)',             out => 'ISS'        },
    'ISS FM'            => { tle => 'ISS (ZARYA)',             out => 'ISS'        },
    'ISS_[APRS]'        => { tle => 'ISS (ZARYA)',             out => 'ISS'        },
    'ISS_[FM]'          => { tle => 'ISS (ZARYA)',             out => 'ISS'        },
    'ISS_[SSTV]'        => { tle => 'ISS (ZARYA)',             out => 'ISS'        },

    # --- Russian SSTV / FM satellites ---
    'QMR-KWT-2 (RS95S)' => { tle => 'QMR-KWT-2 (RS95S)',      out => 'RS95S'      },
    'QMR-KWT-2_(RS95S)' => { tle => 'QMR-KWT-2 (RS95S)',      out => 'RS95S'      },
    'RS95S'             => { tle => 'QMR-KWT-2 (RS95S)',       out => 'RS95S'      },
    'RS95S SSTV'        => { tle => 'QMR-KWT-2 (RS95S)',       out => 'RS95S'      },
    'RS95S_[FM]'        => { tle => 'QMR-KWT-2 (RS95S)',       out => 'RS95S'      },
    'RS95S_[SSTV]'      => { tle => 'QMR-KWT-2 (RS95S)',       out => 'RS95S'      },
    'RS40S'             => { tle => 'UMKA 1 (RS40S)',          out => 'RS40S'      },
    'RS40S_[SSTV]'      => { tle => 'UMKA 1 (RS40S)',          out => 'RS40S'      },
    'RS58S'             => { tle => 'MONITOR-3 (RS58S)',        out => 'RS58S'      },
    'RS58S_[SSTV]'      => { tle => 'MONITOR-3 (RS58S)',        out => 'RS58S'      },
    'RS18S SSTV'        => { tle => '',                        out => ''           },  # not in Celestrak
    'RS18S_[SSTV]'      => { tle => '',                        out => ''           },  # not in Celestrak
    'RS38S'             => { tle => 'VIZARD-METEO (RS38S)',    out => 'RS38S'      },  # NORAD 57189
    'RS38S_[SSTV]'      => { tle => 'VIZARD-METEO (RS38S)',    out => 'RS38S'      },  # NORAD 57189

    # --- GEO / no TLE ---
    'QO-100 NB'         => { tle => '',                        out => ''           },
    'QO-100_NB'         => { tle => '',                        out => ''           },
    'QO-100_[NB]'       => { tle => '',                        out => ''           },

    # --- APRS / digipeater satellites ---
    'NO-44'             => { tle => 'PCSAT (NO-44)',           out => 'NO-44'      },
    'NO-44_[APRS]'      => { tle => 'PCSAT (NO-44)',           out => 'NO-44'      },
    'BOTAN APRS'        => { tle => 'BOTAN',                   out => 'BOTAN'      },
    'SONATE-2 APRS'     => { tle => 'SONATE-2',                out => 'SONATE-2'   },
    'SONATE-2'          => { tle => 'SONATE-2',                out => 'SONATE-2'   },
    'SONATE-2_[APRS]'   => { tle => 'SONATE-2',                out => 'SONATE-2'   },
    'KNACKSAT-2'        => { tle => 'KNACKSAT-2',              out => 'KNACKSAT-2' },  # NORAD 67683
    'KNACKSAT-2_[APRS]' => { tle => 'KNACKSAT-2',              out => 'KNACKSAT-2' },  # NORAD 67683

    # --- Microwave / experimental ---
    'CATSAT'            => { tle => 'CATSAT',                  out => 'CATSAT'     },

    # --- Legacy UO-11 telemetry ---
    'UO-11'             => { tle => 'UOSAT 2 (UO-11)',         out => 'UO-11'      },
    'UO-11_[TLM]'       => { tle => 'UOSAT 2 (UO-11)',         out => 'UO-11'      },

    # --- ArcticSat-1 ---
    'ARCTICSAT-1'       => { tle => 'ARCTICSAT 1 (RS74S)',     out => 'ArcticSat-1'},
    'ARCTICSAT-1_[SSTV]'=> { tle => 'ARCTICSAT 1 (RS74S)',     out => 'ArcticSat-1'},

    # --- CroCube (Croatia) ---
    'CROCUBE'           => { tle => 'CROCUBE',                 out => 'CroCube'    },
    'CROCUBE_[GFSK]'    => { tle => 'CROCUBE',                 out => 'CroCube'    },

    # --- LASARsat (Czech) ---
    'LASARSAT'          => { tle => 'LASARSAT',                out => 'LASARsat'   },
    'LASARSAT_[GFSK]'   => { tle => 'LASARSAT',                out => 'LASARsat'   },

    # --- GRBBeta ---
    'GRBBETA'           => { tle => 'GRBBETA',                 out => 'GRBBeta'    },
    'GRBBETA_[GFSK]'    => { tle => 'GRBBETA',                 out => 'GRBBeta'    },
    'GRBBETA_[UHF_DIGI]'=> { tle => 'GRBBETA',                 out => 'GRBBeta'    },
    'GRBBETA_[VHF_DIGI]'=> { tle => 'GRBBETA',                 out => 'GRBBeta'    },

    # --- HADES-SA (AMSAT-EA, Spain) — temp NORAD 98380, launched 2026-03-30 ---
    'HADES-SA'              => { tle => 'HADES-SA',            out => 'HADES-SA'   },
    'HADES-SA_[CODEC2]'     => { tle => 'HADES-SA',            out => 'HADES-SA'   },
    'HADES-SA_[FSK]'        => { tle => 'HADES-SA',            out => 'HADES-SA'   },
    'HADES-SA_[SSDV]'       => { tle => 'HADES-SA',            out => 'HADES-SA'   },

    # --- CAS-3H (LilacSat-2, Harbin) — NORAD 40908 ---
    # Celestrak feed uses "LILACSAT-2" (hyphen); CATNR rename writes "LILACSAT 2" (space)
    'CAS-3H'            => { tle => 'LILACSAT-2',              out => 'CAS-3H'     },
    'CAS-3H_[FM]'       => { tle => 'LILACSAT-2',              out => 'CAS-3H'     },

    # --- Luca (Montenegro Space Research) — NORAD 67287, fetched by CATNR, renamed to "LUCA" ---
    'LUCA'              => { tle => 'LUCA',                    out => 'Luca'       },
    'LUCA_[SSDV]'       => { tle => 'LUCA',                    out => 'Luca'       },

    # --- OTP-2 (Rogue Space) — NORAD 63235 ---
    'OTP-2'             => { tle => 'OTP-2',                   out => 'OTP-2'      },
    'OTP-2_[MUSIC]'     => { tle => 'OTP-2',                   out => 'OTP-2'      },

    # --- Foresail-1p (Finland) — temp NORAD 98467, not yet in standard Celestrak feeds ---
    'FORESAIL-1P'           => { tle => 'FORESAIL-1P',         out => 'Foresail-1p'},
    'FORESAIL-1P_[GMSK]'    => { tle => 'FORESAIL-1P',         out => 'Foresail-1p'},
    'FORESAIL-1P_[UHF_DIGI]'=> { tle => 'FORESAIL-1P',         out => 'Foresail-1p'},

    # --- Ten-Koh 2 (Japan) — temp NORAD 98542, pending confirmation in Celestrak ---
    'TEN-KOH2'          => { tle => 'TEN-KOH 2',              out => 'Ten-Koh2'   },
    'TEN-KOH2_[V/U]'    => { tle => 'TEN-KOH 2',              out => 'Ten-Koh2'   },

    # --- SilverSat ---
    'SILVERSAT'         => { tle => 'SILVERSAT',               out => 'SilverSat'  },
    'SILVERSAT_[SSDV]'  => { tle => 'SILVERSAT',               out => 'SilverSat'  },
);

# Build lookup: uppercased Celestrak TLE name => friendly output name
# Skip entries with empty tle (not in Celestrak)
my %want;
for my $key (keys %ALIAS) {
    my $entry = $ALIAS{$key};
    next unless $entry->{tle} && $entry->{tle} ne '';
    $want{uc($entry->{tle})} = $entry->{out};
}

my $mapped = scalar keys %want;
print STDERR "Satellites in map (ALIAS entries with TLEs): $mapped\n";

# --- Read and filter TLE file, writing friendly names ---
open my $in, "<", $TLE_IN or die "Cannot open TLE file $TLE_IN: $!\n";
my @lines = <$in>;
close $in;
chomp @lines;

open my $out, ">", $TLE_OUT or die "Cannot write $TLE_OUT: $!\n";

my $i          = 0;
my $written    = 0;
my %seen_norad;

while ($i < @lines) {
    my $name = $lines[$i];
    $name =~ s/\r$//;
    $name =~ s/^\s+|\s+$//g;

    if ($name eq '' || $name =~ /^[12]\s/) { $i++; next; }

    my $l1 = $lines[$i+1] // '';
    my $l2 = $lines[$i+2] // '';
    $l1 =~ s/\r$//;
    $l2 =~ s/\r$//;

    if ($l1 =~ /^1\s/ && $l2 =~ /^2\s/) {
        my ($norad) = $l1 =~ /^1\s+(\d+)/;
        my $key = uc($name);
        $key =~ s/^\s+|\s+$//g;

        if (exists $want{$key} && !$seen_norad{$norad}) {
            my $out_name = $want{$key};
            print $out "$out_name\n$l1\n$l2\n";
            $seen_norad{$norad} = 1;
            $written++;
        }
        $i += 3;
    } else {
        $i++;
    }
}

close $out;
print STDERR "Wrote $written blocks to $TLE_OUT (from $mapped mapped TLE keys)\n";
