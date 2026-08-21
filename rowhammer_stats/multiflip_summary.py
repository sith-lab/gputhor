#!/usr/bin/env python3
"""
Double-Flip Summary

Reads the CSV produced by collector.py (--csv flag) and prints, for each
bank and granularity, the number of double-flip chunks (exactly 2 distinct
flipped bytes in the same aligned window) and how many of those are "true"
double-flips (is_real=True, i.e. both bytes flipped in the same hammering
round).

Reconstructs the per-bank event data from the CSV and runs it through
analyse_bank() (multiflip_collector.py) — the same chunk-analysis logic
used to build multiflip_collector.py's own report.

Usage:
    python multiflip_summary.py <collector.csv> [--granularities 8 16 32 64]
                                                 [--csv summary.csv]
"""

import csv
import sys
import os
import argparse
from collections import defaultdict

# ── Import shared data structures / analysis ───────────────────────────────────
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from collector import BankPatternStats, BitFlipEvent, BitFlip
from multiflip_collector import analyse_bank, BankMultiFlipStats

DEFAULT_GRANULARITIES = [8, 16, 32, 64]


# ── Load ──────────────────────────────────────────────────────────────────────
def load_csv(path: str) -> list[dict]:
    with open(path, newline='') as fh:
        reader = csv.DictReader(fh)
        rows = []
        for row in reader:
            rows.append({
                'bank_id':        row['bank_id'].strip(),
                'data_pattern':   row['data_pattern'].strip(),
                'rows_hammered':  int(row.get('rows_hammered', 0)),
                'row':            int(row['row']),
                'byte_in_row':    int(row['byte_in_row']),
                'address':        int(row['address'], 16),
                'offset':         int(row['offset'], 16),
                'bit_position':   int(row['bit_position']),
                'from_bit':       int(row['from_bit']),
                'to_bit':         int(row['to_bit']),
                'pattern_before': row['pattern_before'],
                'pattern_after':  row['pattern_after'],
                'aggressor_row':  int(row['aggressor_row']) if row.get('aggressor_row') else None,
                'round_id':       int(row['round_id']) if row.get('round_id') else 0,
                'source_file':    row['source_file'],
            })
    return rows


def build_pattern_stats(rows: list[dict]) -> dict[tuple, BankPatternStats]:
    """
    Rebuild BankPatternStats keyed by (bank_id, data_pattern) from CSV rows.
    Each CSV row is already one deduplicated bit-flip (collector.py's
    BankPatternStats.add_event dedups before exporting), so rows are
    reconstructed one-flip-per-event rather than re-running dedup.
    """
    stats: dict[tuple, BankPatternStats] = {}

    for row in rows:
        key = (row['bank_id'], row['data_pattern'])
        if key not in stats:
            stats[key] = BankPatternStats(bank_id=row['bank_id'], data_pattern=row['data_pattern'])
            stats[key].rows_hammered = row['rows_hammered']

        flip = BitFlip(
            bit_position = row['bit_position'],
            from_bit     = row['from_bit'],
            to_bit       = row['to_bit'],
        )
        stats[key].events.append(BitFlipEvent(
            row            = row['row'],
            byte_in_row    = row['byte_in_row'],
            address        = row['address'],
            offset         = row['offset'],
            pattern_before = row['pattern_before'],
            pattern_after  = row['pattern_after'],
            flips          = [flip],
            source_file    = row['source_file'],
            round_id       = row['round_id'],
            aggressor_row  = row['aggressor_row'],
        ))

    return stats


# ── Summarise ─────────────────────────────────────────────────────────────────
def summarise(bank_results: list[BankMultiFlipStats],
              granularities: list[int]) -> dict[tuple, dict]:
    """
    Returns a dict keyed by (bank_id, granularity) with values:
        { 'double': int, 'true_double': int }
    Only chunks with exactly 2 flipped bytes are counted as double-flips.
    """
    summary: dict[tuple, dict] = defaultdict(lambda: {'double': 0, 'true_double': 0})

    for bmf in bank_results:
        for gran in granularities:
            for h in bmf.hits.get(gran, []):
                if h.n_bytes != 2:
                    continue
                key = (bmf.bank_id, gran)
                summary[key]['double'] += 1
                if h.is_real:
                    summary[key]['true_double'] += 1

    return summary


# ── Report ────────────────────────────────────────────────────────────────────
def print_report(summary: dict[tuple, dict], granularities: list[int]) -> None:
    # Collect all bank ids present
    banks = sorted({k[0] for k in summary}, key=lambda x: (x.isdigit(), int(x) if x.isdigit() else x))
    if not banks:
        print("No double-flip entries found for the requested granularities.")
        return

    print("\n" + "=" * 72)
    print("  DOUBLE-FLIP SUMMARY  (chunks with exactly 2 flipped bytes)")
    print("=" * 72)

    # ── Per-granularity tables ────────────────────────────────────────────
    for gran in granularities:
        print(f"\n  Granularity: {gran} bytes")
        print(f"  {'Bank':>6}  {'Double Flips':>14}  {'True Double Flips':>18}  {'True %':>8}")
        print(f"  {'─'*6}  {'─'*14}  {'─'*18}  {'─'*8}")

        any_data = False
        for bank in banks:
            key  = (bank, gran)
            d    = summary.get(key, {'double': 0, 'true_double': 0})
            total = d['double']
            true  = d['true_double']
            pct   = f"{100*true/total:.1f}%" if total > 0 else "—"
            print(f"  {bank:>6}  {total:>14}  {true:>18}  {pct:>8}")
            if total > 0:
                any_data = True

        if not any_data:
            print(f"  (no double-flip chunks at {gran}B granularity)")

    # ── Cross-granularity totals per bank ────────────────────────────────
    print(f"\n{'─'*72}")
    print("  TOTALS ACROSS ALL GRANULARITIES")
    print(f"{'─'*72}")
    print(f"  {'Bank':>6}  {'Granularity':>12}  {'Double':>8}  {'True':>8}  {'True %':>8}")
    print(f"  {'─'*6}  {'─'*12}  {'─'*8}  {'─'*8}  {'─'*8}")

    for bank in banks:
        bank_total = bank_true = 0
        for gran in granularities:
            key = (bank, gran)
            d   = summary.get(key, {'double': 0, 'true_double': 0})
            bank_total += d['double']
            bank_true  += d['true_double']
        pct = f"{100*bank_true/bank_total:.1f}%" if bank_total > 0 else "—"
        print(f"  {bank:>6}  {'all':>12}  {bank_total:>8}  {bank_true:>8}  {pct:>8}")

    print("\n" + "=" * 72 + "\n")


# ── CSV export ────────────────────────────────────────────────────────────────
def export_summary_csv(summary: dict[tuple, dict],
                       granularities: list[int],
                       out_path: str) -> None:
    banks = sorted({k[0] for k in summary})
    rows  = []
    for bank in banks:
        for gran in granularities:
            key   = (bank, gran)
            d     = summary.get(key, {'double': 0, 'true_double': 0})
            total = d['double']
            true  = d['true_double']
            rows.append({
                'bank_id':          bank,
                'granularity':      gran,
                'double_flips':     total,
                'true_double_flips': true,
                'true_pct':         round(100 * true / total, 2) if total > 0 else 0.0,
            })

    if not rows:
        print("Nothing to export.")
        return

    with open(out_path, 'w', newline='') as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Summary CSV exported → {out_path}  ({len(rows)} rows)")


# ── CLI ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='Summarise double-flip counts per bank from collector CSV.'
    )
    parser.add_argument(
        'input_csv',
        help='CSV file produced by collector.py --csv'
    )
    parser.add_argument(
        '--granularities', '-g',
        nargs='+',
        type=int,
        default=DEFAULT_GRANULARITIES,
        metavar='N',
        help=f'Granularities to include (default: {DEFAULT_GRANULARITIES})'
    )
    parser.add_argument(
        '--csv',
        metavar='SUMMARY.csv',
        help='Export the summary table to a CSV file'
    )
    args = parser.parse_args()

    # Validate granularities
    for g in args.granularities:
        if g <= 0 or (g & (g - 1)) != 0:
            parser.error(f"Granularity must be a power of 2, got: {g}")

    if not os.path.isfile(args.input_csv):
        print(f"Error: file not found: {args.input_csv}")
        sys.exit(1)

    rows = load_csv(args.input_csv)
    pattern_stats = build_pattern_stats(rows)

    # Group BankPatternStats by bank_id
    by_bank: dict[str, list[BankPatternStats]] = defaultdict(list)
    for bps in pattern_stats.values():
        by_bank[bps.bank_id].append(bps)

    bank_results = [
        analyse_bank(bank_id, patterns, args.granularities)
        for bank_id, patterns in sorted(by_bank.items(), key=lambda x: (x[0].isdigit(), int(x[0]) if x[0].isdigit() else x[0]))
    ]

    summary = summarise(bank_results, args.granularities)
    print_report(summary, args.granularities)

    if args.csv:
        export_summary_csv(summary, args.granularities, args.csv)


if __name__ == '__main__':
    main()
