#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
cd "$repo"
export MPLBACKEND=Agg
python=/home/jaeyongjang/.conda/envs/vortex/bin/python
"$python" -u analysis_workspace/latency_on_hw/workflow.py pipeline \
  --tag rev5_v2 --candidate-map analysis_workspace/latency_on_hw/candidate_fpga_bins.rev5.yaml \
  --from compose --to plot \
  --offline-inputs analysis_workspace/latency_on_hw/docs/rev5_v2/plot
