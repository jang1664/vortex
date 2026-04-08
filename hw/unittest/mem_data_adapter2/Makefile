# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/build/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

SIM_EXEC ?= vcs

TIME_SCALE=1ns/1ps

TOP_MODULE := tb_VX_mem_data_adapter2

TB   := $(UNITTEST_DIR)/tb_VX_mem_data_adapter2.sv
RTLS := $(RTL_DIR)/libs/VX_mem_data_adapter2.sv \
        $(RTL_DIR)/libs/VX_demux.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv \
        $(RTL_DIR)/libs/VX_fifo_queue.sv \
        $(RTL_DIR)/libs/VX_pending_size.sv \
        $(RTL_DIR)/libs/VX_dp_ram.sv

INCDIRS_ := $(VORTEX_HOME)/build/hw \
            $(VORTEX_HOME)/hw \
            $(RTL_DIR) \
            $(RTL_DIR)/libs

DEFINES_ := SIMULATION DEBUG_LEVEL=3

# Keep -CFLAGS argument valid in vcs.mk/vlt.mk even without DPI sources.
CFLAGS  := "-std=c++17 -Wall -Wextra -fPIC -I$(VORTEX_HOME)/build/hw -I$(VORTEX_HOME)/hw -I$(RTL_DIR) -DXLEN_$(XLEN)"
LDFLAGS :=

PARAMS_ :=

COMPILE_LOG := logs/compile.log
SIM_LOG     := logs/sim.log

SIM_ARGS ?=

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
	  vcd2fsdb reports/$${file##*/}.vcd -o reports/$${file##*/}.fsdb; \
	  rm reports/$${file##*/}.vcd; \
	done

clean:
	rm -rf obj_dir
	rm -rf reports logs
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
	rm -f compile
