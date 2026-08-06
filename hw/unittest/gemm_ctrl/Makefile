# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_ctrl

# Use the system compiler for host-side simulator compilation.
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_gemm_ctrl

#PIPE_MULT ?= 1
#PIPE_ALIGN ?= 1
#PIPE_INTERVAL ?= 2


TB   := $(SRC_DIR)/tb_VX_gemm_ctrl.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
				$(RTL_DIR)/core/gemm/VX_gemm_ctrl.sv \
				$(RTL_DIR)/core/VX_config_reg_if.sv \
				$(RTL_DIR)/core/VX_node_done_if.sv \
				$(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
				$(RTL_DIR)/core/gemm/VX_gemm_ctrl_if.sv \
				$(RTL_DIR)/core/gemm/VX_gemm_fsm_if.sv \
				$(RTL_DIR)/core/gemm/VX_gemm_fsm.sv \
				$(RTL_DIR)/libs/VX_fifo_queue.sv \
				$(RTL_DIR)/libs/VX_pending_size.sv \
				$(RTL_DIR)/libs/VX_dp_ram.sv 
				
#PARAMS_  := PIPE_MULT=$(PIPE_MULT) PIPE_ALIGN=$(PIPE_ALIGN) PIPE_INTERVAL=$(PIPE_INTERVAL)
INCDIRS_ := $(RTL_DIR)
DEFINES_ := SIMULATION DEBUG_LEVEL=3 DBG_TRACE_GEMM
CONFIG_DEFINES := $(patsubst -D%,%,$(CONFIGS))
DEFINES_ += $(CONFIG_DEFINES)

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

VL_INCDIRS  := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS  := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES  := +define+$(subst $(space),+,$(DEFINES_))

PARAMS := 
EXTRA_SIM_ARGS ?=

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk

fst2vcd:
	for file in reports/*.fst; do \
	  fst2vcd $$file -o reports/$${file##*/}.vcd; \
	done

vcd2fsdb:
	for file in reports/*.vcd; do \
	  vcd2fsdb $$file -o reports/$${file##*/}.fsdb; \
	done

fst2fsdb:
	for file in reports/*.fst; do \
	  fst2vcd $$file -o reports/$${file##*/}.vcd; \
	  vcd2fsdb  reports/$${file##*/}.vcd -o reports/$${file##*/}.fsdb; \
	  rm reports/$${file##*/}.vcd; \
	done

clean:
	rm -rf obj_dir 
	rm -rf reports logs 
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
