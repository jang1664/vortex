# Include Vortex configuration
ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/build/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
# export CC := /usr/bin/gcc-11
# export CXX := /usr/bin/g++-11

# Default simulator
SIM_EXEC ?= vcs

.PHONY: setup clean compile sim
.NOTPARALLEL:

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_pint2fp

TB   := tb_VX_pint2fp.sv
RTLS := $(RTL_DIR)/core/gemm/VX_pint2fp.sv \
		$(RTL_DIR)/libs/VX_lzc.sv \
		$(RTL_DIR)/libs/VX_find_first.sv \
		$(RTL_DIR)/libs/VX_elastic_buffer.sv \
		$(RTL_DIR)/libs/VX_pipe_buffer.sv \
		$(RTL_DIR)/libs/VX_pipe_register.sv \
		$(RTL_DIR)/libs/VX_shift_register.sv

PARAMS_  :=
INCDIRS_ := $(RTL_DIR) $(VORTEX_HOME)/hw
DEFINES_ := SIMULATION DEBUG_LEVEL=3 DBG_TRACE_GEMM

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

VL_INCDIRS  := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS  := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES  := +define+$(subst $(space),+,$(DEFINES_))

PARAMS := $(foreach p,$(PARAMS_),-pvalue+$(p))

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk

clean:
	rm -rf obj_dir
	rm -rf reports logs
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
