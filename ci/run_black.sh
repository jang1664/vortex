#!/bin/bash

# ----------------------------------------------------------------------------
# - rtlsim
# ----------------------------------------------------------------------------
CONFIGS="-DEXT_TCU_ENABLE -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DVCD_OUTPUT -DAFU_DONE_WAIT_CACHE_DRAIN -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"

CONFIGS="${CONFIGS}" \
DRIVER=rtlsim \
./ci/blackbox.sh --cores=2 --driver=rtlsim --app=vecadd_multi_invoke --args="-n 512 -r 4"

# ----------------------------------------------------------------------------
# - xrtsim
# ----------------------------------------------------------------------------
CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
CONFIGS+=" -DVCD_OUTPUT"
CONFIGS+=" ${AP_DONE_DRAIN_CFG}"
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"
DRAM_REQ_STALL_P_ENTER_PCT=70 \
DRAM_REQ_STALL_P_EXIT_PCT=30 \
DRAM_RSP_STALL_P_ENTER_PCT=70 \
DRAM_RSP_STALL_P_EXIT_PCT=30 \
DRAM_STALL_SEED=1234 \
CONFIGS=${CONFIGS} \
DRIVER=xrt \
./ci/blackbox.sh --debug=3 --cores=2 --driver=xrt --app=vecadd_multi_invoke --args="-n 16384 -r 1"

# ----------------------------------------------------------------------------
# - xrt-vcs-sim
# ----------------------------------------------------------------------------
CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE -DLMEM_LOG_SIZE=22"
CONFIGS+=" -DVCD_OUTPUT"
CONFIGS+=" ${AP_DONE_DRAIN_CFG}"
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"

DRAM_REQ_STALL_P_ENTER_PCT=70 \
DRAM_REQ_STALL_P_EXIT_PCT=30 \
DRAM_RSP_STALL_P_ENTER_PCT=70 \
DRAM_RSP_STALL_P_EXIT_PCT=30 \
DRAM_STALL_SEED=1234 \
CONFIGS=${CONFIGS} \
DRIVER=xrt_vcs \
FSDB_DUMP=1 \
DEBUG_AXI=1 \
./ci/blackbox.sh --cores=1 --threads=32 --driver=xrt_vcs --app=vecadd_multi_invoke --args="-n 8192 -r 1"

./ci/blackbox.sh --cores=1 --threads=8 --driver=xrt_vcs --app=sgemm_tcu

# ----------------------------------------------------------------------------
# - xrt-vcs-pgsim
# ----------------------------------------------------------------------------
CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
CONFIGS+=" -DVCD_OUTPUT"
CONFIGS+=" ${AP_DONE_DRAIN_CFG}"
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"

DRAM_REQ_STALL_P_ENTER_PCT=70 \
DRAM_REQ_STALL_P_EXIT_PCT=30 \
DRAM_RSP_STALL_P_ENTER_PCT=70 \
DRAM_RSP_STALL_P_EXIT_PCT=30 \
DRAM_STALL_SEED=1234 \
CONFIGS=${CONFIGS} \
DRIVER=xrt_vcs_post \
FSDB_DUMP=1 \
DEBUG_AXI=1 \
GUI=1 \
NETLIST=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/gate_sim/vortex_afu_funcsim.v \
./ci/blackbox.sh --cores=2 --driver=xrt_vcs_post --app=vecadd_multi_invoke --args="-n 32 -r 1"

# ----------------------------------------------------------------------------
# - hw_emu
# ----------------------------------------------------------------------------
CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
CONFIGS+=" -DVCD_OUTPUT"
NUM_CORES=2
APP=vecadd_multi_invoke
ARGS="-n 128 -r 1"

CONFIGS=${CONFIGS} \
FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw_emu/bin \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
DRIVER=xrt \
TARGET=hw_emu \
DEBUG_LEVEL=3 \
./ci/blackbox.sh --cores=${NUM_CORES} --driver=xrt --app=$APP --args=$ARGS --debug=${DEBUG_LEVEL}

# ----------------------------------------------------------------------------
# - hw
# ----------------------------------------------------------------------------
# CHIPSCOPE=1 \
# CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DAFU_DONE_WAIT_CACHE_DRAIN" \

srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=01:00:00 --pty bash -c '\
CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DAFU_DONE_WAIT_CACHE_DRAIN -DLMEM_LOG_SIZE=22" \
FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
DRIVER=xrt \
TARGET=hw \
CHIPSCOPE=1 \
./ci/blackbox.sh --threads=4 --cores=2 --driver=xrt --app=vecadd_multi_invoke --args="-n 65536  -r 1024" | tee bb.log
'

CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DAFU_DONE_WAIT_CACHE_DRAIN -DLMEM_LOG_SIZE=22" \
FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
DRIVER=xrt \
TARGET=hw \
./ci/blackbox.sh --threads=4 --cores=2 --driver=xrt --app=vecadd_multi_invoke --args="-n 65536  -r 1024" | tee bb.log

CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DAFU_DONE_WAIT_CACHE_DRAIN -DLMEM_LOG_SIZE=22" \
FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
DRIVER=xrt \
TARGET=hw \
CHIPSCOPE=1 \
./ci/blackbox.sh --threads=4 --cores=2 --driver=xrt --app=vecadd_multi_invoke --args="-n 65536  -r 1024" | tee bb.log

srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=01:00:00 --pty bash -c '\
CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DAFU_DONE_WAIT_CACHE_DRAIN" \
FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
DRIVER=xrt \
TARGET=hw \
CHIPSCOPE=1 \
./ci/blackbox.sh --threads=4 --cores=2 --driver=xrt --app=vecadd_multi_invoke --args="-n 65536  -r 1024" | tee bb.log
'

# ./ci/blackbox.sh --threads=8 --cores=1 --driver=xrt --app=vecadd_multi_invoke --args="-n 65536  -r 1024" | tee bb.log
# ./ci/blackbox.sh --cores=1 --driver=xrt --app=vecadd_multi_invoke --args="-n 16384  -r 32" | tee bb.log

FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/build_u55c_1c_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin \
TARGET=hw \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
./ci/blackbox.sh --cores=2 --driver=xrt --app=elunary --args="-op cos -n 32"

FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
DRIVER=xrt \
TARGET=hw \
DEBUG_LEVEL=3 \
DEBUG_XRT=1 \
./ci/blackbox.sh --cores=2 --driver=xrt --app=sgemm
