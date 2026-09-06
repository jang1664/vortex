UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/dma_write_pair_elastic
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
EB ?= 1
PAD ?= 1
TOP_MODULE := tb_dma_write_pair_elastic
TB := $(SRC_DIR)/tb_dma_write_pair_elastic.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/mem/VX_mem_bus_if.sv \
 $(RTL_DIR)/core/VX_config_reg_if.sv $(RTL_DIR)/core/VX_node_done_if.sv \
 $(RTL_DIR)/core/VX_dma_lookahead_if.sv $(RTL_DIR)/core/VX_dma_unit_align.sv \
 $(RTL_DIR)/mem/VX_tmem_dma_pair_adapter.sv
PARAMS := -pvalue+$(TOP_MODULE).EB=$(EB) -pvalue+$(TOP_MODULE).PAD=$(PAD)
DEFINES := +define+SIMULATION+XLEN_64+MEM_ADDR_WIDTH=34
compile: $(TB) $(RTLS) Makefile
	mkdir -p logs
	vcs -full64 -sverilog -top $(TOP_MODULE) -timescale=1ns/1ps \
	 -cc /usr/bin/gcc -cpp /usr/bin/g++ +incdir+$(RTL_DIR) \
	 -y $(RTL_DIR)/libs +libext+.sv $(DEFINES) $(RTLS) $(TB) $(PARAMS) -l logs/compile.log
	@touch compile
run: compile
	./simv -l logs/sim.log
