# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/tmem_dma_pair_adapter

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_tmem_dma_pair_adapter

TB := $(SRC_DIR)/tb_VX_tmem_dma_pair_adapter.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/mem/VX_tmem_dma_pair_adapter.sv

INCDIRS_ := $(RTL_DIR) $(RTL_DIR)/mem
DEFINES_ := SIMULATION NDEBUG XLEN_64 MEM_ADDR_WIDTH=34

COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log

VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))
empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))

setup:
	mkdir -p logs reports

include vcs.mk
