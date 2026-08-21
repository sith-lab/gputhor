#!/usr/bin/env python3

import re
import sys

def count_unique_flips(filename):
    # Regex to extract the hexadecimal address
    addr_pattern = re.compile(r'Address\s+(0x[0-9a-fA-F]+)')
    row_pattern = re.compile(r'Chosen Critical Aggressor:\s+([0-9]+)')

    unique_addresses = set()
    unique_rows = set()

    with open(filename, 'r') as f:
        for line in f:
            match = addr_pattern.search(line)
            if match:
                addr = match.group(1)
                unique_addresses.add(addr)
            match = row_pattern.search(line)
            if match:
                row = match.group(1)
                unique_rows.add(row)

    return len(unique_addresses), len(unique_rows)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <flip_log.txt>")
        sys.exit(1)

    filename = sys.argv[1]
    count, rows = count_unique_flips(filename)

    print(f"Number of unique bit-flips (by address): {count}")
    print(f"Number of rows: {rows}")
    print(f"Percentage: {count / rows}")
