# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/build/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

# Default simulator
SIM_EXEC ?= vcs

.PHONY: setup clean compile sim
.NOTPARALLEL:

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_reformatter

TB   := $(UNITTEST_DIR)/tb_VX_reformatter.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/core/gemm/VX_reformatter.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_skid_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv

INCDIRS_ := $(RTL_DIR) $(VORTEX_HOME)/hw
DEFINES_ := SIMULATION DEBUG_LEVEL=3

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

VC_INCDIRS  := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES  := +define+$(subst $(space),+,$(DEFINES_))

setup:
	mkdir -p logs reports

clean:
	rm -rf obj_dir
	rm -rf reports logs
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*

# VCS Rules
ifeq ($(SIM_EXEC), vcs)
compile: setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-debug_access+all \
	-l $(COMPILE_LOG) \
	-timescale=$(TIME_SCALE) \
	+libext+.v+ \
	${VC_INCDIRS} \
	$(DEFINES) \
	$(RTLS) \
	$(TB)

sim: compile
	./simv -reportstats -l $(SIM_LOG)
else
# Fallback or Error
compile:
	@echo "Simulator $(SIM_EXEC) not supported in this inline Makefile yet"
	@exit 1
endif
