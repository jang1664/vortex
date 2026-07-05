# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/axi_write_drain

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vlt

TOP_MODULE := tb_VX_axi_write_drain

TB   := $(SRC_DIR)/tb_VX_axi_write_drain.sv
RTLS := $(RTL_DIR)/libs/VX_axi_write_drain.sv

INCDIRS_ := $(RTL_DIR) \
            $(RTL_DIR)/libs
DEFINES_ := SIMULATION

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
