# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/lmem_dma_input_overlap

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_lmem_dma_input_overlap

TB := $(SRC_DIR)/tb_VX_lmem_dma_input_overlap.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
	$(RTL_DIR)/mem/VX_mem_bus_if.sv \
	$(RTL_DIR)/core/gemm/VX_lmem_dma_ctrl_if.sv \
	$(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
	$(RTL_DIR)/libs/VX_dp_ram.sv \
	$(RTL_DIR)/core/gemm/VX_lmem_dma_misal.sv

INCDIRS_ := $(RTL_DIR) $(RTL_DIR)/mem $(RTL_DIR)/core/gemm $(RTL_DIR)/libs
DEFINES_ := SIMULATION NDEBUG DEBUG_LEVEL=3 DBG_TRACE_GEMM XLEN_64 \
	MEM_ADDR_WIDTH=34 GEMM_IMPROVE MXU_WLOAD_NUM=8 \
	W_LMEM_DMA_CMD_BEATS=4 W_LMEM_DMA_RESPONSE_SLOTS=8
CONFIG_DEFINES := $(patsubst -D%,%,$(CONFIGS))
DEFINES_ += $(CONFIG_DEFINES)

COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log
VL_INCDIRS := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))
empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))
PARAMS :=

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk
