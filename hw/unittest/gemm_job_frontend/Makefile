# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/gemm_job_frontend

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

SIM_EXEC ?= vcs

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_gemm_job_frontend

TB   := $(SRC_DIR)/tb_VX_gemm_job_frontend.sv

RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
        $(RTL_DIR)/mem/VX_lsu_mem_if.sv \
        $(RTL_DIR)/core/gemm/VX_instruction_if.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_node_done_if.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_arb.sv \
        $(RTL_DIR)/libs/VX_priority_arbiter.sv \
        $(RTL_DIR)/libs/VX_priority_encoder.sv \
        $(RTL_DIR)/libs/VX_onehot_encoder.sv \
        $(RTL_DIR)/libs/VX_generic_arbiter.sv \
        $(RTL_DIR)/libs/VX_rr_arbiter.sv \
        $(RTL_DIR)/libs/VX_matrix_arbiter.sv \
        $(RTL_DIR)/libs/VX_cyclic_arbiter.sv \
        $(RTL_DIR)/libs/VX_find_first.sv \
        $(RTL_DIR)/libs/VX_lzc.sv \
        $(RTL_DIR)/libs/VX_demux.sv \
        $(RTL_DIR)/libs/VX_popcount.sv \
        $(RTL_DIR)/libs/VX_dp_ram.sv \
        $(RTL_DIR)/libs/VX_pending_size.sv \
        $(RTL_DIR)/libs/VX_fifo_queue.sv \
        $(RTL_DIR)/libs/VX_multi_push_fifo.sv \
        $(RTL_DIR)/mem/VX_lsu_mem_arb.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_job_frontend.sv

INCDIRS_ := $(VORTEX_HOME)/build/hw \
            $(VORTEX_HOME)/hw \
            $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/mem \
            $(RTL_DIR)/core \
            $(RTL_DIR)/core/gemm

DEFINES_ := XLEN_64 SIMULATION DEBUG_LEVEL=3 NUM_THREADS=8

COMPILE_LOG := logs/compile.log

TEST ?=
ifneq ($(strip $(TEST)),)
SIM_LOG := logs/sim_$(TEST).log
else
SIM_LOG := logs/sim.log
endif

SIM_ARGS :=
ifneq ($(strip $(TEST)),)
SIM_ARGS += +TEST=$(TEST)
endif

VL_INCDIRS  := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS  := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES  := +define+$(subst $(space),+,$(DEFINES_))

PARAMS :=

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk

clean:
	rm -rf obj_dir
	rm -rf reports logs
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
	rm -f compile
