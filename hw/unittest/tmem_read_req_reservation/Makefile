# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/tmem_read_req_reservation
AXI_DIR := $(THIRD_PARTY_DIR)/axi

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs
TIME_SCALE := 1ns/1ps
TOP_MODULE := tb_VX_tmem_read_req_reservation

TB := $(SRC_DIR)/tb_VX_tmem_read_req_reservation.sv
RTLS := $(AXI_DIR)/src/axi_pkg.sv \
        $(AXI_DIR)/src/axi_intf.sv \
        $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/core/VX_config_reg_if.sv \
        $(RTL_DIR)/core/VX_dma_lookahead_if.sv \
        $(RTL_DIR)/core/VX_node_done_if.sv \
        $(RTL_DIR)/core/gemm/VX_lmem_dma_ctrl_if.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/mem/VX_tmem_subsystem.sv

INCDIRS_ := $(ROOT_DIR)/hw \
            $(RTL_DIR) \
            $(RTL_DIR)/core \
            $(RTL_DIR)/core/gemm \
            $(RTL_DIR)/mem \
            $(AXI_DIR)/src \
            $(AXI_DIR)/include
DEFINES_ := SIMULATION NDEBUG XLEN_64 MEM_ADDR_WIDTH=34 \
            PLATFORM_MEMORY_ADDR_WIDTH=34
CONFIG_DEFINES := $(patsubst -D%,%,$(CONFIGS))
DEFINES_ += $(CONFIG_DEFINES)

COMPILE_LOG := logs/compile.log
SIM_LOG := logs/sim.log
VC_INCDIRS := $(foreach dir,$(INCDIRS_),+incdir+$(dir))
empty :=
space := $(empty) $(empty)
DEFINES := +define+$(subst $(space),+,$(DEFINES_))
PARAMS :=

setup:
	mkdir -p logs reports

run: sim

include vcs.mk
