UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/lmem_invalid
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
ifneq ($(SIM_EXEC),vcs)
$(error Capacity suite requires SIM_EXEC=vcs)
endif
CONFIG_DEFINES := $(patsubst -D%,+define+%,$(CONFIGS))
.PHONY: compile run
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top tb_lmem_invalid -timescale=1ns/1ps \
	    +incdir+$(RTL_DIR) +define+SIMULATION +define+XLEN_$(XLEN) $(CONFIG_DEFINES) \
	    +libext+.sv -y $(RTL_DIR)/libs -y $(RTL_DIR)/mem \
	    $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/mem/VX_mem_bus_if.sv \
	    $(RTL_DIR)/mem/VX_local_mem.sv $(SRC_DIR)/tb_lmem_invalid.sv \
	    -o simv -l logs/compile.log
run:
	python3 $(SRC_DIR)/check_negative.py
