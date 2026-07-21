# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/dma_gearbox

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs

TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_dma_gearbox
INVALID_TOP_MODULE := tb_VX_dma_gearbox_invalid

TB := $(SRC_DIR)/tb_VX_dma_gearbox.sv
INVALID_TB := $(SRC_DIR)/tb_VX_dma_gearbox_invalid.sv
RTLS := $(RTL_DIR)/core/VX_dma_gearbox.sv

INCDIRS_ := $(RTL_DIR)
DEFINES_ := SIMULATION

COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log

VL_INCDIRS := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk

run: sim

invalid:
	$(MAKE) invalid_case INVALID_NAME=non_divisible INVALID_IN_BYTES=96 INVALID_OUT_BYTES=256
	$(MAKE) invalid_case INVALID_NAME=non_power INVALID_IN_BYTES=96 INVALID_OUT_BYTES=192
	$(MAKE) invalid_case INVALID_NAME=out_of_range INVALID_IN_BYTES=64 INVALID_OUT_BYTES=1024
	$(MAKE) invalid_case INVALID_NAME=below_range INVALID_IN_BYTES=8 INVALID_OUT_BYTES=64

.PHONY: setup run invalid
