#!/bin/bash

# Bank IDs to run.
bank_ids=(77 149 302 322)

# Per-bank delay overrides. Any bank_id not listed here falls back to
# default_delay below.
default_delay=0
declare -A delays=(
  [77]=43
  [149]=43
  [302]=42
  [322]=43
)

pattern_pairs=(
  "55 aa"
  "aa 55"
  "00 ff"
  "ff 00"
)
for bank_id in "${bank_ids[@]}"; do
  delay=${delays[$bank_id]:-$default_delay}

  for pair in "${pattern_pairs[@]}"; do
    read vic_pat agg_pat <<< "$pair"

    echo "=========================================="
    echo "Bank $bank_id | delay=$delay | vic=$vic_pat agg=$agg_pat"
    echo "=========================================="

    num_rows=32000
    min_rowid=500
    max_rowid=$((min_rowid + 1000))

    num_agg=24
    num_warp=8
    num_thread=3
    round=1
    trefi=6

    row_step=4
    skip_step=1
    count_iter=5

    iterations=$((46000))

    # Memory Properties
    addr_step=256
    mem_size=$((47 * (1 << 30)))

    # File paths
    folder="$HAMMER_ROOT/results/t3_campaign"
    mkdir -p "$folder/raw_data"

    rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}.txt"
    log_file="$folder/raw_data/${num_agg}agg_b${bank_id}_${vic_pat}${agg_pat}.log"
    bitflip_file="$folder/raw_data/${num_agg}agg_b${bank_id}_${vic_pat}${agg_pat}.txt"

    # Running the test
    nvidia-smi -q > "$log_file"
    echo "Start hammering ..."

    $HAMMER_ROOT/src/out/build/gputhor \
      "$rowset_file" $num_agg $addr_step $iterations \
      $min_rowid $max_rowid $row_step $skip_step \
      $mem_size $num_warp $num_thread $delay $round \
      $count_iter $num_rows $vic_pat $agg_pat $trefi \
      "$bitflip_file" > "$log_file"

    echo "Hammering done for bank $bank_id | $vic_pat/$agg_pat"
    sleep 3
  done
done

# Gather bit-flip statistics from the raw logs, then summarise.
folder="$HAMMER_ROOT/results/t3_campaign"
collected_csv="$folder/raw_data/collector.csv"
summary_csv="$folder/flip_summary.csv"
summary_txt="$folder/flip_summary.txt"

echo "=========================================="
echo "Collecting bit-flip statistics ..."
echo "=========================================="
python3 "$HAMMER_ROOT/rowhammer_stats/collector.py" "$folder/raw_data" --csv "$collected_csv"

echo "=========================================="
echo "Summarising bit-flip statistics ..."
echo "=========================================="
python3 "$HAMMER_ROOT/rowhammer_stats/flip_summary.py" "$collected_csv" --csv "$summary_csv" | tee "$summary_txt"
