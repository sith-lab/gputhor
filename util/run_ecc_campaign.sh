# Set the first parameter to <Stable Max Clock Rate> reported by run_timing_task.py
# Set the second parameter to a stable memory clock rate
# bash $HAMMER_ROOT/util/init_cuda.sh 2040 6000
# bank delays (1, 43) (2, 44) (3, 44) (4, 43) (5, 45) (6, 42) (7, 43) (8, 45) (9,44)
# Variables
bank_id=144
delay=43          # Delay, set to an optimal delay found by run_delay.sh

num_rows=62000     # Number of rows in the row_set (line number - 1)
# min_rowid=$((30022-92))         # Minimum row id to hammer (set to >=6 to avoid list overflow in the code)
# max_rowid=$((30022-91))    # Maximum row id to hammer (set to <= num_rows - 100 to avoid overflow)
min_rowid=2935        # Minimum row id to hammer (set to >=6 to avoid list overflow in the code)
max_rowid=10000    # Maximum row id to hammer (set to <= num_rows - 100 to avoid overflow)
# min_rowid=56490         # Minimum row id to hammer (set to >=6 to avoid list overflow in the code)
# max_rowid=56491    # Maximum row id to hammer (set to <= num_rows - 100 to avoid overflow)

vic_pat=00                                                            # Victim row data pattern in hex
agg_pat=ff          # Aggressor row data pattern in hex

num_agg=24          # Number of aggressors
num_warp=8          # Number of warps
num_thread=3        # Number of threads per warp
round=1             # No. of round per tREFI, each round hammers <num_agg> rows
trefi=6             # Number of tREFI intervals per hammering round
# Make sure that:
#   - num_warp * num_thread >= num_agg
#   - num_agg * round <= max number of activations per tREFI

row_step=4          # Distance between two aggressor rows in a hammering pattern
skip_step=1         # Increment <skip_step> rows after hammering each pattern
count_iter=10        # Hammer each pattern <count_iter> times

iterations=$((46000))    # Number of tREFI intervals to hammer

# Memory Properties
addr_step=256           # Set to be the <step> parameter used in finding conf_set/row_set
mem_size=$((43 * (1 << 30)))    # Bytes of memory allocated for hammering (recommend: size of memory - 1GB)

# File paths
folder="$HAMMER_ROOT/results/ecc_campaign"
mkdir -p $folder/raw_data

rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}.txt"
log_file="$folder/raw_data/${num_agg}agg_b${bank_id}_${vic_pat}${agg_pat}.log"
bitflip_file="$folder/raw_data/${num_agg}agg_b${bank_id}_${vic_pat}${agg_pat}.txt"


# Running the test
nvidia-smi -q > $log_file
echo "Start hammering ..."

$HAMMER_ROOT/src/out/build/gputhor_ecc $rowset_file $num_agg $addr_step $iterations $min_rowid $max_rowid $row_step $skip_step $mem_size $num_warp $num_thread $delay $round $count_iter $num_rows $vic_pat $agg_pat $trefi $bitflip_file > $log_file

echo "Hammering done."


