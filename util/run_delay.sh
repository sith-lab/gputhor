#!/bin/bash
# Delay sweep: for a chosen hammer executable, runs a single hammering round at
# each delay in [min_delay, max_delay) and records its timing, producing the
# same <..>_timing_delay.txt format that plot_delay.py expects.
#
# This replaces the old dedicated `sync_delay` binary (synchronization.cu,
# whose CMake target was already dropped) -- every hammer executable already
# accepts `delay` as a CLI argument and already prints a
# "Took Approx: <N>ns" line via print_time(), so the sweep itself can just
# live in bash and call whichever real executable we care about.
#
# To sweep a new executable, add a case arm below that appends its argv in
# order and points BITFLIP_FILE/TIME_ARG at /dev/null as appropriate.

# Which executable to sweep: gputhor | gputhor_ecc | gputhor_nonuniform | gpu_hammer | rep_hammer
exe=gputhor

# Variables
bank_id=1

num_agg=24          # Number of aggressors
num_warp=8          # Number of warps
num_thread=3        # Number of threads per warp
round=1             # Period (tREFI rounds) between hammer bursts

min_delay=0         # Minimum delay to test
max_delay=100       # Maximum delay to test

num_rows=32000      # Number of rows in the row_set (line number - 1)
rowid=500           # Id of a row to test the delays, can be arbitrary
iterations=10000    # Hammering iterations per delay sample

vic_pat=00          # Victim row data pattern in hex
agg_pat=ff          # Aggressor row data pattern in hex

trefi=1             # gputhor/gputhor_ecc/gputhor_nonuniform only: tREFI intervals per hammering round
num_reps=1          # rep_hammer only: number of repeated critical-aggressor slots

# Memory Properties
addr_step=256           # Set to be the <step> parameter used in finding conf_set/row_set
mem_size=$((15 * (1 << 30)))    # Bytes of memory allocated for hammering (recommend: size of memory - 1GB)

# Fixed for a delay sweep: exercise exactly one row, one pass, no bit-flip check
row_step=4
skip_step=1
count_iter=1
min_rowid=$rowid
max_rowid=$((rowid + 1))

# File paths
folder="$HAMMER_ROOT/results/delay"
mkdir -p "$folder"
rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}.txt"
time_file="$folder/${exe}_${num_agg}agg_b${bank_id}_timing_delay.txt"
log_file="$folder/${exe}_${num_agg}agg_b${bank_id}_delay.log"

nvidia-smi -q > "$log_file"
: > "$time_file"

echo "Sweeping delay $min_delay..$((max_delay - 1)) on $exe ..."

for ((delay = min_delay; delay < max_delay; delay++)); do
  case "$exe" in
    gputhor)
      cmd=("$HAMMER_ROOT/src/out/build/gputhor" "$rowset_file" "$num_agg" "$addr_step" "$iterations" \
           "$min_rowid" "$max_rowid" "$row_step" "$skip_step" "$mem_size" "$num_warp" "$num_thread" \
           "$delay" "$round" "$count_iter" "$num_rows" "$vic_pat" "$agg_pat" "$trefi" /dev/null)
      ;;
    gputhor_ecc)
      cmd=("$HAMMER_ROOT/src/out/build/gputhor_ecc" "$rowset_file" "$num_agg" "$addr_step" "$iterations" \
           "$min_rowid" "$max_rowid" "$row_step" "$skip_step" "$mem_size" "$num_warp" "$num_thread" \
           "$delay" "$round" "$count_iter" "$num_rows" "$vic_pat" "$agg_pat" "$trefi" /dev/null)
      ;;
    gputhor_nonuniform)
      cmd=("$HAMMER_ROOT/src/out/build/gputhor_nonuniform" "$rowset_file" "$num_agg" "$addr_step" "$iterations" \
           "$min_rowid" "$max_rowid" "$row_step" "$skip_step" "$mem_size" "$num_warp" "$num_thread" \
           "$delay" "$round" "$count_iter" "$num_rows" "$vic_pat" "$agg_pat" "$trefi" /dev/null)
      ;;
    gpu_hammer)
      cmd=("$HAMMER_ROOT/src/out/build/gpu_hammer" "$rowset_file" "$((num_agg - 1))" "$addr_step" "$iterations" \
           "$min_rowid" "$max_rowid" "$row_step" "$skip_step" "$mem_size" "$num_warp" "$num_thread" \
           "$delay" "$round" "$count_iter" "$num_rows" "$vic_pat" "$agg_pat" /dev/null)
      ;;
    rep_hammer)
      cmd=("$HAMMER_ROOT/src/out/build/rep_hammer" "$rowset_file" "$num_agg" "$addr_step" "$iterations" \
           "$min_rowid" "$max_rowid" "$row_step" "$skip_step" "$mem_size" "$num_warp" "$num_thread" \
           "$delay" "$round" "$count_iter" "$num_rows" "$vic_pat" "$agg_pat" "$num_reps" /dev/null)
      ;;
    *)
      echo "Unknown exe: $exe" >&2
      exit 1
      ;;
  esac

  out=$("${cmd[@]}" 2>&1)
  echo "$out" >> "$log_file"

  ns=$(grep -oP 'Took Approx: \K[0-9]+(?=ns)' <<< "$out" | tail -1)
  echo "$ns" >> "$time_file"
  echo "  delay=$delay -> ${ns:-<no timing found>}"
done

echo "Hammering done."
