# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/hw_debug

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs

TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_hw_debug

TB := $(SRC_DIR)/tb_VX_hw_debug.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
		$(RTL_DIR)/afu/xrt/VX_hw_debug.sv

INCDIRS_ := $(RTL_DIR)
DEFINES_ := SIMULATION ENABLE_HW_DEBUG_MODULE ENABLE_HW_DEBUG_AXI PLATFORM_MEMORY_ID_WIDTH=4

COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log

VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))
PARAMS :=

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk
