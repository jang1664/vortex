UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/sram_lsu_transport
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TOP_MODULE := tb_VX_sram_lsu_transport
TEST_DESTINATION_SLOTS ?= 3
TB := $(SRC_DIR)/tb_VX_sram_lsu_transport.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/mem/VX_lsu_mem_if.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_slr_stream.sv \
        $(RTL_DIR)/core/VX_sram_lsu_transport.sv
INCDIRS := $(RTL_DIR) $(RTL_DIR)/mem $(RTL_DIR)/libs $(RTL_DIR)/core
DEFINES := $(patsubst -D%,+define+%,$(CONFIGS)) +define+SIMULATION +define+NDEBUG

.PHONY: compile run sim
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top $(TOP_MODULE) -timescale=1ns/1ps \
	  -cc /usr/bin/gcc -cpp /usr/bin/g++ -debug_access+all \
	  $(foreach dir,$(INCDIRS),+incdir+$(dir)) $(DEFINES) \
	  $(RTLS) $(TB) -pvalue+$(TOP_MODULE).DESTINATION_READ_SLOTS=$(TEST_DESTINATION_SLOTS) \
	  $(PARAMS) -l logs/compile.log
run:
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
sim: run
