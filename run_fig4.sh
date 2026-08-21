#!/bin/bash

bank_id=77           # CHANGE ME!
delay=0

num_rows=1000      # CHANGE ME! Number of rows in the row_set (line number - 1)
base_agg=100        # Any row id to generate the pattern
crit_agg=1000       # Any row id to generate the pattern

vic_pat=00          # Victim row data pattern in hex
agg_pat=ff          # Aggressor row data pattern in hex

num_agg=9           # Number of aggressors
num_warp=3          # Number of warps
num_thread=3        # Number of threads per warp
round=1             # No. of round per tREFI, each round hammers <num_agg> rows
# Make sure that:
#   - num_warp * num_thread >= num_agg
#   - num_agg * round <= max number of activations per tREFI

row_step=4          # Distance between two aggressor rows in a hammering pattern
skip_step=1         # Increment <skip_step> rows after hammering each pattern
count_iter=50       # Hammer each pattern <count_iter> times

iterations=100000   # Number of tREFI intervals to hammer\

# Memory Properties
addr_step=256           # Set to be the <step> parameter used in finding conf_set/row_set
mem_size=$((43 * (1 << 30)))    # CHANGE ME! Bytes of memory allocated for hammering (recommend: size of memory - 1GB)

# File paths
folder="$HAMMER_ROOT/results/fig4/raw_data"
mkdir -p $folder

rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}.txt"

# Step 1: Compute baseline
intensity=1
same_warp=0
same_cacheline=0

log_file="$folder/baseline.log"
time_file="$folder/baseline.txt"

# Running the test
nvidia-smi -q > $log_file
echo "Running baseline ..."

$HAMMER_ROOT/src/out/build/coalesce $rowset_file $num_agg $addr_step $iterations $base_agg $crit_agg $row_step $skip_step $mem_size $num_warp $num_thread $delay $round $count_iter $num_rows $vic_pat $agg_pat $same_warp $same_cacheline $intensity $time_file > $log_file

echo "Baseline completed"

sleep 3


# Step 2: Generate data
for intensity in 2 3; do
    for same_warp in 0 1; do
        for same_cacheline in 0 1; do

            log_file="$folder/${intensity}x_warp${same_warp}_cacheline${same_cacheline}.log"
            time_file="$folder/${intensity}x_warp${same_warp}_cacheline${same_cacheline}_timing.txt"

            # Running the test
            nvidia-smi -q > $log_file
            echo "Running with ${intensity}x intensity, same_warp = ${same_warp}, same_cacheline = ${same_cacheline} ..."

            $HAMMER_ROOT/src/out/build/coalesce $rowset_file $num_agg $addr_step $iterations $base_agg $crit_agg $row_step $skip_step $mem_size $num_warp $num_thread $delay $round $count_iter $num_rows $vic_pat $agg_pat $same_warp $same_cacheline $intensity $time_file > $log_file

            echo "done."

            sleep 3

        done
    done
done

# Step 3: Plot
echo "Plotting Figure 4 ..."
python3 $HAMMER_ROOT/plot_scripts/plot_fig4.py
echo "Saved Figure 4 at ${HAMMER_ROOT}/results/fig4.pdf"
