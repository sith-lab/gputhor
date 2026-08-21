#!/usr/bin/env python3
"""
Rowhammer Stats Summary

Reads the CSV produced by collector.py (--csv flag) and prints:
  - Per bank x pattern: bit-flip count and average bit-flips per hammered row
  - Per bank: total bit-flips across all patterns and combined average
  - Grand total across all banks

"Average bit-flips per row" uses the total rows hammered (last_aggressor -
first_aggressor + 1), not just the rows that experienced flips.

Usage:
    python flip_summary.py <collector.csv> [--csv summary.csv]
"""

import csv
import sys
import os
import argparse
from collections import defaultdict


# -- Load ---------------------------------------------------------------------
def load_csv(path: str) -> list[dict]:
    with open(path, newline='') as fh:
        reader = csv.DictReader(fh)
        rows = []
        for row in reader:
            rows.append({
                'bank_id':       row['bank_id'].strip(),
                'data_pattern':  row['data_pattern'].strip(),
                'rows_hammered': int(row.get('rows_hammered', 0)),
                'row':           int(row['row']),
                'offset':        row['offset'].strip(),
                'bit_position':  int(row['bit_position']),
                'to_bit':        int(row['to_bit']),
            })
    return rows


# -- Summarise ----------------------------------------------------------------
def summarise(rows: list[dict]) -> dict:
    """
    Returns:
      {
        bank_id: {
          'total_flips': int,
          'patterns': {
            pattern: {
              'flips': int,
              'rows_hammered': int,   # constant per (bank, pattern)
            }
          }
        }
      }
    rows_hammered is the same for every flip row of the same (bank, pattern),
    so we record it once on first encounter.
    """
    summary: dict = defaultdict(lambda: {
        'unique_flips': set(),   # (offset, bit_position, to_bit) across all patterns
        'patterns': defaultdict(lambda: {'flips': 0, 'rows_hammered': 0})
    })
    seen_hammered: set = set()

    for row in rows:
        bank    = row['bank_id']
        pattern = row['data_pattern']
        key     = (bank, pattern)
        flip_key = (row['offset'], row['bit_position'], row['to_bit'])

        summary[bank]['unique_flips'].add(flip_key)
        summary[bank]['patterns'][pattern]['flips'] += 1

        if key not in seen_hammered:
            seen_hammered.add(key)
            summary[bank]['patterns'][pattern]['rows_hammered'] = row['rows_hammered']

    return summary


# -- Cross-bank stats ----------------------------------------------------------
ROW_BYTES        = 2048            # bytes per hammered row
ROW_TIME_MS       = 5 * 64        # ms to hammer one row (10 refresh intervals @ 64ms)
BEST_PATTERN      = '00ff'
FULL_BANK_ROWS    = 64000         # rows per bank in a full (non-reduced) campaign


def compute_global_stats(summary: dict) -> dict:
    banks = list(summary.keys())
    num_banks = len(banks)

    bank_avgs = []
    bank_rows_list = []
    for bank in banks:
        bank_data    = summary[bank]
        bank_unique  = len(bank_data['unique_flips'])
        bank_rows    = max((pd['rows_hammered'] for pd in bank_data['patterns'].values()), default=0)
        if bank_rows > 0:
            bank_avgs.append(bank_unique / bank_rows)
            bank_rows_list.append(bank_rows)

    grand_unique     = sum(len(summary[b]['unique_flips']) for b in banks)
    avg_flip_per_row = sum(bank_avgs) / len(bank_avgs) if bank_avgs else 0.0
    avg_flip_per_bank = grand_unique / num_banks if num_banks else 0.0
    avg_flip_per_gb   = avg_flip_per_row * (1024 ** 3 / ROW_BYTES)
    avg_rows_per_bank = sum(bank_rows_list) / len(bank_rows_list) if bank_rows_list else 0.0

    best_flips = 0
    best_rows_hammered = 0
    for bank in banks:
        pd = summary[bank]['patterns'].get(BEST_PATTERN)
        if pd:
            best_flips          += pd['flips']
            best_rows_hammered  += pd['rows_hammered']
    best_time_hours = (best_rows_hammered * ROW_TIME_MS) / (1000 * 3600)
    flips_per_hour_best = best_flips / best_time_hours if best_time_hours > 0 else 0.0

    # Extrapolate the reduced run up to a full bank (FULL_BANK_ROWS rows). The
    # measured per-row flip rate is scale-invariant, so we project it onto a full
    # bank to estimate the totals a non-reduced campaign would report.
    est_flip_per_bank        = avg_flip_per_row * FULL_BANK_ROWS
    est_total_unique_flips   = est_flip_per_bank * num_banks

    return {
        'total_unique_flips':      grand_unique,
        'avg_rows_per_bank':       avg_rows_per_bank,
        'avg_flip_per_row':        avg_flip_per_row,
        'avg_flip_per_bank':       avg_flip_per_bank,
        'avg_flip_per_gb':         avg_flip_per_gb,
        'flips_per_hour_best':     flips_per_hour_best,
        'best_pattern_flips':      best_flips,
        'best_rows_hammered':      best_rows_hammered,
        'est_total_unique_flips':  est_total_unique_flips,
        'est_flip_per_bank':       est_flip_per_bank,
    }


# -- Report -------------------------------------------------------------------
def print_report(summary: dict) -> None:
    banks = sorted(summary.keys(), key=lambda x: (x.isdigit(), int(x) if x.isdigit() else x))
    if not banks:
        print("No data found in CSV.")
        return

    print("\n" + "=" * 68)
    print("  ROWHAMMER BIT-FLIP SUMMARY")
    print("=" * 68)

    grand_total = 0

    for bank in banks:
        bank_data    = summary[bank]
        patterns     = bank_data['patterns']
        bank_unique  = len(bank_data['unique_flips'])
        grand_total += bank_unique

        print(f"\n{'─'*68}")
        print(f"  BANK {bank}  --  {bank_unique} unique bit-flip(s) across "
              f"{len(patterns)} pattern(s)")
        print(f"{'─'*68}")

        print(f"\n  {'Pattern':>12}  {'Flips':>8}  {'RowsHammered':>13}  {'Flips/Row':>10}")
        print(f"  {'─'*12}  {'─'*8}  {'─'*13}  {'─'*10}")

        for pattern in sorted(patterns.keys()):
            pd            = patterns[pattern]
            flips         = pd['flips']
            rows_hammered = pd['rows_hammered']
            bank_rows_hammered = rows_hammered
            flips_per_row = flips / rows_hammered if rows_hammered > 0 else 0.0
            print(f"  {pattern:>12}  {flips:>8}  {rows_hammered:>13}  {flips_per_row:>10.4f}")

        bank_avg = bank_unique / bank_rows_hammered if bank_rows_hammered > 0 else 0.0
        print(f"\n  {'(all patterns)':>12}  {bank_unique:>8}  "
              f"{bank_rows_hammered:>13}  {bank_avg:>10.4f}")

    grand_unique = sum(len(summary[b]['unique_flips']) for b in banks)
    print(f"\n{'─'*68}")
    print(f"  GRAND TOTAL: {grand_unique} unique bit-flip(s) across {len(banks)} bank(s)")
    print("=" * 68)

    stats = compute_global_stats(summary)
    rows_label = f"Total unique flips ({stats['avg_rows_per_bank']:g} rows / bank)"
    print("\n  WARNING: This run uses a reduced set, so the total unique flips")
    print("        reported here are not expected to match the full campaign.")
    print("\n  ACROSS ALL BANKS")
    print(f"  {'─'*68}")
    print(f"  {rows_label:<45} {stats['total_unique_flips']:>15}")
    print(f"  {'Average flip per row':<45} {stats['avg_flip_per_row']:>15.4f}")
    print(f"  {'Average flip per bank':<45} {stats['avg_flip_per_bank']:>15.4f}")
    print(f"  {'Average flip per GB':<45} {stats['avg_flip_per_gb']:>15.4f}")
    print(f"  {'Flip/Hour (Best Pattern: ' + BEST_PATTERN + ')':<45} "
          f"{stats['flips_per_hour_best']:>15.4f}")
    est_bank_label = f"Est. total unique flips ({FULL_BANK_ROWS} rows / bank)"
    print(f"\n  ESTIMATED FULL BANK ({FULL_BANK_ROWS} rows / bank)")
    print(f"  {'─'*68}")
    print(f"  {est_bank_label:<45} {stats['est_total_unique_flips']:>15.1f}")
    print(f"  {'Est. flip per bank':<45} {stats['est_flip_per_bank']:>15.1f}")
    print("=" * 68 + "\n")


# -- CSV export ---------------------------------------------------------------
def export_summary_csv(summary: dict, out_path: str) -> None:
    rows = []
    for bank in sorted(summary.keys(), key=lambda x: (x.isdigit(), int(x) if x.isdigit() else x)):
        bank_data = summary[bank]
        patterns  = bank_data['patterns']

        bank_rows_hammered = 0
        for pattern in sorted(patterns.keys()):
            pd            = patterns[pattern]
            flips         = pd['flips']
            rows_hammered = pd['rows_hammered']
            bank_rows_hammered = rows_hammered
            rows.append({
                'bank_id':        bank,
                'data_pattern':   pattern,
                'bit_flips':      flips,
                'rows_hammered':  rows_hammered,
                'flips_per_row':  round(flips / rows_hammered, 4) if rows_hammered > 0 else 0.0,
            })

        bank_unique = len(bank_data['unique_flips'])
        rows.append({
            'bank_id':        bank,
            'data_pattern':   'ALL',
            'bit_flips':      bank_unique,
            'rows_hammered':  bank_rows_hammered,
            'flips_per_row':  round(bank_unique / bank_rows_hammered, 4)
                              if bank_rows_hammered > 0 else 0.0,
        })

    if not rows:
        print("Nothing to export.")
        return

    fieldnames = list(rows[0].keys())
    with open(out_path, 'w', newline='') as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

        stats = compute_global_stats(summary)
        writer.writerow({})
        writer.writerow({fieldnames[0]: 'ACROSS_ALL_BANKS'})
        for label, value in [
            ('total_unique_flips',                    stats['total_unique_flips']),
            ('avg_rows_per_bank',                     round(stats['avg_rows_per_bank'], 4)),
            ('avg_flip_per_row',                      round(stats['avg_flip_per_row'], 4)),
            ('avg_flip_per_bank',                      round(stats['avg_flip_per_bank'], 4)),
            ('avg_flip_per_gb',                        round(stats['avg_flip_per_gb'], 4)),
            (f'flips_per_hour_best_{BEST_PATTERN}',    round(stats['flips_per_hour_best'], 4)),
            (f'est_total_unique_flips_{FULL_BANK_ROWS}rows', round(stats['est_total_unique_flips'], 1)),
            ('est_flip_per_bank',                      round(stats['est_flip_per_bank'], 1)),
        ]:
            writer.writerow({fieldnames[0]: label, fieldnames[1]: value})

    print(f"Summary CSV exported -> {out_path}  ({len(rows)} rows)")


# -- CLI ----------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description='Summarise bit-flip counts per bank/pattern from collector CSV.'
    )
    parser.add_argument(
        'input_csv',
        help='CSV file produced by collector.py --csv'
    )
    parser.add_argument(
        '--csv',
        metavar='SUMMARY.csv',
        help='Export the summary table to a CSV file'
    )
    args = parser.parse_args()

    if not os.path.isfile(args.input_csv):
        print(f"Error: file not found: {args.input_csv}")
        sys.exit(1)

    rows    = load_csv(args.input_csv)
    summary = summarise(rows)
    print_report(summary)

    if args.csv:
        export_summary_csv(summary, args.csv)


if __name__ == '__main__':
    main()