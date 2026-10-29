UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/sram_lmem_publish
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
TOP := tb_VX_sram_lmem_publish
LIBDIRS := $(RTL_DIR)/libs $(RTL_DIR)/core $(RTL_DIR)/core/gemm $(RTL_DIR)/mem $(RTL_DIR)/interfaces $(RTL_DIR)/cache
INCDIRS := $(ROOT_DIR)/hw $(RTL_DIR) $(LIBDIRS) $(SRC_DIR)
DEFS := $(patsubst -D%,+define+%,$(CONFIGS)) +define+SIMULATION +define+NDEBUG
.PHONY: compile run
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top $(TOP) -timescale=1ns/1ps -debug_access+all \
	  -cc /usr/bin/gcc -cpp /usr/bin/g++ +libext+.v+.sv \
	  $(foreach d,$(INCDIRS),+incdir+$(d)) $(foreach d,$(LIBDIRS),-y $(d)) $(DEFS) \
	  $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/mem/VX_mem_bus_if.sv \
	  $(RTL_DIR)/libs/VX_slr_stream.sv \
	  $(RTL_DIR)/mem/VX_lsu_mem_if.sv $(SRC_DIR)/$(TOP).sv -l logs/compile.log
run:
	./simv -l logs/sim.log
