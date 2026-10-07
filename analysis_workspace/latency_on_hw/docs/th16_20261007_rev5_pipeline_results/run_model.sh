#!/usr/bin/env bash
set -euo pipefail
model="$1"
repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
w="$repo/analysis_workspace/latency_on_hw"
d="$w/docs/th16_20261007_rev5_pipeline_results"
py=/home/jaeyongjang/.conda/envs/vortex/bin/python
export PYTHON="$py"
export PATH="/home/jaeyongjang/.conda/envs/vortex/bin:$PATH"
export PYTHONPATH="$repo${PYTHONPATH:+:$PYTHONPATH}"
export CANDIDATE_MAP="$w/candidate_fpga_bins.rev5.yaml"
export XRT_INI_PATH=/dev/null
export OMP_NUM_THREADS=4
unset XCL_EMULATION_MODE FPGA_BIN_DIR XRT_XCLBIN_PATH
if [[ "$model" == llama2 ]]; then
  export XRT_DEVICE_INDEX=0 XRT_DEVICE_BDF=0000:2a:00.1
else
  export XRT_DEVICE_INDEX=1 XRT_DEVICE_BDF=0000:3d:00.1
fi
export VORTEX_SHM_PATH="/dev/shm/vortex_rev5_${SLURM_JOB_ID}_${model}"
source "$repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh"
cd "$repo/build_latency_$model"
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex" > "$d/configure_$model.log" 2>&1
cd "$repo"
for stage in prefill generation; do
  echo "START $model $stage $(date --iso-8601=seconds)"
  "$py" -u -m tools.latency_bench run \
    --suite "$d/${model}_${stage}.pkl" \
    --out "$w/outputs_${model}_main.th16_20261007_rev5_pipeline/C4/refresh_fpint_gemm_ffn_hw" \
    --build-dir "$repo/build_latency_$model" --fpga-bin C4 \
    --candidate-map "$CANDIDATE_MAP" --warmup 0 --iterations 1 \
    --latency --power --strict-measurement-reuse --skip-existing --adopt-legacy \
    --application-source-identity "$(< "$d/application_source_identity.txt")" \
    --power-kernel-iterations auto --power-target-sec 10 --power-latency-interval 0.1 \
    --no-power-auto-duration --power-idle-stability-policy "$w/idle_stability_policy.json" \
    --blackbox-timeout 5m --retry --retry-max-rounds 2 --retry-timeout-growth 1.01 \
    --xrt-device-index "$XRT_DEVICE_INDEX" --xrt-device-bdf "$XRT_DEVICE_BDF" --no-srun \
    > "$d/${model}_${stage}.log" 2>&1
  echo "PASS $model $stage $(date --iso-8601=seconds)"
done
