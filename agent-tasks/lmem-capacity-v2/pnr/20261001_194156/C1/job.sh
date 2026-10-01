#!/usr/bin/env bash
set -euo pipefail
unset PERF DEBUG SCOPE PROFILE MAKEFLAGS
export FAST_MODE=0 JOBS=8 MAX_JOBS=8
export PLATFORM=/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194156/configs/tcu_th16_c1_v2.sh
exec python3 /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194156/run_job.py --profile C1 --build /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build_pnr_c1_20261001_194156 --config /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194156/configs/tcu_th16_c1_v2.sh --directory /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194156/C1
