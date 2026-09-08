#!/usr/bin/env bash
# Existing xclbin only. Invoke from configured build under a Slurm allocation.
set -euo pipefail
[[ -n "${SLURM_JOB_ID:-}" ]] || { echo "Slurm allocation required" >&2; exit 1; }
[[ -f config.mk && -f ci/run_black.sh ]] || { echo "Configured build required" >&2; exit 1; }
source ../configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
export PATH=/usr/bin:$PATH
unset VORTEX_RT_PATH TARGET U55C_PERFORMANCE_PROFILE
report_dir="$PWD/hardware-smoke-${SLURM_JOB_ID}"
workload_label=${REFERENCE_SMOKE_LABEL:-gemm16}
app_name=${REFERENCE_SMOKE_APP:-fpint_gemm_ffn_hw}
[[ "$workload_label" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
[[ "$app_name" =~ ^[a-zA-Z0-9_]+$ ]] || exit 2
mkdir -p "$report_dir"
printf '%s\n' "$SLURM_JOB_ID" > "$report_dir/job-id.txt"
/opt/xilinx/xrt/bin/xrt-smi examine --device 0000:2a:00.1 \
    --report platform dynamic-regions memory --format JSON \
    --output "$report_dir/before.json" > "$report_dir/before.log" 2>&1
set +e
timeout 300 bash ci/run_black.sh hw --fpga-bin temp --app "$app_name" \
    --args "${REFERENCE_SMOKE_ARGS:--m 16 -n 16 -k 16 -q 32 -r 1}" > "$report_dir/${workload_label}.log" 2>&1
run_status=$?
/opt/xilinx/xrt/bin/xrt-smi examine --device 0000:2a:00.1 \
    --report platform dynamic-regions memory --format JSON \
    --output "$report_dir/after.json" > "$report_dir/after.log" 2>&1
report_status=$?
set -e
printf 'workload_exit=%s report_exit=%s\n' "$run_status" "$report_status"
echo "Reports: $report_dir"
if [[ $run_status != 0 ]]; then exit "$run_status"; fi
exit "$report_status"
