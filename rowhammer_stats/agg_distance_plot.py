#!/usr/bin/env python3
"""
Aggressor-Victim Row Distance Bar Chart  (multi-CSV, per-pattern)

Reads one or more CSV files produced by collector.py, pools all rows
across files and banks, then plots a 2×2 figure with one subplot per data
pattern showing the exact flip count at each aggressor–victim distance:

    distance = |aggressor_row − victim_row|

Usage:
    python agg_distance_plot.py stats1.csv stats2.csv [stats3.csv ...]
                                [--out-dir ./plots]
                                [--no-show]
                                [--patterns A B C D]
"""

import csv
import os
import sys
import argparse
from collections import Counter, defaultdict

DEFAULT_OUT_DIR = "./plots"


# ── Pattern display ───────────────────────────────────────────────────────────
def _fmt_pattern(raw: str) -> str:
    """
    Turn a raw pattern string into a readable hex label.

    Examples
    --------
    '00ff'   → '0x00FF'
    'aa55'   → '0xAA55'
    '00 ff'  → '0x00FF'        (space-separated bytes collapsed)
    'ff 00'  → '0xFF00'
    """
    # Strip spaces and uppercase
    cleaned = raw.replace(' ', '').upper()
    # If it already looks like a plain hex string, prefix with 0x
    try:
        int(cleaned, 16)
        return f'0x{cleaned}'
    except ValueError:
        # Fall back to the raw string if it isn't pure hex
        return raw


# ── Load ──────────────────────────────────────────────────────────────────────
def load_csvs(paths: list[str]) -> list[dict]:
    """Load and merge rows from multiple CSV files."""
    all_rows = []
    for path in paths:
        if not os.path.isfile(path):
            print(f"  Warning: file not found, skipping → {path}")
            continue
        with open(path, newline='') as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                agg = row.get('aggressor_row', '').strip()
                vic = row.get('row', '').strip()
                if not agg or agg.lower() in ('', 'none', 'n/a'):
                    continue
                try:
                    agg_i = int(agg)
                    vic_i = int(vic)
                except ValueError:
                    continue
                all_rows.append({
                    'source':        os.path.basename(path),
                    'bank_id':       row['bank_id'].strip(),
                    'data_pattern':  row['data_pattern'].strip(),
                    'aggressor_row': agg_i,
                    'victim_row':    vic_i,
                    'distance':      abs(agg_i - vic_i),
                })
    return all_rows


# ── Helpers ───────────────────────────────────────────────────────────────────
def _plot_bar(distances: list[int],
              title: str,
              ax,
              color: str = 'steelblue',
              fontsize_labels: int = 10) -> None:
    """Draw an exact-count bar chart onto *ax*."""
    import matplotlib.ticker as ticker
    import bisect

    # Discard outliers beyond distance 15
    distances = [d for d in distances if d <= 15]

    counts = Counter(distances)
    xs = sorted(counts.keys())
    ys = [counts[x] for x in xs]

    print(f"    [{title}] unique distances: {len(xs)}, "
          f"range [{min(xs)}, {max(xs)}], total flips: {len(distances)}")

    # Use contiguous integer positions so bars always render, then relabel
    positions = list(range(len(xs)))
    ax.bar(positions, ys, width=0.8, color=color,
           edgecolor='white', linewidth=0.5)

    mean_d = sum(distances) / len(distances)

    # Interpolate mean position onto the contiguous axis
    if len(xs) > 1:
        idx_left = max(0, min(bisect.bisect_right(xs, mean_d) - 1, len(xs) - 2))
        frac = (mean_d - xs[idx_left]) / (xs[idx_left + 1] - xs[idx_left])
        mean_pos = idx_left + frac
    else:
        mean_pos = 0.0

    ax.axvline(mean_pos, color='darkorange', linewidth=1.4, linestyle='-.',
               label=f'mean = {mean_d:.1f}', zorder=3)
    ax.legend(fontsize=fontsize_labels - 1)

    # Show at most ~12 x-tick labels to avoid crowding
    step = max(1, len(xs) // 12)
    tick_pos    = positions[::step]
    tick_labels = [str(xs[i]) for i in range(0, len(xs), step)]
    ax.set_xticks(tick_pos)
    ax.set_xticklabels(tick_labels, rotation=45, ha='right',
                       fontsize=fontsize_labels - 2)
    ax.tick_params(axis='y', labelsize=fontsize_labels - 2)

    ax.set_xlim(-0.5, len(xs) - 0.5)
    ax.set_ylim(0, max(ys) * 1.15)

    ax.yaxis.set_major_locator(ticker.MaxNLocator(integer=True))

    ax.set_xlabel('|Aggressor Row − Victim Row|', fontsize=fontsize_labels)
    ax.set_ylabel('Count', fontsize=fontsize_labels)
    ax.set_title(title, fontsize=fontsize_labels + 1, fontweight='bold')


def _save_and_show(fig, out_path: str, show: bool) -> None:
    import matplotlib.pyplot as plt
    os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_path, dpi=500, bbox_inches='tight',format="pdf")
    print(f"  Saved → {out_path}")
    if show:
        plt.show()
    plt.close(fig)


# ── Colours for patterns ──────────────────────────────────────────────────────
_PATTERN_COLORS = ['#D4AA7D', '#5B4A8A', '#D4726A', '#9B4A5A']


# ── Main plot ─────────────────────────────────────────────────────────────────
def plot_by_pattern(rows: list[dict],
                    out_dir: str,
                    show: bool,
                    patterns: list[str] | None = None,
                    source_label: str = '') -> None:
    """
    One 2×2 figure, one subplot per data pattern.
    Rows from all banks and all source CSVs are pooled together.
    """
    import matplotlib.pyplot as plt

    by_pattern: dict[str, list[int]] = defaultdict(list)
    for r in rows:
        by_pattern[r['data_pattern']].append(r['distance'])

    if patterns is None:
        patterns = sorted(by_pattern.keys())

    print(f"  Patterns found: {patterns}")

    ncols, nrows = 2, 2
    fig, axes = plt.subplots(nrows, ncols,
                             figsize=(14, 10),
                             squeeze=False)

    # suptitle = "Aggressor–Victim Distance by Data Pattern"
    # if source_label:
    #     suptitle += f"\n{source_label}"
    # fig.suptitle(suptitle, fontsize=14, fontweight='bold', y=1.02)

    for idx, pattern in enumerate(patterns[:4]):
        ax    = axes[idx // ncols][idx % ncols]
        color = _PATTERN_COLORS[idx % len(_PATTERN_COLORS)]
        dists = by_pattern.get(pattern, [])

        if not dists:
            print(f"  Warning: no data for pattern '{pattern}', hiding subplot.")
            ax.set_visible(False)
            continue

        _plot_bar(dists,
                  title=f"Pattern: {_fmt_pattern(pattern)}",
                  ax=ax,
                  color=color,
                  fontsize_labels=20)

    for idx in range(len(patterns), nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    _save_and_show(fig,
                   os.path.join(out_dir, "distance_by_pattern.pdf"),
                   show)


# ── CLI ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='Plot aggressor–victim row distance bar charts per data pattern.'
    )
    parser.add_argument('input_csvs',
                        nargs='+',
                        metavar='CSV',
                        help='One or more CSV files produced by collector.py')
    parser.add_argument('--out-dir', default=DEFAULT_OUT_DIR, metavar='DIR',
                        help=f'Directory for saved plots (default: {DEFAULT_OUT_DIR})')
    parser.add_argument('--no-show', action='store_true',
                        help='Save plots without displaying them interactively')
    parser.add_argument('--patterns', nargs='+', metavar='PAT',
                        default=None,
                        help='Explicit list of up to 4 pattern names to plot '
                             '(default: auto-discover from data, alphabetical)')
    args = parser.parse_args()

    # Backend MUST be set before pyplot is imported anywhere in the process
    if args.no_show:
        import matplotlib
        matplotlib.use('Agg')

    print(f"Loading {len(args.input_csvs)} CSV file(s) ...")
    rows = load_csvs(args.input_csvs)

    if not rows:
        print("No rows with valid aggressor_row found across all inputs. Nothing to plot.")
        sys.exit(0)

    n_banks    = len({r['bank_id']      for r in rows})
    n_patterns = len({r['data_pattern'] for r in rows})
    # n_sources  = len({r['source']       for r in rows})
    # print(f"  {len(rows)} flip(s) loaded from {n_sources} file(s), "
    #       f"{n_banks} bank(s), {n_patterns} pattern(s)\n")

    # source_label = (f"Sources: {', '.join(sorted({r['source'] for r in rows}))}"
    #                 if n_sources > 1 else
    #                 f"Source: {rows[0]['source']}")

    show = not args.no_show

    print("Plotting distance figure (all banks collated, per pattern) ...")
    plot_by_pattern(rows, args.out_dir, show,
                    patterns=args.patterns)

    print("\nDone.")


if __name__ == '__main__':
    main()