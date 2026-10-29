UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/sram_dma
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TOP_MODULE := tb_VX_sram_dma
TB := $(SRC_DIR)/tb_VX_sram_dma.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/core/VX_sram_dma.sv
INCDIRS := $(RTL_DIR) $(RTL_DIR)/mem $(RTL_DIR)/core
DEFINES := $(patsubst -D%,+define+%,$(CONFIGS)) +define+SIMULATION +define+NDEBUG
COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log

.PHONY: compile run sim
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top $(TOP_MODULE) -timescale=1ns/1ps \
	  -cc /usr/bin/gcc -cpp /usr/bin/g++ -debug_access+all \
	  $(foreach dir,$(INCDIRS),+incdir+$(dir)) $(DEFINES) \
	  $(RTLS) $(TB) $(PARAMS) -l $(COMPILE_LOG)

run:
	./simv $(EXTRA_SIM_ARGS) -l $(SIM_LOG)

sim: run
