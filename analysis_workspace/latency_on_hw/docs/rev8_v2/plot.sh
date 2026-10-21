#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/../../../.." && pwd)
cd "$repo"
export PATH="/home/jaeyongjang/.conda/envs/vortex/bin:$PATH"
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
# Run only after run.sh has completed measurement and refinement.
"$PYTHON" analysis_workspace/latency_on_hw/docs/rev8_v2/freeze_plot_inputs.py
"$PYTHON" -u analysis_workspace/latency_on_hw/workflow.py pipeline \
  --tag rev8_v2 \
  --candidate-map analysis_workspace/latency_on_hw/candidate_fpga_bins.rev8.yaml \
  --suite-size full --models llama2,llama3 --from compose --to plot \
  --offline-inputs analysis_workspace/latency_on_hw/docs/rev8_v2/plot_inputs
"$PYTHON" analysis_workspace/latency_on_hw/docs/rev8_v2/compare_results.py
