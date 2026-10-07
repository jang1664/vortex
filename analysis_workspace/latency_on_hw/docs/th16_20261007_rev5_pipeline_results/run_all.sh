#!/usr/bin/env bash
set -uo pipefail
d=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/th16_20261007_rev5_pipeline_results
printf 'SLURM_JOB_ID=%s start=%s\n' "$SLURM_JOB_ID" "$(date --iso-8601=seconds)"
bash "$d/run_model.sh" llama2 > "$d/llama2.session.log" 2>&1 &
p2=$!
bash "$d/run_model.sh" llama3 > "$d/llama3.session.log" 2>&1 &
p3=$!
trap 'kill -TERM "$p2" "$p3" 2>/dev/null || true' TERM INT
wait "$p2"; r2=$?
wait "$p3"; r3=$?
printf 'llama2_exit=%s llama3_exit=%s end=%s\n' "$r2" "$r3" "$(date --iso-8601=seconds)"
[[ "$r2" == 0 && "$r3" == 0 ]]
