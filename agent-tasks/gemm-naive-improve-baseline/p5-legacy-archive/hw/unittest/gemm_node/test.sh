#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# GEMM node regression test runner
#
# Usage:
#   ./test.sh                          # run all (qcol + qrow)
#   ./test.sh qcol                     # QDIR=COL tests only
#   ./test.sh qrow                     # QDIR=ROW tests only
#   ./test.sh single M,N,K,QBLK,WTRANS,QDIR
#                                      # run one specific case
#     e.g.  ./test.sh single 32,32,64,32,0,1
#
# Environment variables:
#   SIM_EXEC   vlt  | vcs (default)
#   DO_CLEAN   0 (default) | 1
#   CCACHE_DIR cache directory (default /tmp/.ccache)
# ===========================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

SIM_EXEC=${SIM_EXEC:-vcs}
DO_CLEAN=${DO_CLEAN:-0}
CCACHE_DIR=${CCACHE_DIR:-/tmp/.ccache}
mkdir -p logs "$CCACHE_DIR"

if [[ "$DO_CLEAN" == "1" ]]; then
  make clean
fi

# ---- test sets -----------------------------------------------------------

# QCOL shapes (row-major, QDIR=0)
QCOL_SHAPES=(
  "32,32,32"
  "2,64,128"
  "8,32,128"
  "4,128,128"
  "2,64,256"
)
QCOL_QBLKS=(32 64 128)
QCOL_WTRANS=(0 1)

# QROW shapes (QDIR=1, constraint: qblk >= MXU_KT && qblk >= MXU_NT,
#               qblk%MXU_KT==0, qblk%MXU_NT==0  => qblk in {32,64,128,...})
QROW_SHAPES=(
  "32,32,64"
  "2,32,128"
  "4,64,128"
  "8,128,256"
)
QROW_QBLKS=(32 64 128)
QROW_WTRANS=(0 1)

# ---- helpers -------------------------------------------------------------

ts=$(date +%Y%m%d_%H%M%S)
SUMMARY="logs/regress_${ts}.summary"
: > "$SUMMARY"

pass=0
fail=0

run_case() {
  local m="$1" n="$2" k="$3" qblk="$4" wtrans="$5" qdir="$6"
  local qdir_tag; qdir_tag=$( (( qdir )) && echo "QROW" || echo "QCOL" )
  local name="${qdir_tag}_WT${wtrans}_Q${qblk}_M${m}_N${n}_K${k}"
  local sim_log="logs/sim_${name}.log"
  local mk_log="logs/make_${name}.log"

  echo "[RUN] $name" | tee -a "$SUMMARY"
  local start; start=$(date +%s)

  if CCACHE_DIR="$CCACHE_DIR" make SIM_EXEC="$SIM_EXEC" run \
      TEST="$name" M="$m" N="$n" K="$k" QBLK="$qblk" \
      EXTRA_SIM_ARGS="+WTRANS=${wtrans} +QDIR=${qdir}" >"$mk_log" 2>&1; then
    :
  else
    :
  fi

  local end; end=$(date +%s)
  local dur=$((end - start))

  if [[ -f "$sim_log" ]] && grep -q "OUTPUT CHECK PASSED" "$sim_log"; then
    echo "[PASS] $name (${dur}s)" | tee -a "$SUMMARY"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name (${dur}s)" | tee -a "$SUMMARY"
    if [[ -f "$sim_log" ]]; then
      grep -nE "TEST_CFG|Fatal:|ERROR|OUTPUT CHECK" "$sim_log" | tail -n 20 | tee -a "$SUMMARY"
    else
      tail -n 40 "$mk_log" | tee -a "$SUMMARY"
    fi
    fail=$((fail + 1))
  fi

  echo "" >> "$SUMMARY"
}

run_qcol() {
  for shape in "${QCOL_SHAPES[@]}"; do
    IFS=',' read -r m n k <<< "$shape"
    for qblk in "${QCOL_QBLKS[@]}"; do
      for wtrans in "${QCOL_WTRANS[@]}"; do
        run_case "$m" "$n" "$k" "$qblk" "$wtrans" 0
      done
    done
  done
}

run_qrow() {
  for shape in "${QROW_SHAPES[@]}"; do
    IFS=',' read -r m n k <<< "$shape"
    for qblk in "${QROW_QBLKS[@]}"; do
      for wtrans in "${QROW_WTRANS[@]}"; do
        run_case "$m" "$n" "$k" "$qblk" "$wtrans" 1
      done
    done
  done
}

# ---- main ----------------------------------------------------------------

MODE="${1:-all}"

case "$MODE" in
  all)
    run_qcol
    run_qrow
    ;;
  qcol)
    run_qcol
    ;;
  qrow)
    run_qrow
    ;;
  single)
    # expect: M,N,K,QBLK,WTRANS,QDIR
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 single M,N,K,QBLK,WTRANS,QDIR"
      exit 1
    fi
    IFS=',' read -r sm sn sk sqblk swtrans sqdir <<< "$2"
    run_case "$sm" "$sn" "$sk" "$sqblk" "$swtrans" "$sqdir"
    ;;
  *)
    echo "Unknown mode: $MODE"
    echo "Usage: $0 [all|qcol|qrow|single M,N,K,QBLK,WTRANS,QDIR]"
    exit 1
    ;;
esac

echo "[RESULT] pass=${pass} fail=${fail}" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
