# GEMM Unit Synthesis for Xilinx U55C
# Usage:
#   make build          - Run full synthesis and implementation
#   make gen-sources    - Generate source file list only
#   make clean          - Clean build artifacts

PROJECT = VX_gemm_unit_top
TOP_LEVEL_ENTITY = $(PROJECT)
FPU_IP = 1

include ../../common.mk

# RTL include paths
RTL_INCLUDE = -I$(RTL_DIR) \
              -I$(RTL_DIR)/libs \
              -I$(RTL_DIR)/interfaces \
              -I$(RTL_DIR)/core \
              -I$(RTL_DIR)/core/gemm \
              -I$(RTL_DIR)/fpu \
              -I$(RTL_DIR)/mem

# Additional defines (optional)
# CONFIGS += -DDBG_TRACE_GEMM