#!/usr/bin/env python3
"""
poll_maps.py — Poll ALL map types from multiple HamClock servers every N minutes.
Captures Last-Modified headers only; files are discarded (sent to /dev/null).
Prints a live table after each full round, then a final cross-server comparison report.

Usage:
    python3 poll_maps.py [--rounds N] [--interval SECONDS] [--servers SERVER [SERVER ...]]
                        [--map-types TYPE [TYPE ...]] [--sizes SIZE [SIZE ...]]

Defaults:
    Rounds   : 12 (1 hour at 5-min interval)
    Interval : 300 s (5 min)
    Servers  : ohb  csi  (see SERVERS dict below — edit base URLs to match your setup)
    Map types: Aurora Clouds Countries DRAP-S MUF-RT OHB-S CSI-S Physical Terrain Wx-in Wx-mB
    Sizes    : all 8 standard sizes

Notes:
  • All three servers (hamclock, ohb, csi) use identical filenames — only the base URL differs.
  • The cross-server comparison shows Last-Modified deltas between servers for the same file,
    revealing which server regenerates its maps earliest.
"""

import subprocess
import re
import time
import argparse
from datetime import datetime, timezone
from collections import defaultdict

# ── Server definitions ────────────────────────────────────────────────────────
# Key  : short label used in output
# Value: base URL up to (but not including) the filename
SERVERS = {
    "ohb": "http://ohb.hamclock.app/ham/HamClock/maps",
    "csi": "https://clearskyinstitute.com/ham/HamClock/maps",
}

# ── Map types to poll ─────────────────────────────────────────────────────────
# Each entry: (filename_suffix, compressed?)
# "compressed" means the .bmp.z variant; set False for plain .bmp
# Add OHB-S / CSI-S (or whatever suffix your servers use) here:
MAP_TYPES = [
    ("Aurora",    True),
    ("Clouds",    True),
    ("Countries", True),
    ("DRAP-S",    True),
    ("MUF-RT",    True),
    ("Physical",  True),
    ("Terrain",   True),
    ("Wx-in",     True),
    ("Wx-mB",     True),
]

# ── Sizes ─────────────────────────────────────────────────────────────────────
SIZES = [
    "660x330",
    "1320x660",
    "1980x990",
    "2640x1320",
    "3960x1980",
    "5280x2640",
    "5940x2970",
    "7920x3960",
]

VARIANTS = ["D", "N"]  # Day / Night


# ── URL builder ───────────────────────────────────────────────────────────────

def build_entries(servers, map_types, sizes, variants):
    """
    Returns list of (server_key, label, url).
    label = "<variant>-<size>-<map_type>"
    """
    entries = []
    for srv_key, base_url in servers.items():
        for variant in variants:
            for size in sizes:
                for mtype, compressed in map_types:
                    ext = "bmp.z" if compressed else "bmp"
                    filename = f"map-{variant}-{size}-{mtype}.{ext}"
                    url = f"{base_url}/{filename}"
                    label = f"{variant}-{size}-{mtype}"
                    entries.append((srv_key, label, url))
    return entries


# ── HTTP HEAD fetch ───────────────────────────────────────────────────────────

def fetch_last_modified(url: str, timeout: int = 30) -> str:
    """
    Run curl -s -I to get headers only.
    Returns the Last-Modified string, or an error token.
    """
    try:
        result = subprocess.run(
            ["curl", "-s", "-I", "--max-time", str(timeout), url],
            capture_output=True,
            text=True,
            timeout=timeout + 5,
        )
        for line in result.stdout.splitlines():
            if line.lower().startswith("last-modified:"):
                return line.split(":", 1)[1].strip()
        for line in result.stdout.splitlines():
            if line.startswith("HTTP/"):
                return f"NO-HEADER ({line.strip()})"
        return "NO-RESPONSE"
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    except Exception as e:
        return f"ERROR: {e}"


def parse_lm(lm_str: str):
    """Parse a Last-Modified HTTP date to a UTC datetime, or None on failure."""
    for fmt in (
        "%a, %d %b %Y %H:%M:%S %Z",
        "%a, %d %b %Y %H:%M:%S GMT",
    ):
        try:
            return datetime.strptime(lm_str, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


# ── Table helpers ─────────────────────────────────────────────────────────────

def col_widths(rows, headers):
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    return widths


def print_table(headers, rows, title=""):
    widths = col_widths(rows, headers)
    sep = "+-" + "-+-".join("-" * w for w in widths) + "-+"
    fmt = "| " + " | ".join(f"{{:<{w}}}" for w in widths) + " |"
    if title:
        bar = "=" * len(sep)
        print(f"\n{bar}")
        print(f"  {title}")
        print(bar)
    print(sep)
    print(fmt.format(*headers))
    print(sep)
    for row in rows:
        print(fmt.format(*[str(c) for c in row]))
    print(sep)


def shorten_lm(lm: str, maxlen: int = 25) -> str:
    """Trim long LM strings for table display."""
    return lm[:maxlen] if len(lm) > maxlen else lm


# ── Cross-server comparison ───────────────────────────────────────────────────

def cross_server_comparison(results, servers, map_types, sizes, variants):
    """
    For each (variant, size, map_type) triple, show the Last-Modified observed
    on each server in the MOST RECENT round, plus the delta in seconds between them.
    Only shown when ≥ 2 servers are configured.
    """
    srv_keys = list(servers.keys())
    if len(srv_keys) < 2:
        print("\n  (Only one server configured — cross-server comparison not applicable)")
        return

    print(f"\n{'═'*80}")
    print("  CROSS-SERVER COMPARISON  (most recent poll per server)")
    print(f"{'═'*80}")

    header = ["Variant", "Size", "Map Type"] + srv_keys + ["Δ (s)", "Newer server"]
    rows = []
    skipped = 0

    for variant in variants:
        for size in sizes:
            for mtype, _ in map_types:
                label = f"{variant}-{size}-{mtype}"
                latest_per_srv = {}
                for srv in srv_keys:
                    key = (srv, label)
                    if key in results and results[key]:
                        latest_per_srv[srv] = results[key][-1][1]  # last poll LM
                    else:
                        latest_per_srv[srv] = "—"

                # Parse timestamps for servers that responded
                parsed = {}
                for srv in srv_keys:
                    dt = parse_lm(latest_per_srv[srv])
                    if dt:
                        parsed[srv] = dt

                if len(parsed) < 2:
                    skipped += 1
                    continue  # can't compare

                dts = list(parsed.values())
                delta_s = int(abs((dts[0] - dts[1]).total_seconds()))
                newer = max(parsed, key=lambda s: parsed[s])
                older = min(parsed, key=lambda s: parsed[s])
                newer_label = newer if newer != older else "same"

                row = (
                    [variant, size, mtype]
                    + [shorten_lm(latest_per_srv[s]) for s in srv_keys]
                    + [str(delta_s), newer_label]
                )
                rows.append(row)

    if rows:
        print_table(header, rows)
        print(f"\n  Rows shown : {len(rows)}")
        if skipped:
            print(f"  Skipped    : {skipped}  (map type missing on ≥1 server, or no response)")
    else:
        print("  No comparable rows — check server URLs and map type names.")

    # Summary: which server is fresher more often
    if rows:
        from collections import Counter
        newer_counts = Counter(r[-1] for r in rows if r[-1] not in ("same", "—"))
        print("\n  Freshness tally (# maps where server had the newer timestamp):")
        for srv, cnt in newer_counts.most_common():
            print(f"    {srv:<20}  {cnt}")
        same_count = sum(1 for r in rows if r[-1] == "same")
        if same_count:
            print(f"    {'(same timestamp)':<20}  {same_count}")


# ── Per-map-type generation-time summary ─────────────────────────────────────

def generation_time_report(results, servers, map_types, sizes, variants):
    """
    For each (server, map_type) pair, summarise the spread of Last-Modified
    timestamps across all sizes and variants in the most recent round.
    This reveals which map types refresh most frequently / are most stale.
    """
    print(f"\n{'═'*80}")
    print("  MAP-TYPE FRESHNESS SUMMARY  (most recent round, all sizes & variants)")
    print(f"{'═'*80}")

    for srv_key in servers:
        print(f"\n  Server: {srv_key}")
        header = ["Map Type", "Samples", "Oldest LM", "Newest LM", "Spread (s)", "Avg age (min)"]
        rows = []
        now_utc = datetime.now(timezone.utc)

        for mtype, _ in map_types:
            timestamps = []
            for variant in variants:
                for size in sizes:
                    label = f"{variant}-{size}-{mtype}"
                    key = (srv_key, label)
                    if key in results and results[key]:
                        lm_str = results[key][-1][1]
                        dt = parse_lm(lm_str)
                        if dt:
                            timestamps.append(dt)

            if not timestamps:
                rows.append([mtype, "0", "—", "—", "—", "—"])
                continue

            oldest = min(timestamps)
            newest = max(timestamps)
            spread_s = int((newest - oldest).total_seconds())
            ages_min = [(now_utc - t).total_seconds() / 60 for t in timestamps]
            avg_age = sum(ages_min) / len(ages_min)

            rows.append([
                mtype,
                str(len(timestamps)),
                oldest.strftime("%Y-%m-%d %H:%M UTC"),
                newest.strftime("%Y-%m-%d %H:%M UTC"),
                str(spread_s),
                f"{avg_age:.1f}",
            ])

        # Sort by average age descending (stalest first)
        rows.sort(key=lambda r: float(r[5]) if r[5] != "—" else -1, reverse=True)
        print_table(header, rows)


# ── Main polling loop ─────────────────────────────────────────────────────────

def run(rounds: int, interval: int, servers: dict, map_types: list, sizes: list):
    entries = build_entries(servers, map_types, sizes, VARIANTS)
    # results[(srv_key, label)] = [(poll_time_str, last_modified_str), ...]
    results = defaultdict(list)

    total_maps = len(entries)
    print(f"\nHamClock Multi-Server Map Poller")
    print(f"  Servers  : {', '.join(servers.keys())}  ({len(servers)} total)")
    print(f"  Map types: {', '.join(mt for mt, _ in map_types)}")
    print(f"  Sizes    : {len(sizes)}")
    print(f"  Variants : {', '.join(VARIANTS)}")
    print(f"  URLs/round: {total_maps}")
    print(f"  Rounds   : {rounds}")
    print(f"  Interval : {interval}s ({interval/60:.1f} min)")
    print(f"  Started  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S local')}\n")

    for rnd in range(1, rounds + 1):
        round_start = datetime.now()
        print(f"\n{'─'*70}")
        print(f"  Round {rnd}/{rounds}  —  {round_start.strftime('%H:%M:%S')}")
        print(f"{'─'*70}")

        for srv_key, label, url in entries:
            lm = fetch_last_modified(url)
            poll_time = datetime.now().strftime("%H:%M:%S")
            results[(srv_key, label)].append((poll_time, lm))
            ok = "ERROR" not in lm and "TIMEOUT" not in lm and "NO-" not in lm
            status = "✓" if ok else "✗"
            print(f"  {status} [{srv_key}] {label:<30}  {lm}")

        # ── Rolling table: last-modified per round (one row per label×server) ──
        if len(servers) == 1:
            srv_key = list(servers.keys())[0]
            unique_labels = list(dict.fromkeys(lbl for s, lbl, _ in entries if s == srv_key))
            headers = ["Map Label"] + [f"R{i}" for i in range(1, rnd + 1)]
            rows = []
            for label in unique_labels:
                key = (srv_key, label)
                lm_row = [shorten_lm(r[1], 22) for r in results[key]]
                rows.append([label] + lm_row)
            print_table(headers, rows, title=f"Last-Modified — after round {rnd} [{srv_key}]")
        else:
            # Multi-server: show one table per server
            for srv_key in servers:
                unique_labels = list(dict.fromkeys(lbl for s, lbl, _ in entries if s == srv_key))
                headers = ["Map Label"] + [f"R{i}" for i in range(1, rnd + 1)]
                rows = []
                for label in unique_labels:
                    key = (srv_key, label)
                    lm_row = [shorten_lm(r[1], 22) for r in results[key]]
                    rows.append([label] + lm_row)
                print_table(headers, rows, title=f"Last-Modified — after round {rnd} [{srv_key}]")

        if rnd < rounds:
            nxt = time.time() + interval
            print(f"\n  ⏳  Waiting {interval}s … (next at ~{datetime.fromtimestamp(nxt).strftime('%H:%M:%S')})")
            time.sleep(interval)

    # ── FINAL REPORTS ──────────────────────────────────────────────────────────
    print(f"\n{'═'*80}")
    print("  FINAL REPORT")
    print(f"{'═'*80}")

    # 1. Per-server change summary
    for srv_key in servers:
        change_rows = []
        for _, label, _ in [e for e in entries if e[0] == srv_key]:
            observations = [r[1] for r in results[(srv_key, label)]]
            unique_lm = list(dict.fromkeys(observations))
            changes = len(unique_lm) - 1
            change_rows.append((label, changes, unique_lm[0][:22], unique_lm[-1][:22], "; ".join(unique_lm)))

        headers = ["Map Label", "Changes", "First LM", "Last LM"]
        rows = [(r[0], r[1], r[2], r[3]) for r in change_rows]
        print_table(headers, rows, title=f"Change summary [{srv_key}]")

        print(f"\n  Unique LM values per map [{srv_key}]:\n")
        for row in change_rows:
            label, changes, _, _, all_unique = row
            print(f"  {label:<35} ({changes} change{'s' if changes != 1 else ''})")
            for lm in all_unique.split("; "):
                print(f"      → {lm}")

    # 2. Map-type freshness summary (all map types, not just DRAP)
    generation_time_report(results, servers, map_types, sizes, VARIANTS)

    # 3. Cross-server comparison (only meaningful with ≥ 2 servers)
    cross_server_comparison(results, servers, map_types, sizes, VARIANTS)

    print(f"\n  Poll completed at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'═'*80}\n")


# ── CLI ────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Poll HamClock map servers for Last-Modified headers across all map types.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Default: 12 rounds, 5-min interval, all configured servers & map types
  python3 poll_maps.py

  # Quick 3-round test with 60-second interval
  python3 poll_maps.py --rounds 3 --interval 60

  # Poll only DRAP-S and OHB-S at 1320x660
  python3 poll_maps.py --map-types DRAP-S OHB-S --sizes 1320x660

  # Add a second server on the fly (also edit SERVERS dict for permanent config)
  # (use --servers to override which keys from SERVERS dict are active)
  python3 poll_maps.py --servers hamclock
""",
    )
    parser.add_argument("--rounds",    type=int, default=12,  help="Number of polling rounds (default: 12)")
    parser.add_argument("--interval",  type=int, default=300, help="Seconds between rounds (default: 300)")
    parser.add_argument("--servers",   nargs="+", default=None,
                        help="Server keys to use (must exist in SERVERS dict). Default: all.")
    parser.add_argument("--map-types", nargs="+", default=None,
                        help="Map type names to poll (e.g. DRAP-S OHB-S Aurora). Default: all.")
    parser.add_argument("--sizes",     nargs="+", default=None,
                        help="Sizes to poll (e.g. 1320x660 660x330). Default: all.")
    args = parser.parse_args()

    # Resolve servers
    active_servers = {}
    if args.servers:
        for k in args.servers:
            if k not in SERVERS:
                parser.error(f"Unknown server key '{k}'. Available: {list(SERVERS.keys())}")
            active_servers[k] = SERVERS[k]
    else:
        active_servers = dict(SERVERS)

    # Resolve map types
    all_mtype_names = {mt: compressed for mt, compressed in MAP_TYPES}
    if args.map_types:
        active_map_types = []
        for mt in args.map_types:
            if mt not in all_mtype_names:
                print(f"  Warning: map type '{mt}' not in MAP_TYPES list — adding as compressed .bmp.z")
                active_map_types.append((mt, True))
            else:
                active_map_types.append((mt, all_mtype_names[mt]))
    else:
        active_map_types = list(MAP_TYPES)

    # Resolve sizes
    active_sizes = args.sizes if args.sizes else list(SIZES)

    run(
        rounds=args.rounds,
        interval=args.interval,
        servers=active_servers,
        map_types=active_map_types,
        sizes=active_sizes,
    )
