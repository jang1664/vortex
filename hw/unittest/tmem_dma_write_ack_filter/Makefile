UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/tmem_dma_write_ack_filter
AXI_DIR := $(THIRD_PARTY_DIR)/axi
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
TMEM_BYTES ?= 32
TMEM_BANKS ?= 2
TMEM_BANK_SIZE ?= 4096
NDEBUG ?= 1
SUBSYSTEM_RTL ?= $(RTL_DIR)/mem/VX_tmem_subsystem.sv
TOP := tb_VX_tmem_dma_write_ack_filter
LIBDIRS := $(RTL_DIR)/libs $(RTL_DIR)/core $(RTL_DIR)/core/gemm $(RTL_DIR)/mem $(RTL_DIR)/interfaces $(AXI_DIR)/src
INCDIRS := $(ROOT_DIR)/hw $(RTL_DIR) $(LIBDIRS) $(AXI_DIR)/include
DEFS := $(patsubst -D%,+define+%,$(CONFIGS)) +define+SIMULATION \
        +define+PLATFORM_MEMORY_ID_WIDTH=8 +define+PLATFORM_MEMORY_ADDR_WIDTH=34
ifeq ($(NDEBUG),1)
DEFS += +define+NDEBUG
endif
.PHONY: compile run
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top $(TOP) -timescale=1ns/1ps -debug_access+all \
	  -cc /usr/bin/gcc -cpp /usr/bin/g++ +libext+.v+.sv \
	  $(foreach d,$(INCDIRS),+incdir+$(d)) $(foreach d,$(LIBDIRS),-y $(d)) $(DEFS) \
	  $(AXI_DIR)/src/axi_pkg.sv $(AXI_DIR)/src/axi_intf.sv $(RTL_DIR)/VX_gpu_pkg.sv \
	  $(RTL_DIR)/mem/VX_mem_bus_if.sv $(RTL_DIR)/core/VX_config_reg_if.sv \
	  $(RTL_DIR)/core/VX_dma_lookahead_if.sv $(RTL_DIR)/core/VX_node_done_if.sv \
	  $(RTL_DIR)/core/gemm/VX_lmem_dma_ctrl_if.sv $(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
	  $(SUBSYSTEM_RTL) $(SRC_DIR)/tb_VX_tmem_dma_write_ack_filter.sv \
	  -pvalue+$(TOP).DATA_SIZE=$(TMEM_BYTES) -pvalue+$(TOP).NUM_BANKS=$(TMEM_BANKS) \
	  -pvalue+$(TOP).BANK_SIZE=$(TMEM_BANK_SIZE) -l logs/compile.log
run:
	./simv -l logs/sim.log
