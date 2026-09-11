UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_naive_meta
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TEST ?= controller
BACKEND ?= naive
EXTRA_SIM_ARGS ?=
ifneq ($(SIM_EXEC),vcs)
$(error This suite requires SIM_EXEC=vcs)
endif
ifeq ($(filter $(TEST),controller types),)
$(error TEST must be controller or types)
endif
ifeq ($(filter $(BACKEND),naive improve),)
$(error BACKEND must be naive or improve)
endif

TOP_MODULE := tb_$(TEST)
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv
ifeq ($(BACKEND),naive)
BACKEND_DEFINE := +define+GEMM_NAIVE
endif
ifeq ($(TEST),controller)
ifneq ($(BACKEND),naive)
$(error The staged controller requires BACKEND=naive)
endif
RTLS += $(RTL_DIR)/libs/VX_pending_size.sv \
    $(RTL_DIR)/libs/VX_dp_ram.sv \
    $(RTL_DIR)/libs/VX_fifo_queue.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_ctrl_naive_meta_if.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_ctrl_naive_meta.sv
endif
CONFIG_DEFINES := $(patsubst -D%,+define+%,$(CONFIGS))
.PHONY: setup compile run
setup:
	mkdir -p logs
compile: setup
	vcs -full64 -sverilog -top $(TOP_MODULE) -timescale=1ns/1ps \
	    -debug_access+all +incdir+$(RTL_DIR) +define+SIMULATION +define+XLEN_$(XLEN) \
	    $(CONFIG_DEFINES) $(BACKEND_DEFINE) $(RTLS) \
	    $(SRC_DIR)/$(TOP_MODULE).sv -o simv -l logs/compile.log
run:
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
