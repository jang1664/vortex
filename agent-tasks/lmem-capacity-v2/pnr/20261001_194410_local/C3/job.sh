#!/usr/bin/env bash
set -euo pipefail
unset PERF DEBUG SCOPE PROFILE MAKEFLAGS SLURM_JOB_ID SLURM_JOBID SLURM_CPUS_PER_TASK
export FAST_MODE=0 JOBS=8 MAX_JOBS=8
export PLATFORM=/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194410_local/configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh
exec python3 /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194410_local/run_job.py --profile C3 --build /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build_pnr_c3_20261001_194410_local --config /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194410_local/configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh --directory /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/lmem-capacity-v2/pnr/20261001_194410_local/C3 --slr-floorplan 0 --attempt 2
