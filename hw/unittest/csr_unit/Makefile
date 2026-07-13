UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/csr_unit

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vlt
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_csr_unit
TB := $(SRC_DIR)/tb_VX_csr_unit.sv

LIB_RTLS := $(RTL_DIR)/libs/VX_shift_register.sv \
            $(RTL_DIR)/libs/VX_pipe_register.sv \
            $(RTL_DIR)/libs/VX_pipe_buffer.sv \
            $(RTL_DIR)/libs/VX_stream_buffer.sv \
            $(RTL_DIR)/libs/VX_elastic_buffer.sv
IF_RTLS := $(RTL_DIR)/interfaces/VX_commit_csr_if.sv \
           $(RTL_DIR)/interfaces/VX_sched_csr_if.sv \
           $(RTL_DIR)/interfaces/VX_execute_if.sv \
           $(RTL_DIR)/interfaces/VX_result_if.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/fpu/VX_fpu_pkg.sv \
        $(RTL_DIR)/fpu/VX_fpu_csr_if.sv \
        $(IF_RTLS) \
        $(LIB_RTLS) \
        $(RTL_DIR)/core/VX_csr_data.sv \
        $(RTL_DIR)/core/VX_csr_unit.sv

INCDIRS_ := $(RTL_DIR) $(RTL_DIR)/libs $(RTL_DIR)/interfaces $(RTL_DIR)/core $(RTL_DIR)/fpu
DEFINES_ := SIMULATION XLEN_64 PERF_ENABLE NDEBUG

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
