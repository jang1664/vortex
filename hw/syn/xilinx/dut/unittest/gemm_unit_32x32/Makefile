# GEMM Unit Synthesis for Xilinx U55C
# Usage:
#   make build          - Run full synthesis and implementation
#   make gen-sources    - Generate source file list only
#   make clean          - Clean build artifacts

PROJECT = VX_gemm_unit_top
TOP_LEVEL_ENTITY = $(PROJECT)
FPU_IP = 1

include ../../common.mk

# third_party paths required for gen_sources.sh to successfully preprocess
# RTL_DIR contents (e.g. Vortex_axi.sv `include "axi/assign.svh"`).
THIRD_PARTY_AXI_DIR     := $(THIRD_PARTY_DIR)/axi
COMMON_CELLS_INC_DIR    := $(THIRD_PARTY_AXI_DIR)/.bender/git/checkouts/common_cells-3e2fcccecd7aee7b/include

# RTL include paths
RTL_INCLUDE = -I$(RTL_DIR) \
              -I$(RTL_DIR)/libs \
              -I$(RTL_DIR)/interfaces \
              -I$(RTL_DIR)/core \
              -I$(RTL_DIR)/core/gemm \
              -I$(RTL_DIR)/fpu \
              -I$(RTL_DIR)/mem \
              -I$(RTL_DIR)/verification \
              -I$(RTL_DIR)/tcu \
              -I$(THIRD_PARTY_AXI_DIR)/include \
              -I$(COMMON_CELLS_INC_DIR)

# Additional defines (optional)
# CONFIGS += -DDBG_TRACE_GEMM