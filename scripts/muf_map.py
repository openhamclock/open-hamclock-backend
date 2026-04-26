#!/usr/bin/env python3

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

"""
muf_map.py — World VOACAP reliability map from DE.

Direct Python port of k4drw/hamclock-next PropEngine.cpp with:
  - Real ionosonde data from prop.kc2g.com/api/stations.json (optional)
  - MUF(3000) → MUF(distance) scaling
  - LUF calculation
  - OWF/FOT reliability window (peaks at 75% of MUF-LUF range)
  - Hop penalty: 0.92^(hops-1)
  - High-lat penalty
  - kIndex geomagnetic penalties
  - CW mode advantage (+16 dB)
  - Fully vectorized numpy — renders in <1s

Color scale matches HamClock REL bar:
  0%=#606460  ~30%=red  ~60%=yellow  100%=green
"""
import argparse, hashlib, io, json, math, os, sys, time
from pathlib import Path
import numpy as np

SKIP_KM  = 500.0
R_EARTH  = 6371.0
_ZR,_ZG,_ZB = 0x60, 0x64, 0x60   # #606460 zero-reliability color

# Mode advantage in dB over 100W SSB baseline
MODE_ADVANTAGE_DB = {
    'CW': 16.0, 'FT8': 12.0, 'FT4': 10.0, 'JT65': 15.0,
    'WSPR': 25.0, 'SSB': 0.0, 'AM': -6.0, 'FM': -3.0,
    'RTTY': 5.0, 'PSK31': 14.0
}


# ---------------------------------------------------------------------------
# REL colormap LUT:  #606460 → red → yellow → green
# ---------------------------------------------------------------------------
def _rel_color(t):
    t = max(0.0, min(1.0, t))
    if t < 0.25:
        s = t / 0.25
        return (int(_ZR + (180-_ZR)*s), int(_ZG*(1-s)), int(_ZB*(1-s)))
    elif t < 0.5:
        s = (t - 0.25) / 0.25
        return (180 + int(75*s), int(180*s), 0)
    else:
        s = (t - 0.5) / 0.5
        return (255 - int(255*s), 180 + int(75*s), int(60*s))

_REL_LUT = np.array([_rel_color(i/1023.0) for i in range(1024)], dtype=np.uint8)

def rel_to_rgb(rel_arr):
    # rel_arr is 0..100, normalize to 0..1
    idx = np.clip((rel_arr / 100.0 * 1023).astype(np.int32), 0, 1023)
    return _REL_LUT[idx]


# ---------------------------------------------------------------------------
# Signal margin (dB) — CW = +16 dB over 100W SSB baseline
# ---------------------------------------------------------------------------
def signal_margin_db(mode='CW', watts=100.0):
    mode_adv = MODE_ADVANTAGE_DB.get(mode.upper(), 0.0)
    power_offset = 10.0 * math.log10(max(0.01, watts) / 100.0)
    return mode_adv + power_offset


# ---------------------------------------------------------------------------
# Ionosonde data loading from KC2G JSON
# ---------------------------------------------------------------------------
def load_ionosonde(json_path):
    """
    Load stations from prop.kc2g.com/api/stations.json
    Returns list of dicts with lat, lon, foF2, mufd, md, confidence
    """
    stations = []
    try:
        with open(json_path) as f:
            data = json.load(f)
        for row in data:
            cs = float(row.get('cs', 0) or 0)
            if cs <= 0:
                continue
            st = row.get('station', {})
            lat = float(st.get('latitude', 0) or 0)
            lon = float(st.get('longitude', 0) or 0)
            if lon > 180.0:
                lon -= 360.0
            fof2 = float(row.get('fof2', 0) or 0)
            if fof2 <= 0:
                continue
            mufd = row.get('mufd')
            md   = float(row.get('md', 3.0) or 3.0)
            stations.append({
                'lat': lat, 'lon': lon,
                'foF2': fof2,
                'mufd': float(mufd) if mufd is not None else None,
                'md': md,
                'confidence': cs
            })
    except Exception as e:
        print(f"Ionosonde load failed: {e}", file=sys.stderr)
    return stations


def sample_iono_at_midpoints(stations, mid_lat, mid_lon):
    """
    Sample ionosonde foF2/mufd/md at the actual path midpoint for each pixel.
    mid_lat, mid_lon: 2D arrays (H,W) of path midpoint coordinates.
    Uses IDW matching IonosondeProvider.cpp: max 2000km radius, confidence-weighted.
    Returns (foF2, mufd, md) arrays shape (H,W).
    """
    MAX_D = 2000.0
    H, W = mid_lat.shape

    foF2_out = np.zeros((H, W))
    mufd_out  = np.full((H, W), np.nan)
    md_out    = np.full((H, W), 3.0)

    if not stations:
        return foF2_out, mufd_out, md_out

    s_lat = np.array([s['lat']  for s in stations])
    s_lon = np.array([s['lon']  for s in stations])
    s_fof = np.array([s['foF2'] for s in stations])
    s_muf = np.array([s['mufd'] if s['mufd'] is not None else np.nan
                      for s in stations])
    s_md  = np.array([s['md']   for s in stations])
    s_con = np.array([s['confidence'] for s in stations])

    # Haversine distance from each midpoint to each station
    # Shape: (H, W, N)
    mlat_r = np.radians(mid_lat)[:,:,None]
    mlon_r = np.radians(mid_lon)[:,:,None]
    s_latr = np.radians(s_lat)[None,None,:]
    s_lonr = np.radians(s_lon)[None,None,:]

    a = (np.sin((s_latr - mlat_r)/2)**2 +
         np.cos(mlat_r)*np.cos(s_latr)*np.sin((s_lonr - mlon_r)/2)**2)
    dist = 2*R_EARTH*np.arcsin(np.sqrt(np.clip(a, 0, 1)))  # (H,W,N)

    mask = dist <= MAX_D
    weights = np.where(mask,
                       (s_con[None,None,:] / 100.0) / np.maximum(1.0, dist**2),
                       0.0)

    w_sum    = weights.sum(axis=-1)
    has_data = w_sum > 0

    foF2_out = np.where(has_data,
                        (weights * s_fof[None,None,:]).sum(axis=-1) / np.maximum(w_sum, 1e-12),
                        0.0)

    mufd_mask  = mask & ~np.isnan(s_muf[None,None,:])
    w_mufd     = np.where(mufd_mask,
                          (s_con[None,None,:]/100.0)/np.maximum(1.0, dist**2), 0.0)
    w_mufd_sum = w_mufd.sum(axis=-1)
    s_muf_safe = np.where(np.isnan(s_muf), 0.0, s_muf)
    mufd_out   = np.where(w_mufd_sum > 0,
                          (w_mufd * s_muf_safe[None,None,:]).sum(axis=-1) /
                          np.maximum(w_mufd_sum, 1e-12),
                          np.nan)

    md_out = np.where(has_data,
                      (weights * s_md[None,None,:]).sum(axis=-1) / np.maximum(w_sum, 1e-12),
                      3.0)

    return foF2_out, mufd_out, md_out


# ---------------------------------------------------------------------------
# MUF calculation — port of PropEngine::calculateMUF
# ---------------------------------------------------------------------------
def calculate_muf_vec(dist, mid_lat, mid_lon, utc_hour, sfi, ssn,
                      foF2_iono, mufd_iono, md_iono):
    """
    All arrays of shape (H,W). Returns muf array (MHz).
    Prefers real ionosonde data, falls back to solar model.
    """
    # muf3000: prefer mufd, then foF2*md, then solar model
    hour_factor  = 1.0 + 0.4 * np.cos((utc_hour - 14.0) * math.pi / 12.0)
    lat_factor   = 1.0 - np.abs(mid_lat) / 150.0
    foF2_est     = 0.9 * math.sqrt(ssn + 15.0) * hour_factor * lat_factor
    muf3000_solar = foF2_est * 3.0

    # From ionosonde: mufd directly if available
    has_mufd = ~np.isnan(mufd_iono) & (mufd_iono > 0)
    has_fof2 = foF2_iono > 0

    muf3000 = np.where(has_mufd, mufd_iono,
               np.where(has_fof2, foF2_iono * md_iono,
                        muf3000_solar))

    # Convert MUF(3000) → MUF(distance)
    muf = np.where(dist < 3000.0,
                   muf3000 * np.sqrt(np.maximum(dist, 1.0) / 3000.0),
                   muf3000 * (1.0 + 0.15 * np.log10(np.maximum(dist, 3000.0) / 3000.0)))
    return muf


# ---------------------------------------------------------------------------
# LUF calculation — port of PropEngine::calculateLUF
# ---------------------------------------------------------------------------
def calculate_luf_vec(dist, mid_lat, utc_hour, sfi, k_index):
    path_factor  = np.sqrt(dist / 1000.0)
    solar_factor = math.sqrt(sfi)
    zenith_angle = np.abs(utc_hour - 12.0) * 15.0
    zenith_rad   = np.radians(zenith_angle)
    diurnal      = np.power(np.maximum(0.1, np.cos(zenith_rad)), 0.5)
    storm_factor = 1.0 + (k_index * 0.1)
    base_luf     = 2.0 * path_factor * solar_factor * diurnal * storm_factor / 10.0
    # Nighttime reduction
    is_night     = (utc_hour < 6.0) | (utc_hour > 18.0)
    luf          = np.where(is_night, base_luf * 0.3, base_luf)
    return np.maximum(1.0, luf)


# ---------------------------------------------------------------------------
# Reliability — port of PropEngine::calculateReliability
# ---------------------------------------------------------------------------
def calculate_reliability_vec(freq_mhz, dist, mid_lat, mid_lon,
                               utc_hour, sfi, ssn, k_index,
                               foF2_iono, mufd_iono, md_iono,
                               margin_db):
    muf = calculate_muf_vec(dist, mid_lat, mid_lon, utc_hour, sfi, ssn,
                             foF2_iono, mufd_iono, md_iono)
    luf = calculate_luf_vec(dist, mid_lat, utc_hour, sfi, k_index)

    eff_muf = muf * (1.0 + margin_db * 0.012)
    eff_luf = luf * np.maximum(0.1, 1.0 - margin_db * 0.008)

    # OWF/FOT reliability window (matches PropEngine exactly)
    rel = np.zeros_like(dist)

    # Above MUF * 1.1 — strong penalty
    cond1 = freq_mhz > eff_muf * 1.1
    rel = np.where(cond1, np.maximum(0.0, 30.0 - (freq_mhz - eff_muf) * 5.0), rel)

    # Just above MUF (MUF to MUF*1.1)
    cond2 = ~cond1 & (freq_mhz > eff_muf)
    rel = np.where(cond2,
                   30.0 + (eff_muf*1.1 - freq_mhz) / (eff_muf*0.1) * 20.0,
                   rel)

    # Well below LUF
    cond3 = ~cond1 & ~cond2 & (freq_mhz < eff_luf * 0.8)
    rel = np.where(cond3,
                   np.maximum(0.0, 20.0 - (eff_luf - freq_mhz) * 10.0),
                   rel)

    # Just below LUF (LUF*0.8 to LUF)
    cond4 = ~cond1 & ~cond2 & ~cond3 & (freq_mhz < eff_luf)
    rel = np.where(cond4,
                   20.0 + (freq_mhz - eff_luf*0.8) / (eff_luf*0.2) * 30.0,
                   rel)

    # In window (LUF to MUF) — OWF peaks at 75%
    cond5 = ~cond1 & ~cond2 & ~cond3 & ~cond4
    r_range = np.maximum(0.001, eff_muf - eff_luf)
    pos     = (freq_mhz - eff_luf) / r_range
    optimal = 0.75
    rel_window = np.where(pos < optimal,
                          50.0 + (pos / optimal) * 45.0,
                          95.0 - ((pos - optimal) / (1.0 - optimal)) * 45.0)
    rel = np.where(cond5, rel_window, rel)
    # Degenerate case: LUF >= MUF
    rel = np.where(cond5 & (r_range <= 0.001), 30.0, rel)

    # kIndex penalties
    kp = np.ones_like(rel)
    kp = np.where(k_index >= 7, 0.10, kp)
    kp = np.where((k_index >= 6) & (k_index < 7), 0.20, kp)
    kp = np.where((k_index >= 5) & (k_index < 6), 0.40, kp)
    kp = np.where((k_index >= 4) & (k_index < 5), 0.60, kp)
    kp = np.where((k_index >= 3) & (k_index < 4), 0.80, kp)
    rel = rel * kp

    # Hop penalty — continuous exponential decay to avoid hard rings at
    # 3500km, 7000km etc. 0.92^(hops-1) with continuous hops.
    hops = np.maximum(0.0, (dist - 500.0) / 3500.0)  # continuous, starts after skip zone
    rel  = rel * np.power(0.92, hops)

    # High-lat penalty — smooth gradient 60°→80° instead of step
    abs_mid_lat = np.abs(mid_lat)
    lat_pen = np.clip((abs_mid_lat - 60.0) / 20.0, 0.0, 1.0)  # 0 at 60°, 1 at 80°
    lat_factor = 1.0 - (lat_pen * 0.6)   # max 60% penalty at 80°+
    rel = rel * lat_factor
    # Extra storm penalty at high lat
    if k_index >= 3:
        rel = np.where(abs_mid_lat > 60.0, rel * (1.0 - lat_pen * 0.4), rel)

    # Solar flux penalties for high bands
    if freq_mhz >= 50.0 and sfi < 150.0:
        rel *= (sfi / 150.0) ** 1.5
    elif freq_mhz >= 28.0 and sfi < 120.0:
        rel *= math.sqrt(sfi / 120.0)
    elif freq_mhz >= 21.0 and sfi < 100.0:
        rel *= math.sqrt(sfi / 100.0)

    # Nighttime low-band enhancement / high-band penalty
    local_hour = (utc_hour + mid_lon / 15.0 + 24.0) % 24.0
    is_night   = (local_hour < 6.0) | (local_hour > 18.0)
    if freq_mhz <= 3.5:
        rel = np.where(~is_night, rel * 0.7, rel)
    elif freq_mhz <= 7.0:
        rel = np.where(is_night, rel * 1.1, rel)

    return np.clip(rel, 0.0, 99.0)


# ---------------------------------------------------------------------------
# True great-circle midpoint — port of PropEngine's Bx/By method
# ---------------------------------------------------------------------------
def gc_midpoint_vec(tx_lat, tx_lon, lat2d, lng2d):
    """Returns (mid_lat, mid_lon) arrays — true great-circle midpoint."""
    phi1 = math.radians(tx_lat)
    lam1 = math.radians(tx_lon)
    phi2 = np.radians(lat2d)
    lam2 = np.radians(lng2d)

    Bx = np.cos(phi2) * np.cos(lam2 - lam1)
    By = np.cos(phi2) * np.sin(lam2 - lam1)

    mid_phi = np.arctan2(math.sin(phi1) + np.sin(phi2),
                         np.sqrt((math.cos(phi1) + Bx)**2 + By**2))
    mid_lam = lam1 + np.arctan2(By, math.cos(phi1) + Bx)

    return np.degrees(mid_phi), np.degrees(mid_lam)


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
def render_map(tx_lat, tx_lng, utc_hour, month, ssn, sfi, k_index,
               mhz, mode, watts,
               stations, width=660, height=330, args_timing=False):
    from PIL import Image, ImageDraw

    lats   = np.linspace(90.0, -90.0, height)
    lngs   = np.linspace(-180.0, 180.0, width)
    lng2d, lat2d = np.meshgrid(lngs, lats)   # (H,W)

    # Distance TX → every pixel
    la1r = math.radians(tx_lat); lo1r = math.radians(tx_lng)
    la2r = np.radians(lat2d);    lo2r = np.radians(lng2d)
    a    = (np.sin((la2r-la1r)/2)**2 +
            math.cos(la1r)*np.cos(la2r)*np.sin((lo2r-lo1r)/2)**2)
    dist = 2*R_EARTH*np.arcsin(np.sqrt(np.clip(a, 0, 1)))

    # True great-circle midpoint
    mid_lat, mid_lon = gc_midpoint_vec(tx_lat, tx_lng, lat2d, lng2d)

    # Use solar model only — ionosonde IDW at midpoints creates visible
    # spoke artifacts because station influence circles project as spokes
    # when mapped through path midpoint geometry.
    foF2_iono = np.zeros((height, width))
    mufd_iono = np.full((height, width), np.nan)
    md_iono   = np.full((height, width), 3.0)

    margin_db = signal_margin_db(mode, watts)

    rel = calculate_reliability_vec(
        mhz, dist, mid_lat, mid_lon,
        float(utc_hour), float(sfi), float(ssn), float(k_index),
        foF2_iono, mufd_iono, md_iono,
        margin_db
    )

    # Skip zone
    skip_t = np.clip(dist / SKIP_KM, 0.0, 1.0) ** 2.5
    rel    = rel * skip_t

    # Smooth to eliminate geometric artifacts from midpoint sampling
    from scipy.ndimage import gaussian_filter
    rel = gaussian_filter(rel.astype(np.float64), sigma=4.0)
    rel = np.clip(rel, 0.0, 99.0)

    # Colorize
    rgb  = rel_to_rgb(rel)
    rgba = np.concatenate([rgb, np.full((*rgb.shape[:2],1), 255, np.uint8)], axis=-1)
    img  = Image.fromarray(rgba, 'RGBA')
    draw = ImageDraw.Draw(img)

    # TX dot
    tx_x = int(np.clip((tx_lng+180)/360*width,  5, width-6))
    tx_y = int(np.clip((90-tx_lat)/180*height,  5, height-6))
    draw.ellipse([(tx_x-5,tx_y-5),(tx_x+5,tx_y+5)], outline=(255,255,255,255), width=2)
    draw.ellipse([(tx_x-2,tx_y-2),(tx_x+2,tx_y+2)], fill=(255,255,255,255))

    return _overlay_borders(img, width, height)


# ---------------------------------------------------------------------------
# Borders
# ---------------------------------------------------------------------------
def _overlay_borders(img, width, height):
    import glob as _g
    from PIL import Image
    base = '/opt/hamclock-backend/htdocs/ham/HamClock/maps'
    bmps = sorted(_g.glob(f'{base}/map-*-Countries.bmp'), key=os.path.getsize)
    for p in ([f'{base}/map-N-{width}x{height}-Countries.bmp',
               f'{base}/map-D-{width}x{height}-Countries.bmp'] + bmps):
        if os.path.exists(p):
            try:
                arr   = np.array(Image.open(p).convert('RGB').resize((width,height)))
                brite = arr[:,:,0].astype(int)+arr[:,:,1].astype(int)+arr[:,:,2].astype(int)
                b     = brite > 80
                b[:4,:]=b[-4:,:]=b[:,:4]=b[:,-4:]=False
                ov    = np.zeros((height,width,4),np.uint8)
                ov[b] = [200,200,200,180]
                return Image.alpha_composite(img, Image.fromarray(ov,'RGBA'))
            except Exception as e:
                print(f"Border err: {e}", file=sys.stderr)
    return img


# ---------------------------------------------------------------------------
# Cache / main
# ---------------------------------------------------------------------------
def _cache_path(d, tx_lat, tx_lng, utc, ssn, sfi, kp, month, mhz, mode, watts, w, h):
    key = f"{tx_lat:.2f},{tx_lng:.2f},{utc},{ssn},{sfi},{kp},{month},{mhz:.3f},{mode},{watts},{w},{h}"
    return Path(d) / f"rel-{hashlib.md5(key.encode()).hexdigest()[:12]}.png"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--txlat',       type=float, required=True)
    ap.add_argument('--txlng',       type=float, required=True)
    ap.add_argument('--utc',         type=float, required=True)
    ap.add_argument('--month',       type=int,   required=True)
    ap.add_argument('--ssn',         type=float, default=50.0)
    ap.add_argument('--sfi',         type=float, default=120.0)
    ap.add_argument('--kindex',      type=float, default=2.0)
    ap.add_argument('--mhz',         type=float, required=True)
    ap.add_argument('--mode',        type=str,   default='CW')
    ap.add_argument('--watts',       type=float, default=100.0)
    ap.add_argument('--width',       type=int,   default=660)
    ap.add_argument('--height',      type=int,   default=330)
    ap.add_argument('--iono-json',   type=str,   default='',
                    help='Path to prop.kc2g.com stations.json cache')
    ap.add_argument('--cache-dir',   type=str,   default='/tmp')
    ap.add_argument('--cache-ttl',   type=int,   default=1800)
    ap.add_argument('--output',      type=str,   default='-')
    ap.add_argument('--timing',      action='store_true')
    args = ap.parse_args()

    cp = _cache_path(args.cache_dir, args.txlat, args.txlng,
                     args.utc, args.ssn, args.sfi, args.kindex,
                     args.month, args.mhz, args.mode, args.watts,
                     args.width, args.height)
    if args.cache_ttl > 0 and cp.exists():
        age = time.time() - cp.stat().st_mtime
        if age < args.cache_ttl:
            if args.timing: print(f"Cache hit ({age:.0f}s old)", file=sys.stderr)
            data = cp.read_bytes()
            (sys.stdout.buffer if args.output=='-' else open(args.output,'wb')).write(data)
            return

    # Load ionosonde data if available
    stations = []
    iono_path = args.iono_json
    if not iono_path:
        # Check default locations
        for p in ['/opt/hamclock-backend/tmp/stations.json',
                  '/opt/hamclock-backend/cache/stations.json']:
            if os.path.exists(p):
                iono_path = p
                break
    if iono_path:
        stations = load_ionosonde(iono_path)
        if args.timing:
            print(f"Loaded {len(stations)} ionosonde stations from {iono_path}", file=sys.stderr)
    else:
        if args.timing:
            print("No ionosonde data — using solar model fallback", file=sys.stderr)

    t0 = time.time()
    img = render_map(
        args.txlat, args.txlng, args.utc, args.month,
        args.ssn, args.sfi, args.kindex,
        args.mhz, args.mode, args.watts,
        stations, args.width, args.height, args_timing=args.timing
    )
    t1 = time.time()
    if args.timing:
        print(f"Render: {t1-t0:.2f}s", file=sys.stderr)

    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    data = buf.getvalue()
    try:
        cp.parent.mkdir(parents=True, exist_ok=True)
        cp.write_bytes(data)
    except Exception:
        pass
    (sys.stdout.buffer if args.output=='-' else open(args.output,'wb')).write(data)


if __name__ == '__main__':
    main()
