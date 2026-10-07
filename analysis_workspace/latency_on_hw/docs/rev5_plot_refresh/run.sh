#!/usr/bin/env bash
set -euo pipefail
repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
workspace="$repo/analysis_workspace/latency_on_hw"
evidence="$workspace/docs/rev5_plot_refresh"
python=/home/jaeyongjang/.conda/envs/vortex/bin/python
tag=th16_20261007_rev5_pipeline
export MPLBACKEND=Agg
cd "$repo"
"$python" "$evidence/build_plot_inputs.py"
"$python" -u "$workspace/run_compose.py" \
  --llama2-results "$workspace/outputs_llama2_main.$tag" \
  --llama3-results "$workspace/outputs_llama3_main.$tag" \
  --llama2-suites "$evidence/suites/llama2_7b" \
  --llama3-suites "$evidence/suites/llama3_8b" \
  --models llama2_7b,llama3_8b --metric fpga_cycle_latency \
  --select latest --missing error --raw-db-subdirs C1,C3,C4 \
  --out "$workspace/composed_results.$tag" \
  > "$evidence/compose.log" 2>&1
for model in llama2_7b llama3_8b; do
  "$python" -u "$workspace/prepare.py" \
    --composed-csv "$workspace/composed_results.$tag/$model/composed.csv" \
    --models "$model" --workers 1 --exact-model-input --out-tokens 128 \
    --output-root "$workspace/figure_prepare.$tag" \
    > "$evidence/prepare_$model.log" 2>&1
done
raw_args=()
for model in llama2 llama3; do
  for candidate in C1 C3 C4; do
    raw_args+=(--kernel-raw-db "$workspace/outputs_${model}_main.$tag/$candidate/raw_db.csv")
  done
done
"$python" -u "$workspace/plot.py" --plot all --models llama2_7b,llama3_8b \
  --out-tokens 128 --workers 1 --formats png,pdf,svg \
  --prepared-root "$workspace/figure_prepare.$tag" \
  --out-dir "$workspace/figure_output.$tag" \
  --candidate-snapshot "$evidence/power_selection.json" "${raw_args[@]}" \
  > "$evidence/plot.log" 2>&1
echo "Completed: $workspace/figure_output.$tag"
