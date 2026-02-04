# Include Vortex configuration
ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/build/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

SIM_EXEC ?= vcs

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_gemm_unit

TB   := tb_VX_gemm_unit.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
				$(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/verification/cf_math_pkg.sv \
        $(RTL_DIR)/verification/fpint_emul.sv \
        $(RTL_DIR)/verification/utils.sv \
        $(RTL_DIR)/core/gemm/VX_fp32_add.sv \
        $(RTL_DIR)/core/gemm/VX_fp16_mul.sv \
        $(RTL_DIR)/core/gemm/VX_fp32_mul.sv \
        $(RTL_DIR)/core/gemm/VX_stream_fence.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv \
        $(RTL_DIR)/verification/VX_mem_pkg.sv \
        $(RTL_DIR)/verification/VX_stream_intf.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_tree_v1.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_weight_regs_v1.sv \
        $(RTL_DIR)/core/gemm/VX_pe_tree_new.sv \
        $(RTL_DIR)/libs/VX_reduce_tree_pipelined_v2.sv \
        $(RTL_DIR)/libs/VX_reduce_tree.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_unit.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_unit_if.sv \
        $(RTL_DIR)/core/gemm/VX_prealigner.sv \
        $(RTL_DIR)/core/gemm/VX_pint2fp.sv \
        $(RTL_DIR)/core/gemm/VX_f32_to_f16.sv \
        $(RTL_DIR)/libs/VX_lzc.sv \
        $(RTL_DIR)/libs/VX_find_first.sv \
        $(RTL_DIR)/libs/VX_fifo_v2.sv \
        $(RTL_DIR)/libs/VX_sp_ram.sv

DPI_SRCS := $(VORTEX_HOME)/hw/dpi/float_dpi.cpp \
            $(VORTEX_HOME)/sim/common/util.cpp \
            $(VORTEX_HOME)/sim/common/softfloat_ext.cpp \
            $(VORTEX_HOME)/sim/common/rvfloats.cpp

SOFTFLOAT_LIB := $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
						

INCDIRS_ := $(VORTEX_HOME)/build/hw \
            $(VORTEX_HOME)/hw \
            $(VORTEX_HOME)/sim/common \
            $(RTL_DIR) \
            $(VORTEX_HOME)/hw/dpi \
            $(THIRD_PARTY_DIR)/softfloat/source/include

DEFINES_ := SIMULATION DEBUG_LEVEL=3 DBG_TRACE_GEMM

CFLAGS  := "-std=c++17 -Wall -Wextra -Wno-array-bounds -Wno-maybe-uninitialized -fPIC -I$(VORTEX_HOME)/build/hw -I$(VORTEX_HOME)/hw -I$(VORTEX_HOME)/sim/common -I$(VORTEX_HOME)/hw/dpi -I$(RTL_DIR) -I$(THIRD_PARTY_DIR)/softfloat/source/include -DXLEN_$(XLEN)"
LDFLAGS := 

PARAMS_  := 

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