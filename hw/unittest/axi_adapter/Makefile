UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/axi_adapter
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TOP_MODULE := tb_VX_axi_adapter
TB := $(SRC_DIR)/tb_VX_axi_adapter.sv
ADAPTER_RTL ?= $(RTL_DIR)/libs/VX_axi_adapter.sv
RTLS := $(RTL_DIR)/core/VX_mem_remap.sv $(ADAPTER_RTL)
INCDIRS := $(ROOT_DIR)/hw $(RTL_DIR) $(RTL_DIR)/libs $(RTL_DIR)/core
# Keep the test geometry explicit, independent of a sourced kernel profile.
# Assertions remain enabled; compressed tags are configured in the testbench.
DEFINES := +define+SIMULATION+VCS+XLEN_64+PLATFORM_MEMORY_ADDR_WIDTH=34+PLATFORM_MEMORY_NUM_BANKS=32+PLATFORM_MEMORY_INTERLEAVE=1+PLATFORM_MEMORY_REMAP+NUM_HBM_PORTS=8

SIMV ?= simv
COMPILE_LOG ?= logs/compile.log
.PHONY: setup run check-invalid
setup:
	mkdir -p logs
run: sim
check-invalid:
	python3 $(SRC_DIR)/check_invalid.py
include $(SIM_EXEC).mk
