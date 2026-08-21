#!/bin/bash

bank_id=77           # CHANGE ME!
delay=58            # CHANGE ME! Delay, set to an optimal delay found by run_delay.sh

num_rows=31400      # CHANGE ME! Number of rows in the row_set (line number - 1)
base_agg=100        # Any row id to generate the base pattern
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
skip_step=3         # Increment <skip_step> rows after hammering each pattern
count_iter=20       # Hammer each pattern <count_iter> times

iterations=46000   # Number of tREFI intervals to hammer

# Memory Properties
addr_step=256           # Set to be the <step> parameter used in finding conf_set/row_set
mem_size=$((23 * (1 << 30)))    # CHANGE ME! Bytes of memory allocated for hammering (recommend: size of memory - 1GB)

for trefi in {1..36}; do
  for intensity in {2..4}; do

    # File paths
    folder="$HAMMER_ROOT/results/fig6/raw_data"
    mkdir -p $folder

    rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}.txt"
    log_file="$folder/${intensity}x_${trefi}trefi_b${bank_id}_${vic_pat}${agg_pat}.log"
    bitflip_file="$folder/${intensity}x_${trefi}trefi_b${bank_id}_${vic_pat}${agg_pat}.txt"

    # Running the test
    nvidia-smi -q > $log_file
    echo "Start hammering ${intensity}x ${trefi} tREFI patterns ..."

    $HAMMER_ROOT/src/out/build/extend_NtREFI $rowset_file $num_agg $addr_step $iterations $base_agg $crit_agg $row_step $skip_step $mem_size $num_warp $num_thread $delay $round $count_iter $num_rows $vic_pat $agg_pat $trefi $intensity $bitflip_file > $log_file

    echo "Hammering done."

    sleep 3

  done
  sleep 10
done

echo "Plotting Figure 6 ..."
python3 $HAMMER_ROOT/plot_scripts/plot_fig6.py
echo "Saved Figure 6 at ${HAMMER_ROOT}/results/fig6.pdf"

