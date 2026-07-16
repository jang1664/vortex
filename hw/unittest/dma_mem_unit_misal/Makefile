# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/dma_mem_unit_misal

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vlt

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_dma_mem_unit_misal

#PIPE_MULT ?= 1
#PIPE_ALIGN ?= 1
#PIPE_INTERVAL ?= 2


TB   := $(SRC_DIR)/tb_VX_dma_mem_unit_misal.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
				$(RTL_DIR)/core/VX_dma_unit_align.sv \
				$(RTL_DIR)/core/VX_dma_unit_misal.sv \
				$(RTL_DIR)/core/VX_dma_unit.sv \
				$(RTL_DIR)/mem/VX_local_mem.sv \
				$(RTL_DIR)/mem/VX_mem_bus_if.sv \
				$(RTL_DIR)/core/VX_config_reg_if.sv \
				$(RTL_DIR)/libs/VX_mul_u32_pipe.sv \
				$(RTL_DIR)/libs/VX_stream_xbar.sv \
				$(RTL_DIR)/libs/VX_sp_ram.sv \
				$(RTL_DIR)/libs/VX_pipe_buffer.sv \
				$(RTL_DIR)/libs/VX_pipe_register.sv \
				$(RTL_DIR)/libs/VX_stream_arb.sv \
				$(RTL_DIR)/libs/VX_popcount.sv \
				$(RTL_DIR)/libs/VX_demux.sv \
				$(RTL_DIR)/libs/VX_elastic_buffer.sv \
				$(RTL_DIR)/libs/VX_fifo_queue.sv \
				$(RTL_DIR)/libs/VX_pending_size.sv \
				$(RTL_DIR)/libs/VX_dp_ram.sv \
				$(RTL_DIR)/libs/VX_stream_buffer.sv \
				$(RTL_DIR)/libs/VX_generic_arbiter.sv \
				$(RTL_DIR)/libs/VX_shift_register.sv \
				$(RTL_DIR)/libs/VX_priority_arbiter.sv \
				$(RTL_DIR)/libs/VX_priority_encoder.sv \
				$(RTL_DIR)/libs/VX_lzc.sv \
				$(RTL_DIR)/libs/VX_find_first.sv \
				$(RTL_DIR)/core/VX_node_done_if.sv
#PARAMS_  := PIPE_MULT=$(PIPE_MULT) PIPE_ALIGN=$(PIPE_ALIGN) PIPE_INTERVAL=$(PIPE_INTERVAL)
INCDIRS_ := $(RTL_DIR)
DEFINES_ := SIMULATION DEBUG_LEVEL=3 DBG_TRACE_GEMM DMA_RD_OUTSTANDING_SLOT=8

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

VL_INCDIRS  := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS  := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES  := +define+$(subst $(space),+,$(DEFINES_))

PARAMS := 

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk

run: sim

fst2vcd:
	for file in reports/*.fst; do \
	  fst2vcd $$file -o reports/$${file##*/}.vcd; \
	done

vcd2fsdb:
	for file in reports/*.vcd; do \
	  vcd2fsdb $$file -o reports/$${file##*/}.fsdb; \
	done

fst2fsdb:
	for file in reports/*.fst; do \
	  fst2vcd $$file -o reports/$${file##*/}.vcd; \
	  vcd2fsdb  reports/$${file##*/}.vcd -o reports/$${file##*/}.fsdb; \
	  rm reports/$${file##*/}.vcd; \
	done

clean:
	rm -rf obj_dir 
	rm -rf reports logs 
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
