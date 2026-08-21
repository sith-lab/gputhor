#!/usr/bin/env python3
"""
Rowhammer Bit-Flip Statistics Collector

Parses log files named like "24agg_b4_55aa.log" and collects bit-flip
statistics organized by bank ID and data pattern.

Bit-flip direction (0→1 or 1→0) and the positions of flipped bits are
derived exclusively from the "Data Pattern: 0xAA -> 0xBB" field by
XOR-ing before and after byte values.
"""

import re
import os
import glob
import argparse
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional


# ── Regex patterns ────────────────────────────────────────────────────────────
RE_FILENAME  = re.compile(r'.*_b([0-9a-zA-Z]+)_([0-9a-fA-F]+)(?:_[a-zA-Z0-9]+)*\.log$')
RE_BASE_ADDR = re.compile(r'Layout address:\s*(0x[0-9a-fA-F]+)')
RE_BITFLIP   = re.compile(
    r'Observed\s+(\d+)\s+bit-flip\(s\)\s+in\s+Row\s+(\d+),\s+Byte\s+(\d+),\s+Address\s+(0x[0-9a-fA-F]+)'
)
RE_PATTERN   = re.compile(
    r'Data Pattern:\s*(0x[0-9a-fA-F]+)\s*->\s*(0x[0-9a-fA-F]+)'
)
RE_ROUND_SEP = re.compile(r'={10,}')   # separates hammering rounds
RE_AGGRESSOR = re.compile(r'Chosen Critical Aggressor:\s*(\d+)')


# ── Helpers ───────────────────────────────────────────────────────────────────
@dataclass
class BitFlip:
    """A single bit that changed within one corrupted byte."""
    bit_position: int   # 0 = LSB
    from_bit: int       # original value (0 or 1)
    to_bit: int         # observed value (0 or 1)


def decode_flips(before: int, after: int) -> list[BitFlip]:
    """
    XOR before and after byte values to find every bit that flipped.
    Returns one BitFlip per differing bit; direction is read from `before`.
    """
    xor = before ^ after
    flips = []
    for bit in range(8):
        if xor & (1 << bit):
            from_bit = (before >> bit) & 1
            to_bit   = (after  >> bit) & 1
            flips.append(BitFlip(bit_position=bit, from_bit=from_bit, to_bit=to_bit))
    return flips


# ── Data structures ───────────────────────────────────────────────────────────
@dataclass
class BitFlipEvent:
    row: int
    byte_in_row: int
    address: int
    offset: int             # address - base_address
    pattern_before: str     # e.g. "0x55"
    pattern_after: str      # e.g. "0x75"
    flips: list[BitFlip]    # one entry per bit that changed (usually 1)
    source_file: str
    round_id: int = 0       # hammering round index within the file (0-based)
    aggressor_row: Optional[int] = None  # Chosen Critical Aggressor row for this flip


@dataclass
class BankPatternStats:
    bank_id: str
    data_pattern: str
    events: list = field(default_factory=list)
    rows_hammered: int = 0              # last_aggressor - first_aggressor + 1, summed across files
    # dedup key: (offset, bit_position, from_bit, to_bit)
    _seen: set = field(default_factory=set, repr=False, compare=False)

    def add_event(self, event: 'BitFlipEvent') -> tuple[int, int]:
        """
        Add an event, silently dropping any individual BitFlip entries that
        are duplicates of one already recorded (same offset + bit + direction).
        Returns (n_added, n_dropped).
        """
        unique_flips = []
        for f in event.flips:
            key = (event.offset, f.bit_position, f.from_bit, f.to_bit)
            if key not in self._seen:
                self._seen.add(key)
                unique_flips.append(f)

        n_dropped = len(event.flips) - len(unique_flips)
        if unique_flips:
            deduped = BitFlipEvent(
                row            = event.row,
                byte_in_row    = event.byte_in_row,
                address        = event.address,
                offset         = event.offset,
                pattern_before = event.pattern_before,
                pattern_after  = event.pattern_after,
                flips          = unique_flips,
                source_file    = event.source_file,
                round_id       = event.round_id,
                aggressor_row  = event.aggressor_row,
            )
            self.events.append(deduped)

        return len(unique_flips), n_dropped

    # ── derived ──────────────────────────────────────────────────────────
    @property
    def total_flips(self) -> int:
        """Total number of individual bit-flips across all events."""
        return sum(len(e.flips) for e in self.events)

    @property
    def unique_offsets(self) -> set:
        return {e.offset for e in self.events}

    @property
    def flips_per_row(self) -> dict:
        d: dict = defaultdict(int)
        for e in self.events:
            d[e.row] += len(e.flips)
        return dict(d)

    @property
    def flip_directions(self) -> dict:
        """Count 0→1 and 1→0 flips across all events."""
        d = {"0_to_1": 0, "1_to_0": 0}
        for e in self.events:
            for f in e.flips:
                if f.from_bit == 0 and f.to_bit == 1:
                    d["0_to_1"] += 1
                elif f.from_bit == 1 and f.to_bit == 0:
                    d["1_to_0"] += 1
        return d


# ── Parser ────────────────────────────────────────────────────────────────────
def parse_log_file(filepath: str) -> list[BitFlipEvent]:
    """Parse a single log file and return a list of BitFlipEvents."""
    filename = os.path.basename(filepath)
    m = RE_FILENAME.match(filename)
    if not m:
        print(f"  [SKIP] Filename doesn't match expected pattern: {filename}")
        return []

    base_address: Optional[int] = None
    events: list[BitFlipEvent] = []
    pending_flip: Optional[dict] = None   # holds Row/Byte/Address until pattern line
    round_id: int = 0                     # increments on each ===== separator
    aggressor_row: Optional[int] = None   # current Chosen Critical Aggressor row
    first_aggressor: Optional[int] = None # first aggressor seen in this file
    last_aggressor:  Optional[int] = None # last aggressor seen in this file

    with open(filepath, 'r', errors='replace') as fh:
        for line in fh:
            line = line.rstrip()

            # Round separator — increment before processing any following flips
            if RE_ROUND_SEP.search(line):
                round_id += 1
                pending_flip = None   # discard any flip header orphaned by separator
                continue

            # Base address (grab even after first find in case of multiple)
            bm = RE_BASE_ADDR.search(line)
            if bm:
                base_address = int(bm.group(1), 16)
                continue

            # Chosen Critical Aggressor — stays in effect until next occurrence
            am = RE_AGGRESSOR.search(line)
            if am:
                aggressor_row = int(am.group(1))
                if first_aggressor is None:
                    first_aggressor = aggressor_row
                last_aggressor = aggressor_row
                continue

            # Bit-flip header line: "Observed N bit-flip(s) in Row R, Byte B, Address A"
            fm = RE_BITFLIP.search(line)
            if fm:
                pending_flip = {
                    'row':          int(fm.group(2)),
                    'byte':         int(fm.group(3)),
                    'address':      int(fm.group(4), 16),
                    'round_id':     round_id,
                    'aggressor_row': aggressor_row,
                }
                continue

            # Detail line containing the data pattern transition
            pm = RE_PATTERN.search(line)
            if pm and pending_flip is not None:
                if base_address is None:
                    print(f"  [WARN] No base address found before bit-flip in {filename}")
                    pending_flip = None
                    continue

                before_val = int(pm.group(1), 16)
                after_val  = int(pm.group(2), 16)
                flips      = decode_flips(before_val, after_val)

                if not flips:
                    print(f"  [WARN] Pattern {pm.group(1)}->{pm.group(2)} shows no bit difference — skipping")
                    pending_flip = None
                    continue

                offset = pending_flip['address'] - base_address
                events.append(BitFlipEvent(
                    row            = pending_flip['row'],
                    byte_in_row    = pending_flip['byte'],
                    address        = pending_flip['address'],
                    offset         = offset,
                    pattern_before = pm.group(1),
                    pattern_after  = pm.group(2),
                    flips          = flips,
                    source_file    = filename,
                    round_id       = pending_flip['round_id'],
                    aggressor_row  = pending_flip['aggressor_row'],
                ))
                pending_flip = None

    if first_aggressor is not None and last_aggressor is not None:
        rows_hammered = last_aggressor - first_aggressor + 1
    else:
        rows_hammered = 0
    return events, rows_hammered


# ── Collector ─────────────────────────────────────────────────────────────────
def collect_stats(folder: str) -> dict[tuple, BankPatternStats]:
    """
    Walk *folder* for matching .log files and return a dict keyed by
    (bank_id, data_pattern) → BankPatternStats.
    """
    pattern = os.path.join(folder, '**', '*.log')
    log_files = glob.glob(pattern, recursive=True)

    if not log_files:
        print(f"No .log files found under: {folder}")
        return {}

    stats: dict[tuple, BankPatternStats] = {}

    for filepath in sorted(log_files):
        filename = os.path.basename(filepath)
        m = RE_FILENAME.match(filename)
        if not m:
            continue

        bank_id      = m.group(1)
        data_pattern = m.group(2).lower()
        key          = (bank_id, data_pattern)

        print(f"  Parsing {filename}  (bank={bank_id}, pattern={data_pattern})")
        events, rows_hammered = parse_log_file(filepath)

        if key not in stats:
            stats[key] = BankPatternStats(bank_id=bank_id, data_pattern=data_pattern)
            stats[key].rows_hammered = rows_hammered   # record once; all files assumed equal


        total_added = total_dropped = 0
        for event in events:
            added, dropped = stats[key].add_event(event)
            total_added   += added
            total_dropped += dropped

        msg = f"    → {total_added} bit-flip(s) added, {rows_hammered} rows hammered"
        if total_dropped:
            msg += f", {total_dropped} duplicate(s) ignored"
        print(msg)

    return stats


# ── Report ────────────────────────────────────────────────────────────────────
def print_report(stats: dict[tuple, BankPatternStats]) -> None:
    if not stats:
        print("No statistics to report.")
        return

    # Group by bank for a nicer layout
    by_bank: dict[int, list[BankPatternStats]] = defaultdict(list)
    for bps in stats.values():
        by_bank[bps.bank_id].append(bps)

    print("\n" + "=" * 70)
    print("  ROWHAMMER BIT-FLIP STATISTICS")
    print("=" * 70)

    for bank_id in sorted(by_bank, key=lambda x: (x.isdigit(), int(x) if x.isdigit() else x)):
        print(f"\n{'─'*70}")
        print(f"  BANK {bank_id}")
        print(f"{'─'*70}")

        for bps in sorted(by_bank[bank_id], key=lambda x: x.data_pattern):
            dirs  = bps.flip_directions
            print(f"\n  Data Pattern : {bps.data_pattern}")
            print(f"  Total flips  : {bps.total_flips}")
            print(f"  Unique offsets (bytes): {len(bps.unique_offsets)}")
            print(f"  Flip directions: 0→1 = {dirs['0_to_1']},  1→0 = {dirs['1_to_0']}")

            fpr = bps.flips_per_row
            if fpr:
                top_rows = sorted(fpr.items(), key=lambda x: -x[1])[:5]
                top_str  = ", ".join(f"Row{r}×{c}" for r, c in top_rows)
                print(f"  Top rows (up to 5)  : {top_str}")

            # Per-flip detail table (one row per individual bit-flip)
            if bps.events:
                print(f"\n  {'Offset':>14}  {'Row':>6}  {'Agg':>6}  {'Byte':>6}  {'Bit':>4}  "
                      f"{'Dir':>5}  {'PatBefore':>10}  {'PatAfter':>10}  Source")
                print(f"  {'─'*14}  {'─'*6}  {'─'*6}  {'─'*6}  {'─'*4}  "
                      f"{'─'*5}  {'─'*10}  {'─'*10}  {'─'*20}")
                for e in sorted(bps.events, key=lambda x: x.offset):
                    agg_str = str(e.aggressor_row) if e.aggressor_row is not None else 'N/A'
                    for f in e.flips:
                        direction = f"{f.from_bit}→{f.to_bit}"
                        print(f"  {e.offset:#016x}  {e.row:>6}  {agg_str:>6}  {e.byte_in_row:>6}  "
                              f"{f.bit_position:>4}  {direction:>5}  "
                              f"{e.pattern_before:>10}  "
                              f"{e.pattern_after:>10}  {e.source_file}")

    print("\n" + "=" * 70)
    print(f"  SUMMARY: {len(stats)} (bank, pattern) combinations parsed")
    total = sum(s.total_flips for s in stats.values())
    print(f"  TOTAL BIT-FLIPS across all banks/patterns: {total}")
    print("=" * 70 + "\n")


# ── CSV export ────────────────────────────────────────────────────────────────
def export_csv(stats: dict[tuple, BankPatternStats], out_path: str) -> None:
    import csv
    rows = []
    for bps in stats.values():
        for e in bps.events:
            for f in e.flips:
                rows.append({
                    'bank_id':        bps.bank_id,
                    'data_pattern':   bps.data_pattern,
                    'rows_hammered':  bps.rows_hammered,
                    'row':            e.row,
                    'byte_in_row':    e.byte_in_row,
                    'address':        hex(e.address),
                    'offset':         hex(e.offset),
                    'bit_position':   f.bit_position,
                    'from_bit':       f.from_bit,
                    'to_bit':         f.to_bit,
                    'pattern_before': e.pattern_before,
                    'pattern_after':  e.pattern_after,
                    'aggressor_row':  e.aggressor_row,
                    'round_id':       e.round_id,
                    'source_file':    e.source_file,
                })

    if not rows:
        print("No data to export.")
        return

    fieldnames = list(rows[0].keys())
    with open(out_path, 'w', newline='') as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"CSV exported → {out_path}  ({len(rows)} rows)")


# ── CLI ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='Collect Rowhammer bit-flip statistics from log files.'
    )
    parser.add_argument(
        'folder',
        nargs='?',
        default='.',
        help='Folder containing *_b<N>_<pattern>.log files (default: current dir)'
    )
    parser.add_argument(
        '--csv',
        metavar='OUTPUT.csv',
        help='Also export all events to a CSV file'
    )
    args = parser.parse_args()

    folder = os.path.abspath(args.folder)
    print(f"Scanning: {folder}")

    stats = collect_stats(folder)
    # print_report(stats)

    if args.csv:
        export_csv(stats, args.csv)


if __name__ == '__main__':
    main()