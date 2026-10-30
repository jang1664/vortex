UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk
RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/mmio_serializer
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++
SIM_EXEC ?= vcs
TEST_TOP ?= tb_mmio_serializer
TB := $(SRC_DIR)/$(TEST_TOP).sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
 $(RTL_DIR)/mem/VX_lsu_mem_if.sv $(RTL_DIR)/mem/VX_mem_bus_if.sv \
 $(RTL_DIR)/core/VX_config_reg_if.sv $(RTL_DIR)/core/VX_node_done_if.sv \
 $(RTL_DIR)/libs/VX_shift_register.sv $(RTL_DIR)/libs/VX_pipe_register.sv \
 $(RTL_DIR)/libs/VX_pipe_buffer.sv $(RTL_DIR)/libs/VX_stream_buffer.sv \
 $(RTL_DIR)/libs/VX_elastic_buffer.sv $(RTL_DIR)/libs/VX_slr_stream.sv \
 $(RTL_DIR)/libs/VX_stream_arb.sv $(RTL_DIR)/libs/VX_stream_switch.sv \
 $(RTL_DIR)/libs/VX_bits_insert.sv $(RTL_DIR)/libs/VX_bits_remove.sv \
 $(RTL_DIR)/libs/VX_generic_arbiter.sv $(RTL_DIR)/libs/VX_rr_arbiter.sv \
 $(RTL_DIR)/libs/VX_priority_arbiter.sv $(RTL_DIR)/libs/VX_priority_encoder.sv \
 $(RTL_DIR)/libs/VX_find_first.sv $(RTL_DIR)/libs/VX_lzc.sv $(RTL_DIR)/libs/VX_popcount.sv \
 $(RTL_DIR)/libs/VX_onehot_encoder.sv $(RTL_DIR)/libs/VX_demux.sv \
 $(RTL_DIR)/libs/VX_matrix_arbiter.sv $(RTL_DIR)/libs/VX_cyclic_arbiter.sv \
 $(RTL_DIR)/mem/VX_lsu_mem_arb.sv \
 $(RTL_DIR)/core/VX_sram_lsu_transport.sv \
 $(RTL_DIR)/core/VX_mmio_serializer.sv \
 $(RTL_DIR)/core/VX_job_desc_mmio_regs.sv $(RTL_DIR)/core/VX_job_dispatcher.sv \
 $(RTL_DIR)/core/VX_job_frontend.sv
INCDIRS := $(RTL_DIR) $(RTL_DIR)/mem $(RTL_DIR)/libs $(RTL_DIR)/core
DEFINES := $(patsubst -D%,+define+%,$(CONFIGS)) +define+SIMULATION +define+NDEBUG +define+XLEN_64
.PHONY: compile run sim
compile:
	mkdir -p logs
	vcs -full64 -sverilog -top $(TEST_TOP) -timescale=1ns/1ps \
	 -cc /usr/bin/gcc -cpp /usr/bin/g++ -debug_access+all \
	 $(foreach dir,$(INCDIRS),+incdir+$(dir)) $(DEFINES) $(RTLS) $(TB) -l logs/compile.log
run:
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
sim: run
