# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_dma_interfaces

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_gemm_dma_interfaces

TB := $(SRC_DIR)/tb_VX_gemm_dma_interfaces.sv
RTLS := $(RTL_DIR)/core/gemm/VX_gemm_dma_fetch_if.sv \
	$(RTL_DIR)/core/gemm/VX_gemm_dma_sink_if.sv

INCDIRS_ := $(VORTEX_HOME)/build/hw $(VORTEX_HOME)/hw $(RTL_DIR) \
	$(RTL_DIR)/core/gemm
DEFINES_ := SIMULATION NDEBUG
CONFIG_DEFINES := $(patsubst -D%,%,$(CONFIGS))
DEFINES_ += $(CONFIG_DEFINES)
COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))
empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))
PARAMS :=

setup:
	mkdir -p logs reports

run: sim

include $(SIM_EXEC).mk
