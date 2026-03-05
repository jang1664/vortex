#!/bin/bash
set -euo pipefail

CONFIGS="-DFPU_FPNEW -DDBG_TRACE_GEMM_FSM \
  -DNUM_CORES=1 -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34"

# ------------------------------------------------------------------------
# - Add DBG flag if you want
# ------------------------------------------------------------------------
# CONFIGS+=" -DDBG_TRACE_PIPELINE"
# CONFIGS+=" -DDBG_TRACE_MEM"
# CONFIGS+=" -DDBG_TRACE_CACHE"
# CONFIGS+=" -DDBG_TRACE_AFU"
# CONFIGS+=" -DDBG_TRACE_SCOPE"
# CONFIGS+=" -DDBG_TRACE_GBAR"
# CONFIGS+=" -DDBG_TRACE_TCU"
# CONFIGS+=" -DDBG_TRACE_GEMM"
# CONFIGS+=" -DNUM_CORES=2"
# CONFIGS+=" -DVCD_OUTPUT"

export VERILATOR_SEED=$((RANDOM + 1))

DEBUG_LEVEL=0

if [[ "${DEBUG_LEVEL}" -eq 0 ]]; then
  if [[ "${CONFIGS}" == *"-DVCD_OUTPUT"* ]]; then
    # drop VCD_OUTPUT if DEBUG_LEVEL is 0, since it generates huge log files and isn't useful without debug messages
    CONFIGS="${CONFIGS//-DVCD_OUTPUT/}"
  fi
fi

export CONFIGS
# ------------------------------------------------------------------------
# - clean if you want
# ------------------------------------------------------------------------
# make -C runtime/rtlsim clean

# ------------------------------------------------------------------------
# - rtl
# ------------------------------------------------------------------------
DRIVER=rtlsim \
DEBUG_LEVEL=${DEBUG_LEVEL} \
bash tests/regression/fpint_gemm_ffn_hw/test.sh "$@"

# ------------------------------------------------------------------------
# - xrt + rtl
# ------------------------------------------------------------------------
# DRIVER=xrt \
# DEBUG_LEVEL=${DEBUG_LEVEL} \
# bash tests/regression/fpint_gemm_ffn_hw/test.sh "$@"

# ------------------------------------------------------------------------
# - xrt + hw_emul
# ------------------------------------------------------------------------
# FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw_emu/bin \
# TARGET=hw_emu \
# PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
# DRIVER=xrt \
# DEBUG_LEVEL=${DEBUG_LEVEL} \
# bash tests/regression/fpint_gemm_ffn_hw/test.sh "$@"

# ------------------------------------------------------------------------
# - FPGA
# ------------------------------------------------------------------------
# FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
# TARGET=hw \
# PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
# DRIVER=xrt \
# CHIPSCOPE=1 \
# DEBUG_LEVEL=${DEBUG_LEVEL} \
# bash tests/regression/fpint_gemm_ffn_hw/test.sh "$@"