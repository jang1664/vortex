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
DIM_COMPARE ?= 0
SPECIAL_MAX_DIMS ?= 3
NEGATIVE_BOUND ?= 0
NEGATIVE_INACTIVE ?= 0
INVALID_MAX_DIMS ?= 0
USE_MISALIGN ?= 0

TB := $(SRC_DIR)/tb_VX_dma_padding_optional.sv \
      $(SRC_DIR)/tb_VX_dma_padding_width_invalid.sv \
      $(SRC_DIR)/tb_VX_dma_max_dims_invalid.sv
LIB_RTLS := $(RTL_DIR)/libs/VX_shift_register.sv \
            $(RTL_DIR)/libs/VX_pipe_register.sv \
            $(RTL_DIR)/libs/VX_pipe_buffer.sv \
            $(RTL_DIR)/libs/VX_stream_buffer.sv \
            $(RTL_DIR)/libs/VX_placeholder.sv \
            $(RTL_DIR)/libs/VX_async_ram_patch.sv \
            $(RTL_DIR)/libs/VX_dp_ram_compiled.sv \
            $(RTL_DIR)/libs/VX_dp_ram.sv \
            $(RTL_DIR)/libs/VX_fifo_queue.sv \
            $(RTL_DIR)/libs/VX_pending_size.sv \
            $(RTL_DIR)/libs/VX_elastic_buffer.sv \
            $(RTL_DIR)/libs/VX_mul_u32_pipe.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/core/VX_config_reg_if.sv \
        $(RTL_DIR)/core/VX_dma_lookahead_if.sv \
        $(RTL_DIR)/core/VX_node_done_if.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/core/VX_dma_unit_align.sv \
        $(RTL_DIR)/core/VX_dma_gearbox.sv \
        $(RTL_DIR)/core/VX_dma_lane_aligner.sv \
        $(RTL_DIR)/core/VX_dma_lane_assembler.sv \
        $(RTL_DIR)/core/VX_dma_equal_realigner.sv \
        $(RTL_DIR)/core/VX_dma_misal_gen_path.sv \
        $(RTL_DIR)/core/VX_dma_unit_misal.sv \
        $(RTL_DIR)/core/VX_dma_unit.sv \
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
          -pvalue+$(TOP_MODULE).NEGATIVE_PADDING=$(NEGATIVE_PADDING) \
          -pvalue+$(TOP_MODULE).DIM_COMPARE=$(DIM_COMPARE) \
          -pvalue+$(TOP_MODULE).SPECIAL_MAX_DIMS=$(SPECIAL_MAX_DIMS) \
          -pvalue+$(TOP_MODULE).NEGATIVE_BOUND=$(NEGATIVE_BOUND) \
          -pvalue+$(TOP_MODULE).NEGATIVE_INACTIVE=$(NEGATIVE_INACTIVE) \
          -pvalue+$(TOP_MODULE).USE_MISALIGN=$(USE_MISALIGN)
else
PARAMS := -GDATA_SIZE=$(DATA_SIZE) -GNEGATIVE_PADDING=$(NEGATIVE_PADDING) \
          -GDIM_COMPARE=$(DIM_COMPARE) \
          -GSPECIAL_MAX_DIMS=$(SPECIAL_MAX_DIMS) \
          -GNEGATIVE_BOUND=$(NEGATIVE_BOUND) \
          -GNEGATIVE_INACTIVE=$(NEGATIVE_INACTIVE) \
          -GUSE_MISALIGN=$(USE_MISALIGN)
endif
else ifeq ($(TOP_MODULE),tb_VX_dma_max_dims_invalid)
ifeq ($(SIM_EXEC),vcs)
PARAMS := -pvalue+$(TOP_MODULE).INVALID_MAX_DIMS=$(INVALID_MAX_DIMS)
else
PARAMS := -GINVALID_MAX_DIMS=$(INVALID_MAX_DIMS)
endif
else
PARAMS :=
endif

BUILD_TAG := $(SIM_EXEC)_$(TOP_MODULE)_d$(DATA_SIZE)_p$(NEGATIVE_PADDING)_m$(SPECIAL_MAX_DIMS)_c$(DIM_COMPARE)_b$(NEGATIVE_BOUND)_i$(NEGATIVE_INACTIVE)_x$(INVALID_MAX_DIMS)_u$(USE_MISALIGN)
BUILD_DIR := logs/$(BUILD_TAG)
COMPILE_LOG := $(BUILD_DIR)/compile.log
SIM_LOG := $(BUILD_DIR)/sim.log

.PHONY: setup compile run sim

setup:
	mkdir -p $(BUILD_DIR)

include $(UNITTEST_DIR)/$(SIM_EXEC).mk

sim: run
