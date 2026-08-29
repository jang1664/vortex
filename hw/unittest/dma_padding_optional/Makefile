# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/dma_padding_optional

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs
TIME_SCALE := 1ns/1ps
TOP_MODULE ?= tb_VX_dma_padding_optional
DATA_SIZE ?= 64
NEGATIVE_PADDING ?= 0

TB := $(SRC_DIR)/tb_VX_dma_padding_optional.sv \
      $(SRC_DIR)/tb_VX_dma_padding_width_invalid.sv
LIB_RTLS := $(RTL_DIR)/libs/VX_shift_register.sv \
            $(RTL_DIR)/libs/VX_pipe_register.sv \
            $(RTL_DIR)/libs/VX_pipe_buffer.sv \
            $(RTL_DIR)/libs/VX_stream_buffer.sv \
            $(RTL_DIR)/libs/VX_placeholder.sv \
            $(RTL_DIR)/libs/VX_async_ram_patch.sv \
            $(RTL_DIR)/libs/VX_dp_ram_compiled.sv \
            $(RTL_DIR)/libs/VX_dp_ram.sv \
            $(RTL_DIR)/libs/VX_fifo_queue.sv \
            $(RTL_DIR)/libs/VX_elastic_buffer.sv \
            $(RTL_DIR)/libs/VX_mul_u32_pipe.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/core/VX_config_reg_if.sv \
        $(RTL_DIR)/core/VX_dma_lookahead_if.sv \
        $(RTL_DIR)/core/VX_node_done_if.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/core/VX_dma_unit_align.sv \
        $(LIB_RTLS)

INCDIRS_ := $(VORTEX_HOME)/build/hw \
            $(VORTEX_HOME)/hw \
            $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/core \
            $(RTL_DIR)/mem
DEFINES_ := SIMULATION NDEBUG MEM_ADDR_WIDTH=34

VL_INCDIRS := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))
empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))

ifeq ($(TOP_MODULE),tb_VX_dma_padding_optional)
ifeq ($(SIM_EXEC),vcs)
PARAMS := -pvalue+$(TOP_MODULE).DATA_SIZE=$(DATA_SIZE) \
          -pvalue+$(TOP_MODULE).NEGATIVE_PADDING=$(NEGATIVE_PADDING)
else
PARAMS := -GDATA_SIZE=$(DATA_SIZE) -GNEGATIVE_PADDING=$(NEGATIVE_PADDING)
endif
else
PARAMS :=
endif

BUILD_TAG := $(SIM_EXEC)_$(TOP_MODULE)_d$(DATA_SIZE)_p$(NEGATIVE_PADDING)
BUILD_DIR := logs/$(BUILD_TAG)
COMPILE_LOG := $(BUILD_DIR)/compile.log
SIM_LOG := $(BUILD_DIR)/sim.log

.PHONY: setup compile run sim

setup:
	mkdir -p $(BUILD_DIR)

include $(UNITTEST_DIR)/$(SIM_EXEC).mk

sim: run
