# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_sync

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs

TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_gemm_sync

TB := $(SRC_DIR)/tb_VX_gemm_sync.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
		$(RTL_DIR)/core/gemm/VX_gemm_fsm_if.sv \
		$(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
		$(RTL_DIR)/core/gemm/VX_gemm_sync.sv

INCDIRS_ := $(RTL_DIR)
DEFINES_ := SIMULATION

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

