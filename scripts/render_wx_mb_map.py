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
#  render_wx_mb_map.py
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
render_wx_mb_map.py

Render one HamClock Wx-mB map (Day or Night) from:
- a GFS GRIB2 subset file
- a size-matched base bitmap (.bmp or .bmp.z)

Outputs:
- map-<TAG>-<WxH>-Wx-mB.bmp
- map-<TAG>-<WxH>-Wx-mB.bmp.z

Fields used:
- Mean sea level pressure (PRMSL/MSL)
- 10 m winds (UGRD/VGRD or 10u/10v)
- 2 m temperature (TMP/2t) [required]
"""

import argparse
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
import pygrib

from hc_bmp import (
    read_bmp_v4_rgb565_topdown,
    rgb565_to_rgb888,
    rgb888_to_rgb565,
    write_bmp_v4_rgb565_topdown,
)
from hc_zlib import zread, zwrite


def resize_nn(arr: np.ndarray, out_h: int, out_w: int) -> np.ndarray:
    in_h, in_w = arr.shape
    yi = (np.linspace(0, in_h - 1, out_h)).astype(np.int32)
    xi = (np.linspace(0, in_w - 1, out_w)).astype(np.int32)
    return arr[yi][:, xi]


def resize_bilinear(arr: np.ndarray, out_h: int, out_w: int) -> np.ndarray:
    """Lightweight bilinear resize using two 1D interpolations"""
    in_h, in_w = arr.shape
    if in_h == out_h and in_w == out_w:
        return arr.copy()

    arrf = arr.astype(np.float64, copy=False)

    x_old = np.arange(in_w, dtype=np.float64)
    x_new = np.linspace(0, in_w - 1, out_w, dtype=np.float64)
    tmp = np.empty((in_h, out_w), dtype=np.float64)
    for r in range(in_h):
        tmp[r, :] = np.interp(x_new, x_old, arrf[r, :])

    y_old = np.arange(in_h, dtype=np.float64)
    y_new = np.linspace(0, in_h - 1, out_h, dtype=np.float64)
    out = np.empty((out_h, out_w), dtype=np.float64)
    for c in range(out_w):
        out[:, c] = np.interp(y_new, y_old, tmp[:, c])

    return out


def box_blur(arr: np.ndarray, passes: int = 1) -> np.ndarray:
    """Small wrap smoothing to reduce contour clutter"""
    a = arr.astype(np.float64, copy=False)
    for _ in range(passes):
        a = (
            a
            + np.roll(a, 1, axis=0) + np.roll(a, -1, axis=0)
            + np.roll(a, 1, axis=1) + np.roll(a, -1, axis=1)
        ) / 5.0
    return a

def hamclock_temp_cmap():
    """
    HamClock Celsius palette - warm-shifted to better match global temps.
    """
    stops = [
        (-50, "#D0E4F8"),
        (-40, "#B0D4F8"),
        (-30, "#80BCF8"),
        (-20, "#70A4F8"),
        (-10, "#3874D0"),
        (  0, "#2060A8"),
        ( 10, "#009CD8"),  # cyan transition
        ( 15, "#B8E4B0"),  # green
        ( 22, "#F8D020"),  # yellow
        ( 28, "#F88C20"),  # orange
        ( 36, "#E80050"),  # red/pink
        ( 50, "#680028"),
    ]
    vals = np.array([v for v, _ in stops], dtype=np.float64)
    vals = (vals - vals.min()) / (vals.max() - vals.min())
    cols = [c for _, c in stops]
    return LinearSegmentedColormap.from_list("hamclock_celsius", list(zip(vals, cols)))

def pick_required(msgs, *, short_names, type_of_level=None, level=None, label="field"):
    for sn in short_names:
        for g in msgs:
            if getattr(g, "shortName", None) != sn:
                continue
            if type_of_level is not None and getattr(g, "typeOfLevel", None) != type_of_level:
                continue
            if level is not None and getattr(g, "level", None) != level:
                continue
            print(
                f"Selected {label}: shortName={g.shortName} name={g.name} "
                f"typeOfLevel={g.typeOfLevel} level={g.level} units={getattr(g, 'units', None)}"
            )
            return g
    raise RuntimeError(
        f"Required {label} not found. Tried shortNames={short_names}, "
        f"typeOfLevel={type_of_level}, level={level}"
    )


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--grib", required=True, help="Path to GFS GRIB2 subset")
    p.add_argument("--base", required=True, help="Path to base BMP(.z)")
    p.add_argument("--outdir", required=True, help="Output directory")
    p.add_argument("--tag", required=True, choices=["D", "N"], help="Day/Night tag")
    p.add_argument("--width", type=int, required=True)
    p.add_argument("--height", type=int, required=True)
    p.add_argument("--log-inventory", action="store_true", help="Print GRIB inventory")
    p.add_argument(
        "--units", choices=["mb", "inches"], default="mb",
        help="Pressure unit for isobars: mb (millibars, default) or inches (inHg)",
    )
    p.add_argument(
        "--map-type", default="Wx-mB",
        help="Map type tag used in output filename, e.g. Wx-mB or Wx-in (default: Wx-mB)",
    )
    return p.parse_args()


def main():
    args = parse_args()
    W = args.width
    H = args.height

    bw, bh, base565 = read_bmp_v4_rgb565_topdown(zread(args.base))
    if (bw, bh) != (W, H):
        raise SystemExit(f"ERROR: base map is {bw}x{bh}, expected {W}x{H}: {args.base}")
    base_rgb = rgb565_to_rgb888(base565)

    grbs = pygrib.open(args.grib)
    msgs = list(grbs)

    if args.log_inventory:
        print(f"GRIB inventory for {args.tag} {W}x{H} (subset file {args.grib}):")
        for i, g in enumerate(msgs, 1):
            try:
                print(
                    f"  {i:02d}: shortName={g.shortName!r} name={g.name!r} "
                    f"typeOfLevel={g.typeOfLevel!r} level={g.level!r} units={getattr(g, 'units', None)!r}"
                )
            except Exception as e:
                print(f"  {i:02d}: <metadata error: {e}>")

    g_pr = pick_required(
        msgs,
        short_names=["prmsl", "msl"],
        type_of_level="meanSea",
        label="mean sea level pressure",
    )
    pr = g_pr.values / 100.0  # Pa -> hPa/mB

    # Unit conversion for display
    if args.units == "inches":
        pr_display = pr * 0.02953  # hPa -> inHg
        # Isobar levels in inHg spanning ~28.35-31.00 (equiv 960-1050 hPa)
        p_display_levels = np.arange(28.35, 31.01, 0.10)
        p_label_step = 0.30   # label every ~3 lines
        p_fmt = "%.2f"
    else:
        pr_display = pr
        p_display_levels = np.arange(960, 1046, 5)
        p_label_step = 15     # label every 15 mB
        p_fmt = "%d"

    g_u10 = pick_required(
        msgs,
        short_names=["10u", "ugrd"],
        type_of_level="heightAboveGround",
        level=10,
        label="10m U wind",
    )
    g_v10 = pick_required(
        msgs,
        short_names=["10v", "vgrd"],
        type_of_level="heightAboveGround",
        level=10,
        label="10m V wind",
    )
    u10 = g_u10.values
    v10 = g_v10.values

    g_t2m = pick_required(
        msgs,
        short_names=["2t", "tmp"],
        type_of_level="heightAboveGround",
        level=2,
        label="2m temperature",
    )
    t2m_k = g_t2m.values
    grbs.close()

    t2m_c = t2m_k - 273.15

    # ── Longitude alignment: roll raw GRIB arrays BEFORE resampling ──────────
    # GFS runs 0->359.75 deg (1440 cols at 0.25 deg). The map base is centered
    # on the prime meridian (-180->180). Roll so col-0 = -180 deg (= 180E in GFS).
    # Done on the native grid before resize so sub-pixel accuracy is preserved.
    # g_pr.lons is shape (nlat, nlon); row 0 gives the longitude sequence.
    _, lons_grib_2d = g_pr.latlons()   # returns (lats, lons) as 2D arrays
    lons_grib = lons_grib_2d[0]        # 1-D lon array for row 0
    roll_col  = int(np.argmin(np.abs(lons_grib - 180.0)))
    pr     = np.roll(pr,    roll_col, axis=1)
    u10    = np.roll(u10,   roll_col, axis=1)
    v10    = np.roll(v10,   roll_col, axis=1)
    t2m_c  = np.roll(t2m_c, roll_col, axis=1)
    # ─────────────────────────────────────────────────────────────────────────

    # Bilinear resample for smoother fields; reduce contour clutter with pressure-only blur.
    pr_s  = resize_bilinear(pr_display, H, W)
    u_s   = resize_bilinear(u10,   H, W)
    v_s   = resize_bilinear(v10,   H, W)
    t_s_c = resize_bilinear(t2m_c, H, W)
    pr_s  = box_blur(pr_s, passes=2)
    
    scale = max(W / 660.0, 1.0)

    # Pressure labels / lines (reduced clutter)
    lw = 0.55 * (scale ** 0.55)
    fs = max(6.0 * (scale ** 0.55), 6.0)

    # Wind arrows: fewer and more visible
    step = int(max(12 * scale, 12))
    qwidth = 0.0016 / scale
    t_fs = max(4.5 * (scale ** 0.6), 4.5)

    fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
    ax = plt.axes([0, 0, 1, 1])
    ax.set_axis_off()
    ax.imshow(base_rgb, origin="upper")

    # Temperature shading using sampled HamClock Celsius palette
    temp_cmap = hamclock_temp_cmap()

    # Continuous (feathered) temperature shading instead of banded contourf bins
    tmin_c, tmax_c = -40.0, 50.0
    t_plot = np.clip(t_s_c, tmin_c, tmax_c)

    ax.imshow(
       t_plot,
       origin="upper",
       cmap=temp_cmap,
       vmin=tmin_c,
       vmax=tmax_c,
       alpha=0.72,
       interpolation="bilinear",
    )

    # Sparse temp labels (subtle)
    t_label_levels = np.arange(-30, 46, 10)
    ct = ax.contour(t_s_c, levels=t_label_levels, colors="none", linewidths=0.0)
    ax.clabel(ct, inline=True, fmt="%d", fontsize=t_fs, colors="white")

    # Isobars: unit-aware levels and labels
    cs = ax.contour(pr_s, levels=p_display_levels, colors="white", linewidths=lw, alpha=0.85)
    label_levels = [
        lv for lv in cs.levels
        if abs(round(lv / p_label_step) * p_label_step - lv) < (p_label_step * 0.01)
    ]
    if label_levels:
        ax.clabel(cs, levels=label_levels, inline=True, fmt=p_fmt, fontsize=fs, colors="white")

    # Wind direction arrows (uniform size, direction-only)
    yy, xx = np.mgrid[0:H:step, 0:W:step]
    uu = u_s[0:H:step, 0:W:step]
    vv = -v_s[0:H:step, 0:W:step]  # invert for image y-axis

    mag = np.hypot(uu, vv)

    # Keep only meaningful winds so calm areas don't create clutter
    mask = mag < 1.5  # m/s threshold
    uu = np.ma.array(uu, mask=mask)
    vv = np.ma.array(vv, mask=mask)
    mag_m = np.ma.array(mag, mask=mask)

    # Normalize to direction-only (all arrows same length)
    # Avoid divide-by-zero via masked denominator floor.
    denom = np.ma.maximum(mag_m, 1e-6)
    uu_dir = uu / denom
    vv_dir = vv / denom

    # Fixed arrow length in pixels (uniform visual size)
    arrow_len_px = 6.5 * scale   # tune 8..14
    uu_px = uu_dir * arrow_len_px
    vv_px = vv_dir * arrow_len_px

    ax.quiver(
        xx, yy, uu_px, vv_px,
        color="#8461FF",
        edgecolors="#8461FF",
        linewidths=0.0,
        angles="xy",
        scale_units="xy",
        scale=1.0,                # vectors already in pixel lengths
        width=max(0.0024 / scale, qwidth * 2.4),
        alpha=1.0,
        pivot="tail",
        headwidth=5.5,
        headlength=7.0,
        headaxislength=6.0,
        minlength=0.0,
        minshaft=1.5,
        zorder=9,
    )

    fig.canvas.draw()
    wpx, hpx = fig.canvas.get_width_height()
    rgba = np.frombuffer(fig.canvas.buffer_rgba(), dtype=np.uint8).reshape(hpx, wpx, 4)
    img = rgba[:, :, :3].copy()
    plt.close(fig)

    out_bmp = f"{args.outdir}/map-{args.tag}-{W}x{H}-{args.map_type}.bmp"
    out_z = out_bmp + ".z"

    arr565 = rgb888_to_rgb565(img)
    write_bmp_v4_rgb565_topdown(out_bmp, arr565)
    zwrite(out_z, open(out_bmp, "rb").read())

    print("OK:", out_z)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        raise
