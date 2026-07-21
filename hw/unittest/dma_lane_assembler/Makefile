# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/dma_lane_assembler

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs

TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_dma_lane_assembler

TB := $(SRC_DIR)/tb_VX_dma_lane_assembler.sv
RTLS := $(RTL_DIR)/core/VX_dma_lane_assembler.sv

INCDIRS_ := $(VORTEX_HOME)/build/hw \
            $(VORTEX_HOME)/hw \
            $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/core

DEFINES_ := SIMULATION DEBUG_LEVEL=3

CFLAGS := "-std=c++17 -Wall -Wextra -fPIC -I$(VORTEX_HOME)/build/hw -I$(VORTEX_HOME)/hw -I$(RTL_DIR) -DXLEN_$(XLEN)"
LDFLAGS :=
DPI_SRCS :=
SOFTFLOAT_LIB :=
PARAMS :=
SIM_ARGS ?=

COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log

VL_INCDIRS := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))

setup:
	mkdir -p logs reports

include $(UNITTEST_DIR)/$(SIM_EXEC).mk
