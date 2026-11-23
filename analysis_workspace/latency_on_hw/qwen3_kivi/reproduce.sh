#!/usr/bin/env bash
# Run from a login shell. The official coordinator owns the model sweep allocation.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
flow=$(dirname "$here")
export VORTEX_HOME=$(cd "$flow/../.." && pwd)
tag=${1:-}
mode=${2:-all}
if [[ $# -gt 2 || ! "$tag" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo "Usage: $0 TAG [all|sweep|generate|report|rtl-check|board-check]" >&2
    exit 2
fi
out="$flow/outputs_qwen3_kivi_$tag"
PYTHON=$(command -v "${PYTHON:-python3}")
export PYTHON
export PYTHONPATH="$VORTEX_HOME${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1
export PATH="$(dirname "$PYTHON"):$PATH"
export THIRD_PARTY_DIR="${THIRD_PARTY_DIR:-$VORTEX_HOME/third_party}"
export CC="${CC:-/usr/bin/gcc}" CXX="${CXX:-/usr/bin/g++}"
export MPLBACKEND=Agg

configure_build() {
    source "$1"
    mkdir -p "$2"
    cd "$2"
    "$VORTEX_HOME/configure" --xlen=64 --tooldir="${TOOLDIR:-/opt/vortex}" --prefix="${VORTEX_PREFIX:-$HOME/tools/vortex}"
    make -C hw config
}

setup_xrt() {
    export XILINX_XRT="${XILINX_XRT:-/opt/xilinx/xrt}" XRT_INI_PATH=/dev/null
    source "$XILINX_XRT/setup.sh"
}

pipeline() {
    "$PYTHON" "$flow/workflow.py" pipeline --models qwen3 --tag "$tag" --state-root "$out" \
        --candidate-map "$flow/candidate_fpga_bins.rev7.yaml" --suite-size full \
        --from generate --to "$1" --generation-out-tokens 128 --generation-max-seq-len 65536 \
        --decode-measurement sampled --decode-sample-interval 32 --slurm-time 7-00:00:00 --formats png,pdf
}

case "$mode" in
    all)
        "$here/reproduce.sh" "$tag" rtl-check
        "$here/reproduce.sh" "$tag" board-check
        exec "$here/reproduce.sh" "$tag" sweep
        ;;
    sweep)
        setup_xrt
        "$PYTHON" "$here/check_workloads.py"
        configure_build "$VORTEX_HOME/configs/tcu_th16_c1_v3.sh" "$out/build_qwen3"
        make -C kernel -j4
        make -C runtime/stub -j4
        make -C runtime/xrt TARGET=hw -j4
        export NO_SRUN=1
        pipeline plot
        "$PYTHON" "$here/report.py" "$out"
        ;;
    generate) pipeline generate ;;
    report) exec "$PYTHON" "$here/report.py" "$out" ;;
    rtl-check)
        configure_build "$VORTEX_HOME/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh" "$out/build_gate"
        cd hw/unittest/gemm_node_improve
        make FPU_XILINX_EN=1 SIMLIB_DIR="${SIMLIB_DIR:-$out/vcs_simlib}" compile
        for spec in 'qk 4 64 128 1' 'pv 4 128 64 0' 'qk_tail 1 144 128 1' 'pv_tail 1 128 144 0'; do
            read -r name m n k trans <<< "$spec"
            for pattern in OFFSET_CASE CHANNEL_TAGS; do
                log="${name}_${pattern}.log"
                ./simv_xilinx +NO_WAVE +TEST="$name" +M="$m" +N="$n" +K="$k" +WTRANS="$trans" \
                    +QDIR=1 +QBLK=32 +KIVI_LAYOUT +CHECK_EXACT "+$pattern" -l "$log"
                grep -q 'TILED OUTPUT CHECK PASSED' "$log"
            done
        done
        ;;
    board-check)
        if [[ -z "${SLURM_JOB_ID:-}" ]]; then
            exec srun -p fpga --gres=fpga:u55c:1 -c 4 --mem=16G --time=02:00:00 "$here/reproduce.sh" "$tag" board-check
        fi
        setup_xrt
        mkdir -p "$out/kernel_latency"
        unset XRT_DEVICE_INDEX XRT_DEVICE_BDF
        capture="$out/kernel_latency"
        "$PYTHON" - "$flow/candidate_fpga_bins.rev7.yaml" > "$capture/candidate_snapshot.json" <<'PY'
import json
from pathlib import Path
import sys
from tools.latency_bench.candidate_map import resolve_candidate_map
print(json.dumps(resolve_candidate_map(Path(sys.argv[1]), ("C1", "C4"))))
PY
        for candidate in C1 C4; do
            spec=$("$PYTHON" -c 'import json,sys; s=json.load(open(sys.argv[1]))["candidates"][sys.argv[2]]; print(s["alias"]); print(s["config"])' "$capture/candidate_snapshot.json" "$candidate")
            fpga_alias=${spec%%$'\n'*}
            config=${spec#*$'\n'}
            configure_build "$config" "$out/build_check_$candidate"
            make -C kernel -j4
            if [[ "$candidate" == C4 ]]; then
                source "$here/board_cases.sh"
            fi
            for n in 1024 8192 32768; do
                if [[ "$candidate" == C4 ]]; then
                    app=fpint_gemm_ffn_hw
                    args="-m 8 -n 65536 -k 128 --target-m 4 --target-n $n -q 32 -t 1 -d 1"
                else
                    app=sgemm_tcu
                    args="-m 4 -n $n -k 128"
                fi
                "$VORTEX_HOME/ci/run_black.sh" hw --no-srun --fpga-bin "$fpga_alias" --app "$app" --bench \
                    --args "$args --warmup=0 --iterations=1 --csv --output=$capture/${candidate}_$n.csv"
            done > "$capture/qk_${candidate}.stdout" 2>&1
        done
        "$PYTHON" "$here/standalone_qk.py" "$capture"
        ;;
    *) echo "Unknown mode: $mode" >&2; exit 2 ;;
esac
