UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/slr_mem_bus
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
EXTRA_SIM_ARGS ?=
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv \
        $(RTL_DIR)/libs/VX_slr_stream.sv \
        $(RTL_DIR)/libs/VX_stream_transport.sv \
        $(RTL_DIR)/mem/VX_slr_mem_bus.sv
DEFINES := +define+SIMULATION $(patsubst -D%,+define+%,$(CONFIGS))
.PHONY: setup compile sim
setup:
	mkdir -p logs reports
include $(SIM_EXEC).mk
