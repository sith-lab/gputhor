#!/bin/bash

echo ""
echo "-------------------------------------------"
echo ""
echo "[INFO] Starting Generation of Row Sets"

# Generate offsets for four banks (bank IDs 0 through 3).
python3 "$HAMMER_ROOT/util/run_timing_task.py" bank_set \
  --size $((47 * (2 ** 30))) --it 15 --step 256 --threshold 27 \
  --max 4 --outputFile "$HAMMER_ROOT/BANK_SET.txt"

declare -A bank_map
bank_id=0
while IFS= read -r offset; do
  [ -z "$offset" ] && continue
  bank_map[$offset]=$bank_id
  bank_id=$((bank_id + 1))
done < "$HAMMER_ROOT/BANK_SET.txt"

START_BANK=0
END_BANK=3

# Set SELECT_BANK_IDS to a space-separated list of bank_ids to run only those
# (e.g. SELECT_BANK_IDS="3 7 12"). Leave empty to use START_BANK through END_BANK (inclusive).
SELECT_BANK_IDS=""
declare -A select_bank_ids
for id in $SELECT_BANK_IDS; do
  select_bank_ids[$id]=1
done

for val in "${!bank_map[@]}"; do
  if [ ${#select_bank_ids[@]} -gt 0 ]; then
    [ -z "${select_bank_ids[${bank_map[$val]}]}" ] && continue
  else
    [ "${bank_map[$val]}" -lt "$START_BANK" ] && continue
    [ "${bank_map[$val]}" -gt "$END_BANK" ] && continue
  fi
  python3 $HAMMER_ROOT/util/run_timing_task.py conf_set --range $((47 * (2 ** 30))) --size $((47 * (2 ** 30))) --it 15 --step 256 --threshold 27 --file $HAMMER_ROOT/results/row_sets/CONF_SET_${bank_map[$val]}.txt --trgtBankOfs $val
  sleep 3s
  python3 $HAMMER_ROOT/util/run_timing_task.py row_set --size $((47 * (2 ** 30))) --it 15 --threshold 27 --trgtBankOfs $val --outputFile $HAMMER_ROOT/results/row_sets/ROW_SET_${bank_map[$val]}.txt $HAMMER_ROOT/results/row_sets/CONF_SET_${bank_map[$val]}.txt
  sleep 3s
done

echo "[INFO] Done. Row Sets are stored in 'results/row_sets'"
