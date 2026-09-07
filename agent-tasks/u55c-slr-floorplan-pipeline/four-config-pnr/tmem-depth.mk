# Invoke from a configured build's hw/unittest/tmem_depth directory.
ROOT_DIR := $(abspath ../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
TASK_DIR := $(VORTEX_HOME)/agent-tasks/u55c-slr-floorplan-pipeline/four-config-pnr
TB := $(TASK_DIR)/tb_tmem_depth.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/mem/VX_mem_arb.sv $(RTL_DIR)/mem/VX_tensor_mem_bank.sv \
        $(filter-out %_tb.sv,$(wildcard $(RTL_DIR)/libs/*.sv))
VC_CONFIGS := $(patsubst -D%,+define+%,$(filter -D%,$(CONFIGS)))
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
.PHONY: compile run
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top tb_tmem_depth -timescale=1ns/1ps \
	  +incdir+$(RTL_DIR) +incdir+$(RTL_DIR)/libs +incdir+$(RTL_DIR)/mem \
	  +define+SIMULATION +define+XLEN_64 $(VC_CONFIGS) $(RTLS) $(TB) \
	  -l logs/compile.log
run:
	./simv -l logs/sim.log
