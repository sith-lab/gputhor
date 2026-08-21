#!/bin/bash

# Variant of run_gpuhammer_Ntrefi_multi.sh that adds:
#   1. After each gpu_hammer_Ntrefi run, the bit-flip lines in the .log file
#      are extracted into a companion "*_flips.txt" file.
#   2. If nvidia-smi reports that the volatile uncorrected (DUE) DRAM ECC
#      error count went up during the run, every flip extracted from that
#      run's log is tagged "[DUE]" in the companion file.
#   3. If the run ends before reaching the last row (max_rowid - 1) - e.g.
#      because a DUE killed the process - the GPU's ECC errors are cleared
#      via `nvidia-smi --reset-ecc-errors=0` and the same bank_id/pattern is
#      re-run, picking up at min_rowid = (last "Chosen Critical Aggressor"
#      seen) + 1.

if [ -z "$HAMMER_ROOT" ]; then
  echo "Error: HAMMER_ROOT is not defined." >&2
  exit 1
fi

# Bank IDs to run (arbitrary set/order, each in 1..384).
bank_ids=(144)

# Per-bank delay overrides. Any bank_id not listed here falls back to
# default_delay below.
default_delay=0
declare -A delays=(
  [144]=44
)

pattern_pairs=(
  # "55 aa"
  # "aa 55"
  "00 ff"
  # "ff 00"
)

# ----------------------------------------------------------------------------
# Helper: current volatile uncorrected (DUE) DRAM ECC error count.
# Prints nothing if nvidia-smi can't be queried (e.g. GPU fell off the bus).
# ----------------------------------------------------------------------------
get_uncorrected_ecc() {
  nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.dram \
    --format=csv,noheader,nounits -i 0 2>/dev/null
}

for bank_id in "${bank_ids[@]}"; do
  delay=${delays[$bank_id]:-$default_delay}

  for pair in "${pattern_pairs[@]}"; do
    read vic_pat agg_pat <<< "$pair"

    num_rows=62000
    min_rowid=10114
    max_rowid=62000

    num_agg=24
    num_warp=8
    num_thread=3
    round=1

    row_step=4
    skip_step=1
    count_iter=20

    iterations=$((46000))

    # Memory Properties
    addr_step=256
    mem_size=$((43 * (1 << 30)))

    # File paths
    folder="$HAMMER_ROOT/results/gpuh2t_campaign"
    mkdir -p "$folder/raw_data"

    rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}.txt"

    current_min_rowid=$min_rowid

    while true; do
      echo "=========================================="
      echo "Bank $bank_id | delay=$delay | vic=$vic_pat agg=$agg_pat | min_rowid=$current_min_rowid"
      echo "=========================================="

      log_file="$folder/raw_data/${num_agg}agg_b${bank_id}_${vic_pat}${agg_pat}_min${current_min_rowid}.log"
      bitflip_file="$folder/raw_data/${num_agg}agg_b${bank_id}_${vic_pat}${agg_pat}_min${current_min_rowid}.txt"
      flipinfo_file="$folder/raw_data/${num_agg}agg_b${bank_id}_${vic_pat}${agg_pat}_min${current_min_rowid}_flips.txt"

      # Running the test
      uncorrected_before=$(get_uncorrected_ecc)

      echo "Start hammering ..."
      $HAMMER_ROOT/src/out/build/gputhor \
        "$rowset_file" $num_agg $addr_step $iterations \
        $current_min_rowid $max_rowid $row_step $skip_step \
        $mem_size $num_warp $num_thread $delay $round \
        $count_iter $num_rows $vic_pat $agg_pat 6 \
        "$bitflip_file" > "$log_file"

      uncorrected_after=$(get_uncorrected_ecc)

      echo "Hammering done for bank $bank_id | $vic_pat/$agg_pat"

      # ------------------------------------------------------------------
      # 1. Pull the bit-flip info out of this run's log into its own file.
      #    Per-byte detail ("Observed N bit-flip(s) in Row R, Byte B,
      #    Address A" followed by "The Nth bit flipped ...") comes from the
      #    device-side verify_result_kernel printf - a single printf call's
      #    two lines are always emitted contiguously, so pairing consecutive
      #    lines here is reliable. If a "Bit-flip observed" summary has no
      #    matching detail pair, a fallback line is still emitted so the
      #    signal isn't lost.
      # ------------------------------------------------------------------
      awk '
        /Chosen Critical Aggressor:/ { agg_row = $NF; detail_found = 0 }

        /^Observed [0-9]+ bit-flip\(s\) in Row/ {
          vrow = $6; sub(/,$/, "", vrow)
          vbyte = $8; sub(/,$/, "", vbyte)
          vaddr = $10
          pending = 1
          next
        }

        pending && /^The [0-9]+th bit flipped/ {
          bitpos = $2; sub(/th$/, "", bitpos)
          pat_after = $13; sub(/\)$/, "", pat_after)
          print "AggRow " agg_row ": Row " vrow ", Byte " vbyte ", Address " vaddr ", bit " bitpos " " $6 "->" $8 " (Pattern " $11 "->" pat_after ")"
          pending = 0
          detail_found = 1
          next
        }

        /Bit-flip in victim rows: Observed Bit-Flip/ && !detail_found {
          print "AggRow " agg_row ": Bit-flip observed (no per-byte detail captured)"
        }
      ' "$log_file" > "$flipinfo_file"

      # ------------------------------------------------------------------
      # 2. Did an uncorrectable (DUE) DRAM ECC error happen during this run?
      #    Either the count went up, or nvidia-smi couldn't be queried
      #    afterwards (GPU fell off the bus) - both indicate a DUE.
      # ------------------------------------------------------------------
      due_detected=false
      if [[ -z "$uncorrected_after" ]]; then
        due_detected=true
      elif [[ -n "$uncorrected_before" && "$uncorrected_after" -gt "$uncorrected_before" ]]; then
        due_detected=true
      fi

      if [[ "$due_detected" == true && -s "$flipinfo_file" ]]; then
        echo "Uncorrectable error detected during this run - marking flips in $flipinfo_file as DUE"
        sed -i 's/$/ [DUE]/' "$flipinfo_file"
      fi

      # ------------------------------------------------------------------
      # 3. Did we make it all the way to the last row? If not, recover the
      #    GPU and resume from where we left off.
      # ------------------------------------------------------------------
      last_row=$(grep -oP 'Chosen Critical Aggressor:\s*\K[0-9]+' "$log_file" | tail -n1)

      if [[ -n "$last_row" && "$last_row" -ge $((max_rowid - 1)) ]]; then
        echo "Bank $bank_id | $vic_pat/$agg_pat reached the last row ($last_row) - done."
        break
      fi

      echo "Bank $bank_id | $vic_pat/$agg_pat stopped early (last row: ${last_row:-none}, target: $((max_rowid - 1))). Clearing ECC errors and resuming ..."
      sudo nvidia-smi --reset-ecc-errors=0

      if [[ -n "$last_row" ]]; then
        current_min_rowid=$((last_row + 1))
      fi
      sleep 3
    done

    sleep 3
  done
done
