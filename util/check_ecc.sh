#!/bin/bash

expected=${1:-}
case "$expected" in
  Enabled|Disabled) ;;
  *)
    echo "Usage: $0 Enabled|Disabled" >&2
    exit 1
    ;;
esac

if ! modes=$(nvidia-smi --query-gpu=ecc.mode.current --format=csv,noheader); then
  echo "Cannot verify current ECC mode with nvidia-smi; refusing to run." >&2
  exit 1
fi

if [ -z "$modes" ]; then
  echo "nvidia-smi returned no ECC modes; refusing to run." >&2
  exit 1
fi

# Require a known, matching current mode on every GPU returned by nvidia-smi.
gpu=0
while IFS= read -r mode; do
  mode=${mode//[[:space:]]/}
  if [ "$mode" != "$expected" ]; then
    echo "GPU $gpu: current ECC mode is '${mode:-unknown}'; requires $expected. Refusing to run." >&2
    exit 1
  fi
  gpu=$((gpu + 1))
done <<< "$modes"
