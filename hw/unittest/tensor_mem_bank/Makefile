# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/tensor_mem_bank

# Use system-default GCC toolchain available in this environment.
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vlt

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_tensor_mem_bank

TB   := $(SRC_DIR)/tb_VX_tensor_mem_bank.sv

LIB_RTLS := $(filter-out %_tb.sv,$(wildcard $(RTL_DIR)/libs/*.sv))

RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
				$(RTL_DIR)/mem/VX_mem_bus_if.sv \
				$(RTL_DIR)/mem/VX_mem_arb.sv \
				$(RTL_DIR)/mem/VX_tensor_mem_bank.sv \
				$(LIB_RTLS)

INCDIRS_ := $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/mem
DEFINES_ := SIMULATION NDEBUG

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

VL_INCDIRS := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))

TB_ENABLE_URGENCY ?= 1
ifeq ($(SIM_EXEC),vcs)
PARAMS := -pvalue+$(TOP_MODULE).TB_ENABLE_URGENCY=$(TB_ENABLE_URGENCY)
else
PARAMS := -GTB_ENABLE_URGENCY=$(TB_ENABLE_URGENCY)
endif

setup:
	mkdir -p logs reports

run: sim

include $(SIM_EXEC).mk

clean:
	rm -rf obj_dir
	rm -rf reports logs
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
