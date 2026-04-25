#!/usr/bin/env bash
# run_bench.sh — sweep latency measurements across (xclbin x kernel) combinations.
#
# Assumes each kernel lives in tests/regression/<kernel>/ and its main.cpp has
# been instrumented with --bench via tests/common/bench_harness.h.
#
# Usage:
#   tools/bench/run_bench.sh \
#       --xclbins "/path/a.xclbin /path/b.xclbin" \
#       --kernels "softmax rope fpint_gemm_ffn_hw_improve" \
#       --csv /tmp/bench.csv \
#       [--iters 30] [--warmup 5] \
#       [--opts-softmax "-batch 4 -seqq 32 -seqk 32"] \
#       [--opts-fpint_gemm_ffn_hw_improve "-m 128 -n 128 -k 128 -q 32"]
#
# Per-kernel extra args can be supplied via --opts-<kernel_name>.
# Global extra args via --opts "...".

set -euo pipefail

XCLBINS=""
KERNELS=""
CSV="/tmp/vortex_bench.csv"
ITERS=30
WARMUP=5
COMMON_OPTS=""
TARGET="${TARGET:-hw}"  # hw | hw_emu

declare -A PER_KERNEL_OPTS

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xclbins)   XCLBINS="$2"; shift 2 ;;
    --kernels)   KERNELS="$2"; shift 2 ;;
    --csv)       CSV="$2"; shift 2 ;;
    --iters)     ITERS="$2"; shift 2 ;;
    --warmup)    WARMUP="$2"; shift 2 ;;
    --opts)      COMMON_OPTS="$2"; shift 2 ;;
    --target)    TARGET="$2"; shift 2 ;;
    --opts-*)
      k="${1#--opts-}"
      PER_KERNEL_OPTS[$k]="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$XCLBINS" || -z "$KERNELS" ]]; then
  echo "ERROR: --xclbins and --kernels are required" >&2
  exit 1
fi

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: > "$CSV"   # start fresh; harness appends

echo "repo    = $REPO_ROOT"
echo "target  = $TARGET"
echo "csv     = $CSV"
echo "iters   = $ITERS, warmup = $WARMUP"

for xclbin in $XCLBINS; do
  if [[ ! -f "$xclbin" ]]; then
    echo "[skip] xclbin not found: $xclbin" >&2
    continue
  fi
  bin_dir="$(cd "$(dirname "$xclbin")" && pwd)"
  bin_name="$(basename "$xclbin" .xclbin)"

  # Vortex runtime looks for vortex_afu.xclbin under FPGA_BIN_DIR.
  # We point it at the directory containing this xclbin, then symlink if name
  # differs (leaves the original binary unchanged).
  if [[ "$(basename "$xclbin")" != "vortex_afu.xclbin" ]]; then
    ln -sf "$xclbin" "$bin_dir/vortex_afu.xclbin"
  fi

  export FPGA_BIN_DIR="$bin_dir"
  echo ""
  echo "=== xclbin: $bin_name ($xclbin) ==="

  for k in $KERNELS; do
    test_dir="$REPO_ROOT/tests/regression/$k"
    if [[ ! -d "$test_dir" ]]; then
      echo "[skip] test dir not found: $test_dir" >&2
      continue
    fi
    extra="${PER_KERNEL_OPTS[$k]:-}"
    label="${k}@${bin_name}"
    opts="--bench --iters $ITERS --warmup $WARMUP --csv $CSV --label $label $COMMON_OPTS $extra"
    echo ""
    echo "--- $label ---"
    (cd "$test_dir" && make run-xrt TARGET="$TARGET" OPTS="$opts")
  done
done

echo ""
echo "=== done. summary: ==="
python3 "$SCRIPT_DIR/aggregate.py" "$CSV"
