# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/dma_node

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

SIM_EXEC ?= vlt

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_dma_node

TB   := $(SRC_DIR)/tb_VX_dma_node.sv

RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/mem/VX_lsu_mem_if.sv \
        $(RTL_DIR)/core/VX_config_reg_if.sv \
        $(RTL_DIR)/core/VX_node_done_if.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_fifo_queue.sv \
        $(RTL_DIR)/libs/VX_dp_ram.sv \
        $(RTL_DIR)/libs/VX_sp_ram.sv \
        $(RTL_DIR)/libs/VX_async_ram_patch.sv \
        $(RTL_DIR)/libs/VX_placeholder.sv \
        $(RTL_DIR)/libs/VX_popcount.sv \
        $(RTL_DIR)/libs/VX_reduce_tree.sv \
        $(RTL_DIR)/libs/VX_priority_encoder.sv \
        $(RTL_DIR)/libs/VX_onehot_encoder.sv \
        $(RTL_DIR)/libs/VX_find_first.sv \
        $(RTL_DIR)/libs/VX_lzc.sv \
        $(RTL_DIR)/libs/VX_scan.sv \
        $(RTL_DIR)/libs/VX_mux.sv \
        $(RTL_DIR)/libs/VX_demux.sv \
        $(RTL_DIR)/libs/VX_bits_insert.sv \
        $(RTL_DIR)/libs/VX_bits_remove.sv \
        $(RTL_DIR)/libs/VX_bits_concat.sv \
        $(RTL_DIR)/libs/VX_pending_size.sv \
        $(RTL_DIR)/libs/VX_transpose.sv \
        $(RTL_DIR)/libs/VX_generic_arbiter.sv \
        $(RTL_DIR)/libs/VX_priority_arbiter.sv \
        $(RTL_DIR)/libs/VX_rr_arbiter.sv \
        $(RTL_DIR)/libs/VX_cyclic_arbiter.sv \
        $(RTL_DIR)/libs/VX_matrix_arbiter.sv \
        $(RTL_DIR)/libs/VX_stream_arb.sv \
        $(RTL_DIR)/libs/VX_stream_switch.sv \
        $(RTL_DIR)/libs/VX_stream_xbar.sv \
        $(RTL_DIR)/libs/VX_stream_omega.sv \
        $(RTL_DIR)/libs/VX_mul_u32_pipe.sv \
        $(RTL_DIR)/mem/VX_mem_arb.sv \
        $(RTL_DIR)/mem/VX_lsu_mem_arb.sv \
        $(RTL_DIR)/mem/VX_mem_switch.sv \
        $(RTL_DIR)/mem/VX_local_mem.sv \
        $(RTL_DIR)/cache/VX_cache_data.sv \
        $(RTL_DIR)/cache/VX_cache_tags.sv \
        $(RTL_DIR)/cache/VX_cache_repl.sv \
        $(RTL_DIR)/cache/VX_cache_flush.sv \
        $(RTL_DIR)/cache/VX_cache_init.sv \
        $(RTL_DIR)/cache/VX_cache_mshr.sv \
        $(RTL_DIR)/cache/VX_cache_bank.sv \
        $(RTL_DIR)/cache/VX_cache.sv \
        $(RTL_DIR)/cache/VX_cache_bypass.sv \
        $(RTL_DIR)/cache/VX_cache_wrap.sv \
        $(RTL_DIR)/core/VX_job_desc_mmio_regs.sv \
        $(RTL_DIR)/core/VX_job_dispatcher.sv \
        $(RTL_DIR)/core/VX_job_frontend.sv \
        $(RTL_DIR)/core/VX_dma_unit_misal.sv \
        $(RTL_DIR)/core/VX_dma_node.sv

INCDIRS_ := $(VORTEX_HOME)/build/hw \
            $(VORTEX_HOME)/hw \
            $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/cache \
            $(RTL_DIR)/mem \
            $(RTL_DIR)/core

DEFINES_ := SIMULATION XLEN_64 DEBUG_LEVEL=3 DBG_TRACE_GEMM DBG_TRACE_CACHE

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
