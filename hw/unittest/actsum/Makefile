# Include Vortex configuration
ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/build/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

SIM_EXEC ?= vcs

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_act_sum

TB   := tb_VX_act_sum.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
		$(RTL_DIR)/core/gemm/VX_act_sum.sv \
		$(RTL_DIR)/libs/VX_reduce_tree_pipelined.sv \
		$(RTL_DIR)/libs/VX_elastic_buffer.sv \
		$(RTL_DIR)/libs/VX_stream_buffer.sv \
		$(RTL_DIR)/libs/VX_pipe_buffer.sv \
		$(RTL_DIR)/libs/VX_pipe_register.sv \
		$(RTL_DIR)/libs/VX_shift_register.sv \
		$(RTL_DIR)/libs/VX_fifo_queue.sv

PARAMS_  :=
INCDIRS_ := $(RTL_DIR) $(VORTEX_HOME)/hw

# Test parameter overrides (shared by VCS/Verilator via +define)
TB_PIPELINE_STAGES ?= 2
TB_DLY_CYCLES      ?= 1

# Allow convenient hex (0x..) input from make; convert to decimal for safe +define (avoids shell quote issues).
TB_PIPELINE_STAGES_SV := $(if $(filter 0x%,$(TB_PIPELINE_STAGES)),$(shell printf %d $$(( $(TB_PIPELINE_STAGES) ))),$(TB_PIPELINE_STAGES))
TB_DLY_CYCLES_SV      := $(if $(filter 0x%,$(TB_DLY_CYCLES)),$(shell printf %d $$(( $(TB_DLY_CYCLES) ))),$(TB_DLY_CYCLES))

DEFINES_ := SIMULATION DEBUG_LEVEL=3 \
	TB_PIPELINE_STAGES=$(TB_PIPELINE_STAGES_SV) \
	TB_DLY_CYCLES=$(TB_DLY_CYCLES_SV)

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

VL_INCDIRS  := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS  := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES  := +define+$(subst $(space),+,$(DEFINES_))

PARAMS := $(foreach p,$(PARAMS_),-pvalue+$(p))

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