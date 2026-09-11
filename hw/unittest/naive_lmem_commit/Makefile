UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/naive_lmem_commit
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
ifneq ($(SIM_EXEC),vcs)
$(error This suite requires SIM_EXEC=vcs)
endif
CONFIG_DEFINES := $(patsubst -D%,+define+%,$(CONFIGS))
.PHONY: compile run
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top tb_commit -timescale=1ns/1ps \
	    +incdir+$(RTL_DIR) +define+SIMULATION +define+XLEN_$(XLEN) $(CONFIG_DEFINES) \
	    +libext+.sv -y $(RTL_DIR)/libs -y $(RTL_DIR)/mem -y $(RTL_DIR)/core \
	    $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/mem/VX_mem_bus_if.sv \
	    $(RTL_DIR)/core/VX_naive_dma_write_fence.sv \
	    $(RTL_DIR)/mem/VX_naive_lmem_commit_decode.sv \
	    $(RTL_DIR)/mem/VX_local_mem.sv $(SRC_DIR)/tb_commit.sv \
	    -o simv -l logs/compile.log
run:
	./simv -l logs/sim.log
