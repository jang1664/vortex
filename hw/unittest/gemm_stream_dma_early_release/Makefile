UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_stream_dma_early_release
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
RTLS := $(RTL_DIR)/core/gemm/VX_gemm_dma_fetch_if.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_dma_sink_if.sv \
        $(RTL_DIR)/libs/VX_dp_ram.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_stream_dma_queue.sv
DEFINES := +define+SIMULATION+NDEBUG $(patsubst -D%,+define+%,$(CONFIGS))
.PHONY: setup compile run sim
setup:
	mkdir -p logs reports
run: sim
include $(SIM_EXEC).mk
