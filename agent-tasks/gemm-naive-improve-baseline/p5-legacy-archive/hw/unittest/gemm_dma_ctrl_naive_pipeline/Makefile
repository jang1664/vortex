UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_dma_ctrl_naive_pipeline

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_gemm_dma_ctrl_naive_pipeline

TB := $(SRC_DIR)/tb_VX_gemm_dma_ctrl_naive_pipeline.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
	$(RTL_DIR)/mem/VX_lsu_mem_if.sv \
	$(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
	$(RTL_DIR)/core/gemm/VX_gemm_dma_ctrl_naive_if.sv \
	$(RTL_DIR)/core/gemm/VX_gemm_dma_ctrl_naive.sv

INCDIRS := $(VORTEX_HOME)/hw \
	$(RTL_DIR) \
	$(RTL_DIR)/libs \
	$(RTL_DIR)/mem \
	$(RTL_DIR)/core \
	$(RTL_DIR)/core/gemm

DEFINES := +define+SIMULATION+XLEN_64+GEMM_NAIVE \
	+JOB_MMIO_DMA_DESC_ONE_LANE \
	+PLATFORM_MEMORY_DATA_SIZE=64 \
	+PLATFORM_MEMORY_ID_WIDTH=32

COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log
VC_INCDIRS := $(foreach dir,$(INCDIRS),+incdir+$(dir))

.PHONY: setup compile run

setup:
	mkdir -p logs

compile: setup
	vcs -sverilog -full64 -timescale=$(TIME_SCALE) \
		-top $(TOP_MODULE) \
		-l $(COMPILE_LOG) \
		$(VC_INCDIRS) \
		$(DEFINES) \
		$(RTLS) \
		$(TB)

run:
	./simv -reportstats -l $(SIM_LOG)
