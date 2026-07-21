# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/dma_engine

# Use system-default GCC toolchain available in this environment.
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vlt

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_dma_engine

TB   := $(SRC_DIR)/tb_VX_dma_engine.sv

AXI_DIR := $(THIRD_PARTY_DIR)/axi
LIB_RTLS := $(filter-out %_tb.sv,$(wildcard $(RTL_DIR)/libs/*.sv))

RTLS := $(AXI_DIR)/src/axi_pkg.sv \
				$(AXI_DIR)/src/axi_intf.sv \
				$(RTL_DIR)/VX_gpu_pkg.sv \
				$(RTL_DIR)/mem/VX_mem_bus_if.sv \
				$(RTL_DIR)/core/VX_config_reg_if.sv \
				$(RTL_DIR)/core/VX_mem_remap.sv \
				$(RTL_DIR)/core/VX_node_done_if.sv \
				$(RTL_DIR)/core/VX_dma_unit_align.sv \
				$(RTL_DIR)/core/VX_dma_gearbox.sv \
				$(RTL_DIR)/core/VX_dma_lane_aligner.sv \
				$(RTL_DIR)/core/VX_dma_lane_assembler.sv \
				$(RTL_DIR)/core/VX_dma_equal_realigner.sv \
				$(RTL_DIR)/core/VX_dma_misal_gen_path.sv \
				$(RTL_DIR)/core/VX_dma_unit_misal.sv \
				$(RTL_DIR)/core/VX_dma_unit.sv \
				$(RTL_DIR)/mem/VX_dma_engine.sv \
				$(LIB_RTLS)

INCDIRS_ := $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/core \
            $(RTL_DIR)/mem \
            $(AXI_DIR)/include
DEFINES_ := SIMULATION NDEBUG PLATFORM_MEMORY_ID_WIDTH=32 PLATFORM_MEMORY_ADDR_WIDTH=34 MEM_ADDR_WIDTH=34 \
            PLATFORM_MEMORY_NUM_BANKS=32 PLATFORM_MEMORY_NUM_PORTS=8 PLATFORM_MEMORY_INTERLEAVE=1 PLATFORM_MEMORY_REMAP

ifdef PERF
DEFINES_ += PERF_ENABLE
endif

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

clean:
	rm -rf obj_dir
	rm -rf reports logs
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
