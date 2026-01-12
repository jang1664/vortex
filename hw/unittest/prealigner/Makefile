# Include Vortex configuration
ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/build/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

SIM_EXEC ?= vlt

TIME_SCALE=1ns/1ps

TOP_MODULE := tb_VX_prealigner

TB   := tb_VX_prealigner.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
				$(RTL_DIR)/core/gemm/VX_prealigner.sv \
				$(RTL_DIR)/libs/VX_find_first.sv \
				$(RTL_DIR)/libs/VX_lzc.sv \
				$(RTL_DIR)/libs/VX_elastic_buffer.sv \
				$(RTL_DIR)/libs/VX_stream_buffer.sv \
				$(RTL_DIR)/libs/VX_pipe_buffer.sv \
				$(RTL_DIR)/libs/VX_pipe_register.sv \
				$(RTL_DIR)/libs/VX_shift_register.sv \
				$(RTL_DIR)/verification/VX_mem_pkg.sv \
				$(RTL_DIR)/verification/VX_stream_intf.sv \
				$(RTL_DIR)/verification/VX_stream_slave_always_ready.sv
PARAMS_ := NUM_UNIT=4
INCDIRS_ := $(RTL_DIR)
DEFINES_ := SIMULATION DEBUG_LEVEL=3 DBG_TRACE_GEMM

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