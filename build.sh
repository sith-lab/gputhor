#!/bin/bash
#
# build.sh — build the GPUThor executables for this repository.
#
# Builds one or both of:
#   src   the top-level GPUThor rowhammer tool ($REPO/src)
#         (needed by run_artifact.sh and by run_ecc_exploit.sh's hammering phase)
#   due   the GPUBreach Section 8 (DUE) exploit
#         (gpubreach-section8-DUE/build.sh: its gpuhammer, src, and cred_mod)
#
# Usage:
#   bash build.sh [src|due|all]
#     src   build only the top-level GPUThor tool
#     due   build only the GPUBreach Section 8 (DUE) exploit
#     all   build everything (default)

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Top-level GPUThor tool ($REPO/src), as built by run_artifact.sh.
# ----------------------------------------------------------------------------
build_src() {
  echo "Building GPUThor (src)..."
  if ! cmake -S "$SCRIPT_DIR/src" -B "$SCRIPT_DIR/src/out/build"; then
    echo "CMake configuration failed (src)" >&2
    return 1
  fi
  if ! make -C "$SCRIPT_DIR/src/out/build" -j; then
    echo "Build failed (src)" >&2
    return 1
  fi
}

# ----------------------------------------------------------------------------
# GPUBreach Section 8 (DUE) exploit, via gpubreach-section8-DUE/build.sh.
# ----------------------------------------------------------------------------
build_due() {
  local due_dir="$SCRIPT_DIR/gpubreach-section8-DUE"
  echo "Building GPUBreach Section 8 (DUE)..."
  if [ ! -f "$due_dir/init_env.sh" ]; then
    echo "Missing init_env.sh in $due_dir" >&2
    return 1
  fi
  if [ ! -f "$due_dir/build.sh" ]; then
    echo "Missing build.sh in $due_dir" >&2
    return 1
  fi
  # init_env.sh derives BREACH_ROOT / HAMMER_ROOT from `pwd`, and the DUE
  # build.sh relies on both. Run them from the DUE folder in a subshell so the
  # caller's working directory and environment are left unchanged.
  (
    cd "$due_dir" || exit 1
    # shellcheck source=/dev/null
    source "$due_dir/init_env.sh"
    bash "$due_dir/build.sh"
  )
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
target="${1:-all}"

case "$target" in
  src)
    build_src
    ;;
  due)
    build_due
    ;;
  all)
    build_src && build_due
    ;;
  -h|--help)
    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Unknown target: $target (expected: src, due, or all)" >&2
    exit 1
    ;;
esac
