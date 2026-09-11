UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_latency_observer
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TEST ?= controller
BACKEND ?= improve
EXTRA_SIM_ARGS ?=

ifneq ($(SIM_EXEC),vcs)
$(error This directed suite requires SIM_EXEC=vcs)
endif
ifeq ($(filter $(TEST),observer controller),)
$(error TEST must be observer or controller)
endif
ifeq ($(filter $(BACKEND),naive improve),)
$(error BACKEND must be naive or improve)
endif

TOP_MODULE := tb_$(TEST)
TB := $(SRC_DIR)/$(TOP_MODULE).sv
RTLS := $(RTL_DIR)/verification/VX_gemm_latency_observer.sv
ifeq ($(TEST),controller)
RTLS += $(RTL_DIR)/VX_gpu_pkg.sv \
    $(RTL_DIR)/core/VX_config_reg_if.sv \
    $(RTL_DIR)/core/VX_node_done_if.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
    $(RTL_DIR)/libs/VX_fifo_queue.sv \
    $(RTL_DIR)/libs/VX_pending_size.sv \
    $(RTL_DIR)/libs/VX_dp_ram.sv
ifeq ($(BACKEND),naive)
# Production metadata controller; share its independently checked endpoint test.
TOP_MODULE := tb_control
TB := $(VORTEX_HOME)/hw/unittest/naive_meta_control/tb_control.sv
RTLS += $(RTL_DIR)/mem/VX_mem_bus_if.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_ctrl_naive_meta_if.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_fsm_naive_meta.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_ctrl_naive_meta.sv \
    $(RTL_DIR)/core/gemm/VX_naive_source_join.sv \
    $(RTL_DIR)/core/gemm/VX_naive_gemm_control.sv
BACKEND_DEFINE := +define+GEMM_NAIVE
else
RTLS += $(RTL_DIR)/core/gemm/VX_gemm_ctrl_if.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_fsm_if.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_fsm.sv \
    $(RTL_DIR)/core/gemm/VX_microtile_readiness_scheduler.sv \
    $(RTL_DIR)/core/gemm/VX_gemm_ctrl.sv
endif
endif

CONFIG_DEFINES := $(patsubst -D%,+define+%,$(CONFIGS))
.PHONY: setup compile run
setup:
	mkdir -p logs

compile: setup
	vcs -full64 -sverilog -top $(TOP_MODULE) -timescale=1ns/1ps \
	    -debug_access+all +incdir+$(RTL_DIR) +define+SIMULATION \
	    +define+XLEN_$(XLEN) +define+GEMM_LATENCY_OBSERVER $(CONFIG_DEFINES) $(BACKEND_DEFINE) \
	    +libext+.sv -y $(RTL_DIR)/libs -y $(RTL_DIR)/mem -y $(RTL_DIR)/core $(RTLS) $(TB) -o simv -l logs/compile.log

run:
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
