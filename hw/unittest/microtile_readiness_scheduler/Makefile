# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/microtile_readiness_scheduler

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vlt
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_microtile_readiness_scheduler

TB := $(SRC_DIR)/tb_VX_microtile_readiness_scheduler.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
	$(RTL_DIR)/core/gemm/VX_microtile_readiness_scheduler.sv

INCDIRS_ := $(RTL_DIR) $(RTL_DIR)/core/gemm
DEFINES_ := SIMULATION NDEBUG
COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log
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
