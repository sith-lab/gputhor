#!/bin/bash
#
# run_artifact.sh — end-to-end artifact reproduction driver.
#
# Runs, in order:
#   1. run_fig4.sh              (<2 min)
#   2. run_fig6.sh              (<45 min)
#   3. run_fig7.sh              (<1 h 15 min)
#   4. run_table3_campaign.sh   (~1 h 30 min)
#
# Total estimated runtime: ~3.5 hours.

set -u
set -o pipefail

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${HAMMER_ROOT:-}" ]; then
  echo "HAMMER_ROOT not set"
  exit 1
fi

KEEP_GOING=0
for arg in "$@"; do
  case "$arg" in
    -k|--keep-going)
      KEEP_GOING=1
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [-k|--keep-going]

Runs the full artifact reproduction pipeline:
  1. run_fig4.sh              (<2 min)
  2. run_fig6.sh              (<45 min)
  3. run_fig7.sh              (<1h 15 min)
  4. run_table3_campaign.sh   (~1 h 30 min)

  -k, --keep-going   Continue with remaining steps even if one fails.
  -h, --help         Show this help message.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------

echo "Installing Python dependencies from requirements.txt..."
if ! python3 -m pip install -r "$SCRIPT_DIR/requirements.txt"; then
  echo "Failed to install Python dependencies" >&2
  exit 1
fi

echo "Initializing GPU clocks..."
if ! bash "$SCRIPT_DIR/util/init_cuda.sh" 1800 8000; then
  echo "Failed to initialize GPU clocks" >&2
  exit 1
fi

echo "Building GPUThor..."
if ! bash "$SCRIPT_DIR/build.sh" src; then
  echo "Build failed" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Visuals
# ----------------------------------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

rule() {
  printf "%s" "$CYAN"
  printf '%.0s-' $(seq 1 78)
  printf "%s\n" "$RESET"
}

fmt_duration() {
  local total=${1:-0} h m s
  h=$((total / 3600)); m=$(((total % 3600) / 60)); s=$((total % 60))
  if [ "$h" -gt 0 ]; then printf "%dh %dm %ds" "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then printf "%dm %ds" "$m" "$s"
  else printf "%ds" "$s"
  fi
}

# Render an estimate given in minutes, e.g. 75 -> "1h 15min", 45 -> "45min".
fmt_estimate() {
  local total=${1:-0} h m
  h=$((total / 60)); m=$((total % 60))
  if [ "$h" -gt 0 ] && [ "$m" -gt 0 ]; then printf "%dh %dmin" "$h" "$m"
  elif [ "$h" -gt 0 ]; then printf "%dh" "$h"
  else printf "%dmin" "$m"
  fi
}

# ----------------------------------------------------------------------------
# Step definitions
# ----------------------------------------------------------------------------

STEP_NAMES=("Figure 4" "Figure 6" "Figure 7" "Table 3 Campaign")
STEP_SCRIPTS=("run_fig4.sh" "run_fig6.sh" "run_fig7.sh" "run_table3_campaign.sh")
STEP_DESCS=(
  "Timing separation for same/cross-warp, same/diff-cacheline accesses"
  "Bit-flip reproduction rate across tREFI lengths and intensities"
  "Maximum hammering intensity (ACT/tREFI) across multi-tREFI configs"
  "GPUThor campaign across multiple banks and data patterns"
)
STEP_ESTIMATES=(5 45 75 90)
NUM_STEPS=${#STEP_SCRIPTS[@]}

TOTAL_ESTIMATE=0
for e in "${STEP_ESTIMATES[@]}"; do TOTAL_ESTIMATE=$((TOTAL_ESTIMATE + e)); done

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$HAMMER_ROOT/results/artifact_run_${RUN_ID}"
mkdir -p "$LOG_DIR"

declare -a STEP_STATUS=()
declare -a STEP_DURATION=()

# ----------------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------------

echo
rule
printf "%s%s  GPUThor Artifact Reproduction%s\n" "$BOLD" "$CYAN" "$RESET"
rule
printf "  %-22s %s\n" "HAMMER_ROOT:" "$HAMMER_ROOT"
printf "  %-22s %s\n" "Logs:" "$LOG_DIR"
printf "  %-22s ~%s (%d min)\n" "Estimated runtime:" "$(fmt_estimate "$TOTAL_ESTIMATE")" "$TOTAL_ESTIMATE"
echo
printf "  %-4s %-20s %-10s %s\n" "#" "Step" "Est. time" "Description"
for i in "${!STEP_SCRIPTS[@]}"; do
  printf "  %-4s %-20s ~%-9s %s\n" "$((i+1))" "${STEP_NAMES[$i]}" "$(fmt_estimate "${STEP_ESTIMATES[$i]}")" "${STEP_DESCS[$i]}"
done
rule
echo

ARTIFACT_START=$(date +%s)

print_summary() {
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - ARTIFACT_START))
  echo
  rule
  printf "%s%s  Summary%s\n" "$BOLD" "$CYAN" "$RESET"
  rule
  for i in "${!STEP_SCRIPTS[@]}"; do
    local status="${STEP_STATUS[$i]:-skipped}"
    local dur="${STEP_DURATION[$i]:-0}"
    local mark color
    case "$status" in
      ok) mark="[OK]"; color="$GREEN" ;;
      failed) mark="[FAIL]"; color="$RED" ;;
      *) mark="[--]"; color="$DIM" ;;
    esac
    printf "  %s%-6s%s %-20s %s\n" "$color" "$mark" "$RESET" "${STEP_NAMES[$i]}" "$(fmt_duration "$dur")"
  done
  rule
  printf "  Total elapsed: %s\n" "$(fmt_duration "$elapsed")"
  printf "  Logs:          %s\n" "$LOG_DIR"
  rule
  echo
}

trap 'echo; printf "%sInterrupted.%s\n" "$RED" "$RESET"; print_summary; exit 130' INT TERM

# ----------------------------------------------------------------------------
# Run steps
# ----------------------------------------------------------------------------

OVERALL_OK=1

STEP_COOLDOWN=15

for i in "${!STEP_SCRIPTS[@]}"; do
  name="${STEP_NAMES[$i]}"
  script="${STEP_SCRIPTS[$i]}"
  desc="${STEP_DESCS[$i]}"
  est="${STEP_ESTIMATES[$i]}"
  script_path="$HAMMER_ROOT/$script"
  log_file="$LOG_DIR/$(printf '%02d' $((i+1)))_${script%.sh}.log"

  if [ "$i" -gt 0 ]; then
    printf "%sWaiting %ds before next step...%s\n" "$DIM" "$STEP_COOLDOWN" "$RESET"
    sleep "$STEP_COOLDOWN"
  fi

  echo
  rule
  printf "%s%s[%d/%d] %s%s  %s(~%s, started %s)%s\n" \
    "$BOLD" "$BLUE" "$((i+1))" "$NUM_STEPS" "$name" "$RESET" "$DIM" "$(fmt_estimate "$est")" "$(date '+%H:%M:%S')" "$RESET"
  printf "%s%s%s\n" "$DIM" "$desc" "$RESET"
  rule

  if [ ! -f "$script_path" ]; then
    printf "%sMissing script: %s%s\n" "$RED" "$script_path" "$RESET"
    STEP_STATUS[$i]="failed"
    STEP_DURATION[$i]=0
    OVERALL_OK=0
    if [ "$KEEP_GOING" -eq 1 ]; then
      continue
    else
      print_summary
      exit 1
    fi
  fi

  step_start=$(date +%s)
  bash "$script_path" 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  step_end=$(date +%s)
  step_dur=$((step_end - step_start))
  STEP_DURATION[$i]=$step_dur

  if [ "$rc" -eq 0 ]; then
    STEP_STATUS[$i]="ok"
    printf "%s[OK] %s completed in %s%s\n" "$GREEN" "$name" "$(fmt_duration "$step_dur")" "$RESET"
  else
    STEP_STATUS[$i]="failed"
    OVERALL_OK=0
    printf "%s[FAIL] %s failed (exit %d) after %s -- see %s%s\n" \
      "$RED" "$name" "$rc" "$(fmt_duration "$step_dur")" "$log_file" "$RESET"
    if [ "$KEEP_GOING" -ne 1 ]; then
      print_summary
      exit "$rc"
    fi
  fi
done

print_summary

if [ "$OVERALL_OK" -eq 1 ]; then
  printf "%sAll steps completed successfully.%s\n" "$GREEN" "$RESET"
  exit 0
else
  printf "%sOne or more steps failed. See logs above.%s\n" "$RED" "$RESET"
  exit 1
fi
