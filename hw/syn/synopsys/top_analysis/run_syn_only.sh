#!/bin/bash
# Top-level synthesis only (no PnR) for the target Vortex configs.
#
# Usage:
#   hw/syn/synopsys/top_analysis/run_syn_only.sh [config ...]
#
# With no arguments, runs all four synthesis targets sequentially:
#   - configs/tcu_th16_c1.sh
#   - configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh
#   - configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh
#   - configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh
#
# Requires the "stable" conda env (hwexplorer deps). Each run uses
# `--stages top` (elaborate + compile_ultra, ICC2 handoff skipped).
# Per-config driver logs go to /tmp/opencode/dc_top/<tag>.driver.log;
# DC logs live under build/hw/syn/synopsys/top_analysis/Vortex_axi_<tag>/top/logs/.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VORTEX_HOME="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$VORTEX_HOME" || exit 1

if [ "$#" -gt 0 ]; then
    CONFIGS=("$@")
else
    CONFIGS=(
        configs/tcu_th16_c1.sh
        configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh
        configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh
        configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh
    )
fi

LOGDIR=/tmp/opencode/dc_top
mkdir -p "$LOGDIR"

FAILED=()
for cfg in "${CONFIGS[@]}"; do
    tag="$(basename "$cfg" .sh)"
    # Serialize against other DC runs: a second concurrent dc_shell -topo
    # segfaults during analyze (observed 2026-09-18). Wait our turn.
    while pgrep -f "dc_shell -topo" > /dev/null; do
        echo "### [$tag] waiting for active DC run..."
        sleep 120
    done
    echo "### [$tag] start: $(date '+%m%d_%H:%M:%S')"
    conda run -n stable \
        env PYTHONPATH=third_party/hwexplorer \
        python -u hw/syn/synopsys/top_analysis/run.py \
            --config "$cfg" --stages top \
        > "$LOGDIR/$tag.driver.log" 2>&1
    rc=$?
    echo "### [$tag] exit: $rc"
    if [ $rc -ne 0 ]; then
        FAILED+=("$tag")
    fi
done

echo
echo "===== error summary (DC run.log) ====="
for cfg in "${CONFIGS[@]}"; do
    tag="$(basename "$cfg" .sh)"
    run_top="build/hw/syn/synopsys/top_analysis/Vortex_axi_$tag/top"
    dclog="$(ls -t "$run_top"/logs/run.log.* 2>/dev/null | head -1)"
    if [ -z "${dclog:-}" ]; then
        echo "[$tag] no DC log found"
        continue
    fi
    nerr="$(grep -cE '^Error|^Fatal:' "$dclog" || true)"
    nunres="$(grep -ciE 'unresolved reference|Unable to resolve reference' "$dclog" || true)"
    echo "[$tag] Error/Fatal lines: $nerr, unresolved-ref lines: $nunres"
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "FAILED: ${FAILED[*]}"
    exit 1
fi
echo "ALL DRIVER JOBS EXITED 0"
