UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_dma_slr_bridge
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
EXTRA_SIM_ARGS ?=
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_gemm_dma_slr_bridge
TB := $(SRC_DIR)/tb_gemm_dma_slr_bridge.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_dma_ctrl_if.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
        $(RTL_DIR)/libs/VX_slr_stream.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_dma_slr_bridge.sv
VC_INCDIRS := +incdir+$(RTL_DIR)
DEFINES := +define+SIMULATION $(patsubst -D%,+define+%,$(CONFIGS))
COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log

.PHONY: setup compile sim
setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk
