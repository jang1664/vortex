# Include only from a configured build/hw/unittest/<test>/Makefile.
ROOT_DIR := $(abspath ../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
TASK_DIR := $(VORTEX_HOME)/agent-tasks/u55c-slr-floorplan-pipeline/mxu-control-preserve
SLR_MODE ?= 1
TEST_CONFIGS := $(CONFIGS)
ifeq ($(SLR_MODE),0)
TEST_CONFIGS := $(filter-out -DGEMM_SLR_PIPELINE,$(TEST_CONFIGS))
endif
VC_CONFIGS := $(patsubst -D%,+define+%,$(filter -D%,$(TEST_CONFIGS)))
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
.PHONY: compile run
compile:
	python3 $(TASK_DIR)/extract_registers.py generated
	mkdir -p logs
	vcs -full64 -sverilog -top tb_mxu_registers -timescale=1ns/1ps \
	  +incdir+$(RTL_DIR) +incdir+$(RTL_DIR)/libs \
	  +define+SIMULATION +define+XLEN_64 $(VC_CONFIGS) \
	  $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/libs/VX_pipe_buffer.sv \
	  $(RTL_DIR)/libs/VX_pipe_register.sv $(RTL_DIR)/libs/VX_shift_register.sv \
	  generated/extracted_mxu_registers.sv $(TASK_DIR)/tb_mxu_registers.sv \
	  -l logs/compile.log
run:
	./simv -l logs/sim.log
