UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/lmem_weight_gather_dma

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs
TOP_MODULE := tb_lmem_weight_gather_dma

SRCS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/core/gemm/VX_lmem_dma_ctrl_if.sv \
        $(RTL_DIR)/core/gemm/VX_lmem_weight_gather_dma.sv \
        $(SRC_DIR)/tb_lmem_weight_gather_dma.sv

.PHONY: compile run

compile:
	mkdir -p logs
	$(SIM_EXEC) -full64 -sverilog -timescale=1ns/1ps \
		+incdir+$(RTL_DIR) +incdir+$(RTL_DIR)/core \
		+incdir+$(RTL_DIR)/core/gemm +incdir+$(RTL_DIR)/mem \
		+define+SIMULATION+XLEN_64+NUM_THREADS=16+GEMM_NAIVE \
		-top $(TOP_MODULE) $(SRCS) -o simv -l logs/compile.log

run:
	./simv -l logs/sim.log
