#!/usr/bin/env python3
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
#  moontle.py
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
"""
moontle.py - Generate a Moon TLE by fitting SGP4 orbital elements to
             an ephemeris, replicating ClearSkyInstitute's moontle tool.

Methodology (reverse-engineered from ClearSkyInstitute's esats directory):
  - Sample the Moon's GCRS position at 49 points, 1800s apart (~24.5 hours)
  - Fit SGP4 elements to minimize peak angular error (degrees) against ephemeris
  - Warm start (fast): Nelder-Mead from previous TLE elements (~1-2s)
  - Cold start (fallback): differential evolution + Nelder-Mead (~30-60s)
  - Report peak error in the same N/1000 degrees format as ClearSky's errors.txt

ClearSky's original used: libastro (XEphem) + liblevmar (LM fitting) + P13 (SGP4)
This implementation uses: astropy + scipy + sgp4

Usage:
    python3 moontle.py                        # generate TLE for current time
    python3 moontle.py --epoch "2026-04-07T12:00:00"
    python3 moontle.py --output errors.txt    # append error log, write .tle file
    python3 moontle.py --cold                 # force global search (first run)

Requirements:
    pip install astropy sgp4 scipy numpy
"""

import argparse
import math
import os
import sys
from datetime import datetime, timezone

import numpy as np
from astropy.coordinates import get_body
from astropy.time import Time
import astropy.units as u
from scipy.optimize import differential_evolution, minimize
from sgp4.api import Satrec


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

N_SAMPLES = 49
DT_SEC = 1800.0
WARM_THRESHOLD = 30.0  # degrees: if warm result is above this, fall back to cold
MAX_WARM_GAP   =  2.0  # days: if state is older than this, skip warm start entirely

# Bounds for cold start: [inc, raan, ecc, argp, ma, mm]
# RAAN/argp/ma span (-180, 540) so the optimizer never stalls at the 0/360 boundary.
COLD_BOUNDS = [
    ( 18.0,   30.0),   # inc  (degrees)
    (-180.0,  540.0),  # raan (degrees, wrapped mod 360 in TLE)
    (  0.01,   0.15),  # ecc
    (-180.0,  540.0),  # argp (degrees, wrapped)
    (-180.0,  540.0),  # ma   (degrees, wrapped)
    (  0.035,  0.040), # mm   (rev/day, ~27.3-day period)
]

# Persists last fitted params so the next run can warm-start
STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".moontle_state.npy")


# ---------------------------------------------------------------------------
# Ephemeris
# ---------------------------------------------------------------------------

def moon_gcrs_km(t: Time) -> np.ndarray:
    """Return Moon position in GCRS frame (km)."""
    moon = get_body('moon', t, ephemeris='builtin')
    gcrs = moon.gcrs
    return np.array([
        gcrs.cartesian.x.to(u.km).value,
        gcrs.cartesian.y.to(u.km).value,
        gcrs.cartesian.z.to(u.km).value,
    ])


def sample_ephemeris(epoch_jd: float):
    """Sample Moon GCRS positions at N_SAMPLES points, DT_SEC apart."""
    jds = [epoch_jd + i * DT_SEC / 86400.0 for i in range(N_SAMPLES)]
    times = [Time(jd, format='jd', scale='utc') for jd in jds]
    return jds, [moon_gcrs_km(t) for t in times]


# ---------------------------------------------------------------------------
# TLE construction / parsing
# ---------------------------------------------------------------------------

def tle_checksum(line: str) -> int:
    """Compute TLE checksum: sum first 68 chars where '-'=1, digits=value, mod 10."""
    s = 0
    for c in line[:68]:
        if c == '-':
            s += 1
        elif c.isdigit():
            s += int(c)
    return s % 10


def make_tle(epoch_jd: float, inc, raan, ecc, argp, ma, mm) -> tuple:
    t = Time(epoch_jd, format='jd', scale='utc')
    year2 = t.datetime.year % 100
    jan1 = Time(f"{t.datetime.year}-01-01T00:00:00", scale='utc')
    doy = (t - jan1).to(u.day).value + 1.0
    epoch_str = f"{year2:02d}{doy:012.8f}"
    ecc_str = f"{abs(ecc):.7f}"[2:]
    line1_body = f"1     1U     1A   {epoch_str}  .00000000  00000-0  0000000 0  001"
    line2_body = (f"2     1 {inc % 180:8.4f} {raan % 360:8.4f} {ecc_str}"
                  f" {argp % 360:8.4f} {ma % 360:8.4f} {mm:11.8f}    1")
    line1 = line1_body + str(tle_checksum(line1_body))
    line2 = line2_body + str(tle_checksum(line2_body))
    return line1, line2


def tle_to_params(line2: str) -> np.ndarray:
    """Extract [inc, raan, ecc, argp, ma, mm] from TLE line 2."""
    f = line2.split()
    return np.array([float(f[2]), float(f[3]), float("0." + f[4]),
                     float(f[5]), float(f[6]), float(f[7])])


# ---------------------------------------------------------------------------
# Objective function
# ---------------------------------------------------------------------------

def angular_sep_deg(r1: np.ndarray, r2: np.ndarray) -> float:
    n1 = r1 / np.linalg.norm(r1)
    n2 = r2 / np.linalg.norm(r2)
    return math.degrees(math.acos(np.clip(np.dot(n1, n2), -1.0, 1.0)))


def peak_error(epoch_jd: float, params, sample_jds, ephem) -> float:
    """Peak angular error (degrees) between SGP4 and ephemeris over all samples."""
    inc, raan, ecc, argp, ma, mm = params
    if not (0 < inc < 90 and 0 < ecc < 0.99 and mm > 0):
        return 999.0
    line1, line2 = make_tle(epoch_jd, inc, raan, ecc, argp, ma, mm)
    try:
        sat = Satrec.twoline2rv(line1, line2)
    except Exception:
        return 999.0
    errors = []
    for jd, ep in zip(sample_jds, ephem):
        e, r, v = sat.sgp4(int(jd), jd - int(jd))
        if e != 0:
            return 999.0
        errors.append(angular_sep_deg(np.array(r), ep))
    return max(errors)


# ---------------------------------------------------------------------------
# Optimizers
# ---------------------------------------------------------------------------

def run_nelder_mead(obj, x0) -> tuple:
    nm = minimize(obj, x0, method='Nelder-Mead',
                  options={'xatol': 1e-9, 'fatol': 1e-9,
                           'maxiter': 50000, 'maxfev': 100000})
    return nm.x, float(nm.fun)


def run_cold_start(obj, verbose: bool) -> tuple:
    if verbose:
        print("  Differential evolution (cold start)...", flush=True)
    de = differential_evolution(
        obj, COLD_BOUNDS,
        maxiter=300, popsize=15, tol=1e-7,
        seed=42, workers=1, disp=False, polish=False,
        mutation=(0.5, 1.5), recombination=0.9,
    )
    if verbose:
        print(f"  DE peak: {de.fun:.4f}°, polishing...", flush=True)
    return run_nelder_mead(obj, de.x)


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

def load_state(current_epoch_jd: float):
    """
    Load last fitted params. Returns (params, gap_days) or (None, None).
    Automatically returns None if the state is older than MAX_WARM_GAP days.
    """
    try:
        data = np.load(STATE_FILE)
        # data[0] = saved epoch JD, data[1:] = params
        saved_epoch_jd = float(data[0])
        params = data[1:]
        gap_days = abs(current_epoch_jd - saved_epoch_jd)
        return params, gap_days
    except Exception:
        return None, None


def save_state(params: np.ndarray, epoch_jd: float):
    try:
        np.save(STATE_FILE, np.concatenate([[epoch_jd], params]))
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Main fit routine
# ---------------------------------------------------------------------------

def fit_moon_tle(epoch_jd: float, force_cold: bool = False,
                 verbose: bool = True) -> tuple:
    """
    Fit a Moon TLE for the given epoch.
    Returns (line1, line2, peak_error_degrees).
    """
    if verbose:
        t = Time(epoch_jd, format='jd', scale='utc')
        jan1 = Time(f"{t.datetime.year}-01-01T00:00:00", scale='utc')
        doy = (t - jan1).to(u.day).value + 1.0
        print(f"Begin {int(t.unix)} {N_SAMPLES} {int(DT_SEC)} == "
              f"{t.iso[:10]} == day {doy:.4f} UTC", flush=True)

    if verbose:
        print("  Sampling ephemeris...", flush=True)
    sample_jds, ephem = sample_ephemeris(epoch_jd)
    obj = lambda p: peak_error(epoch_jd, p, sample_jds, ephem)

    x, err = None, 999.0

    # --- Try warm start ---
    if not force_cold:
        state, gap_days = load_state(epoch_jd)
        if state is not None:
            if gap_days > MAX_WARM_GAP:
                if verbose:
                    print(f"  State is {gap_days:.1f} days old (>{MAX_WARM_GAP}d), using cold start.", flush=True)
            else:
                warm_err0 = obj(state)
                if verbose:
                    print(f"  Warm start ({gap_days:.2f}d gap), initial error: {warm_err0:.3f}°", flush=True)
                if warm_err0 < 90.0:
                    if verbose:
                        print("  Nelder-Mead (warm)...", flush=True)
                    x, err = run_nelder_mead(obj, state)
                    if verbose:
                        print(f"  Warm result: {err:.4f}° ({err*1000:.0f}/1000)", flush=True)

    # --- Cold start if needed ---
    if err > WARM_THRESHOLD or force_cold:
        if verbose and not force_cold and x is not None:
            print("  Warm result insufficient, falling back to cold start...", flush=True)
        x, err = run_cold_start(obj, verbose)

    save_state(x, epoch_jd)
    line1, line2 = make_tle(epoch_jd, *x)
    return line1, line2, err


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate a Moon TLE by fitting SGP4 to ephemeris data.")
    parser.add_argument('--epoch', default=None,
        help='Epoch as ISO UTC e.g. "2026-04-07T12:00:00". Defaults to now.')
    parser.add_argument('--output', '-o', default=None,
        help='Append error log to this file; TLE written to <base>.tle')
    parser.add_argument('--cold', action='store_true',
        help='Force cold start (use on first run or after long gap).')
    parser.add_argument('--quiet', '-q', action='store_true',
        help='Suppress progress output.')
    args = parser.parse_args()

    epoch_jd = Time(args.epoch, scale='utc').jd if args.epoch else Time.now().jd

    line1, line2, peak = fit_moon_tle(
        epoch_jd, force_cold=args.cold, verbose=not args.quiet)

    peak_int = int(round(peak * 1000))

    if not args.quiet:
        print(f"peak error {peak_int}/1000")

    if args.output:
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(args.output, 'a') as f:
            f.write(f"{ts} moon error: {peak_int}/1000\n")
        base = args.output.rsplit('.', 1)[0] if '.' in os.path.basename(args.output) else args.output
        tle_path = base + '.tle'
        with open(tle_path, 'w') as f:
            f.write(f"Moon\n{line1}\n{line2}\n")
        if not args.quiet:
            print(f"TLE written to {tle_path}")
    else:
        print(f"Moon\n{line1}\n{line2}")


if __name__ == '__main__':
    main()
