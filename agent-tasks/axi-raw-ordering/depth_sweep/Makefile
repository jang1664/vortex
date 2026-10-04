# Copy into an existing configured build's hw/unittest/axi_write_depth_sweep/.
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/agent-tasks/axi-raw-ordering/depth_sweep
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TOP_MODULE := tb_write_depth_sweep
TB := $(VORTEX_HOME)/hw/unittest/axi_adapter/tb_VX_axi_adapter.sv $(SRC_DIR)/tb_write_depth_sweep.sv $(SRC_DIR)/axi_write_depth_monitor.sv
RTLS := $(RTL_DIR)/core/VX_mem_remap.sv $(RTL_DIR)/libs/VX_axi_adapter.sv
INCDIRS := $(ROOT_DIR)/hw $(RTL_DIR) $(RTL_DIR)/libs $(RTL_DIR)/core
DEFINES := +define+SIMULATION+VCS+XLEN_64+PLATFORM_MEMORY_ADDR_WIDTH=34+PLATFORM_MEMORY_NUM_BANKS=32+PLATFORM_MEMORY_INTERLEAVE=1+PLATFORM_MEMORY_REMAP+NUM_HBM_PORTS=8
SIMV ?= simv
COMPILE_LOG ?= logs/compile.log
.PHONY: setup run
setup:
	mkdir -p logs
run: sim
include $(VORTEX_HOME)/hw/unittest/axi_adapter/vcs.mk
