# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/afu_ctrl

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vlt

TOP_MODULE := tb_VX_afu_ctrl

TB   := $(SRC_DIR)/tb_VX_afu_ctrl.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/afu/xrt/VX_afu_ctrl.sv

INCDIRS_ := $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/afu/xrt
DEFINES_ := SIMULATION XLEN_64

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

VL_INCDIRS := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))

PARAMS :=

setup:
	mkdir -p logs reports

run: sim

include $(SIM_EXEC).mk
