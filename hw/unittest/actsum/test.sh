#!/usr/bin/env bash
set -u

# Run a small sweep of PIPELINE_STAGES (bitmask) and DLY_CYCLES.
# Notes:
# - DLY_CYCLES maps to VX_elastic_buffer SIZE.
#   SIZE > 2 uses VX_fifo_queue which requires DEPTH to be a power of 2.
#   Therefore we only use {0,1,2,4} here.

PIPELINE_LIST=(0 1 2 3 7)
DLY_LIST=(0 1 2 4)

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

mkdir -p logs reports
mkdir -p sweep

pass=0
fail=0

echo "======================================"
echo " actsum sweep"
echo " folder: $here"
echo " PIPELINE_LIST: ${PIPELINE_LIST[*]}"
echo " DLY_LIST:      ${DLY_LIST[*]}"
echo "======================================"

for p in "${PIPELINE_LIST[@]}"; do
  for d in "${DLY_LIST[@]}"; do
    tag="p${p}_d${d}"
    echo
    echo "==> Running $tag"

    # Clean first to avoid mixing artifacts/logs between runs.
    make clean >/dev/null 2>&1 || true

    # make clean removes logs/reports in this unittest; recreate them per run.
    mkdir -p logs reports

    run_log="sweep/run_${tag}.log"
    : > "$run_log"

    if make sim -j TB_PIPELINE_STAGES="$p" TB_DLY_CYCLES="$d" >>"$run_log" 2>&1; then
      if grep -q "\*\*\* ALL TESTS PASSED \*\*\*" "$run_log"; then
        echo "PASS $tag"
        pass=$((pass+1))
      else
        echo "FAIL $tag (no PASS marker)"
        fail=$((fail+1))
      fi
    else
      echo "FAIL $tag (make error)"
      fail=$((fail+1))
    fi

    # Preserve key artifacts per run if present.
    if [[ -f logs/compile.log ]]; then
      cp -f logs/compile.log "sweep/compile_${tag}.log" >/dev/null 2>&1 || true
    fi
    if [[ -f logs/sim.log ]]; then
      cp -f logs/sim.log "sweep/sim_${tag}.log" >/dev/null 2>&1 || true
    fi
    if [[ -f reports/tb_VX_act_sum.fsdb ]]; then
      cp -f reports/tb_VX_act_sum.fsdb "sweep/tb_VX_act_sum_${tag}.fsdb" >/dev/null 2>&1 || true
    fi
    if [[ -f reports/tb_VX_act_sum.fst ]]; then
      cp -f reports/tb_VX_act_sum.fst "sweep/tb_VX_act_sum_${tag}.fst" >/dev/null 2>&1 || true
    fi
  done
done

echo

echo "======================================"
echo " Sweep summary"
echo "   PASS: $pass"
echo "   FAIL: $fail"
echo " Logs:  sweep/run_*.log"
echo "======================================"

exit $((fail != 0))
