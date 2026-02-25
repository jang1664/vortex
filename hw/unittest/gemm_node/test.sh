#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

SIM_EXEC=${SIM_EXEC:-vlt}
DO_CLEAN=${DO_CLEAN:-0}
CCACHE_DIR=${CCACHE_DIR:-/tmp/.ccache}
mkdir -p logs "$CCACHE_DIR"

if [[ "$DO_CLEAN" == "1" ]]; then
  make clean
fi

# Larger smoke set (row-major assumptions, QDIR=COL)
SHAPES=(
  "2,64,128"
  "8,32,128"
  "4,128,128"
  "2,64,256"
)

QBLKS=(32 64 128)
WTRANS_LIST=(0 1)

ts=$(date +%Y%m%d_%H%M%S)
SUMMARY="logs/regress_qblk_wtrans_${ts}.summary"
: > "$SUMMARY"

pass=0
fail=0

run_case() {
  local m="$1" n="$2" k="$3" qblk="$4" wtrans="$5"
  local name="WT${wtrans}_Q${qblk}_M${m}_N${n}_K${k}"
  local sim_log="logs/sim_${name}.log"
  local mk_log="logs/make_${name}.log"
  local start
  local end
  local dur

  echo "[RUN] $name" | tee -a "$SUMMARY"
  start=$(date +%s)

  if CCACHE_DIR="$CCACHE_DIR" make SIM_EXEC="$SIM_EXEC" run \
      TEST="$name" M="$m" N="$n" K="$k" QBLK="$qblk" \
      EXTRA_SIM_ARGS="+WTRANS=${wtrans}" >"$mk_log" 2>&1; then
    :
  else
    :
  fi

  end=$(date +%s)
  dur=$((end - start))

  if [[ -f "$sim_log" ]] && rg -q "OUTPUT CHECK PASSED" "$sim_log"; then
    echo "[PASS] $name (${dur}s)" | tee -a "$SUMMARY"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name (${dur}s)" | tee -a "$SUMMARY"
    if [[ -f "$sim_log" ]]; then
      rg -n "TEST_CFG|Fatal:|ERROR|OUTPUT CHECK" "$sim_log" | tail -n 20 | tee -a "$SUMMARY"
    else
      tail -n 40 "$mk_log" | tee -a "$SUMMARY"
    fi
    fail=$((fail + 1))
  fi

  echo "" >> "$SUMMARY"
}

for shape in "${SHAPES[@]}"; do
  IFS=',' read -r m n k <<< "$shape"
  for qblk in "${QBLKS[@]}"; do
    for wtrans in "${WTRANS_LIST[@]}"; do
      run_case "$m" "$n" "$k" "$qblk" "$wtrans"
    done
  done
done

echo "[RESULT] pass=${pass} fail=${fail}" | tee -a "$SUMMARY"
echo "Summary: $SUMMARY"
