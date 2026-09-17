#!/bin/bash

bash "$(dirname "${BASH_SOURCE[0]}")/util/check_ecc.sh" Disabled || exit 1

bank_id=77           # CHANGE ME!
delay=60            # CHANGE ME! Delay, set to an optimal delay found by run_delay.sh

num_rows=64000      # CHANGE ME! Number of rows in the row_set (line number - 1)
base_agg=30021        # Any row id to generate the base pattern
crit_agg=30022      # CHANGE ME! A critical aggressor row that can trigger flips in neighbors

vic_pat=00          # Victim row data pattern in hex
agg_pat=ff          # Aggressor row data pattern in hex

num_agg=24          # Number of aggressors
num_warp=8          # Number of warps
num_thread=3        # Number of threads per warp
round=1             # No. of round per tREFI, each round hammers <num_agg> rows
# Make sure that:
#   - num_warp * num_thread >= num_agg
#   - num_agg * round <= max number of activations per tREFI

row_step=4          # Distance between two aggressor rows in a hammering pattern
skip_step=1         # Increment <skip_step> rows after hammering each pattern
count_iter=100       # Hammer each pattern <count_iter> times

iterations=23000   # Number of tREFI intervals to hammer

num_trials=5        # Number of independent trials per (tREFI, intensity), aggregated in the CSV
agg_method=mean     # How to aggregate the trials: "mean" or "median"

intensity_min=2      # Lowest intensity (ACTs/tREFI) to sweep
intensity_max=7      # Highest intensity (ACTs/tREFI) to sweep

# Memory Properties
addr_step=256           # Set to be the <step> parameter used in finding conf_set/row_set
mem_size=$((47 * (1 << 30)))    # CHANGE ME! Bytes of memory allocated for hammering (recommend: size of memory - 1GB)
folder="$HAMMER_ROOT/results/fig7/raw_data"
mkdir -p $folder
for trial in $(seq 1 $num_trials); do
  for trefi in 3 4 6 9 18 24; do
    echo "TREFI = $trefi"

    for intensity in $(seq $intensity_min $intensity_max); do
      total_acts=$((intensity * trefi))
      echo "  Intensity ${intensity} ACT/TREFI -> Total ACTs: ${total_acts}"
      
      rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}.txt"

      log_file="$folder/${intensity}x_${trefi}trefi_b${bank_id}_${vic_pat}${agg_pat}_trial${trial}.log"
      bitflip_file="$folder/${intensity}x_${trefi}trefi_b${bank_id}_${vic_pat}${agg_pat}_trial${trial}.txt"

      # Running the test
      nvidia-smi -q > $log_file
      echo "Start hammering ${intensity}x ${trefi} tREFI patterns (trial ${trial}/${num_trials}) ..."

      $HAMMER_ROOT/src/out/build/intensity_analysis_NtREFI $rowset_file $num_agg $addr_step $iterations $base_agg $crit_agg $row_step $skip_step $mem_size $num_warp $num_thread $delay $round $count_iter $num_rows $vic_pat $agg_pat $trefi $total_acts $bitflip_file > $log_file

      echo "Hammering done."
      sleep 20
    done
  done
done

echo "Plotting Figure 7 ..."
python3 $HAMMER_ROOT/plot_scripts/plot_fig7.py $count_iter \
  --bank-id $bank_id \
  --vic-pat $vic_pat \
  --agg-pat $agg_pat \
  --num-trials $num_trials \
  --agg-method $agg_method \
  --intensity-min $intensity_min \
  --intensity-max 8
echo "CSV written to ${HAMMER_ROOT}/results/fig7_output.csv"
echo "Saved Figure 7 at ${HAMMER_ROOT}/results/fig7.pdf"
