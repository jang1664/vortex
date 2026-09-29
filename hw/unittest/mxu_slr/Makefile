# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/mxu_slr

# Use the system compiler for host-side simulator compilation.
export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

SIM_EXEC ?= vcs

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_mxu_slr

TB   := $(SRC_DIR)/tb_mxu_slr.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
            $(RTL_DIR)/mem/VX_mem_bus_if.sv \
            $(RTL_DIR)/verification/cf_math_util_pkg.sv \
            $(RTL_DIR)/verification/fpint_emul.sv \
            $(RTL_DIR)/verification/VX_utils_pkg.sv \
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
            $(RTL_DIR)/core/gemm/VX_stream_intf.sv \
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


INCDIRS_ := $(ROOT_DIR)/hw \
            $(VORTEX_HOME)/hw \
            $(VORTEX_HOME)/sim/common \
            $(RTL_DIR) \
            $(VORTEX_HOME)/hw/dpi \
            $(THIRD_PARTY_DIR)/softfloat/source/include

DEFINES_ := SIMULATION DEBUG_LEVEL=0
CONFIG_DEFINES := $(patsubst -D%,%,$(CONFIGS))
DEFINES_ += $(CONFIG_DEFINES)
FPU_NEW_EN ?= 1
ifeq ($(FPU_NEW_EN),1)
DEFINES_ += FPU_FPNEW
endif

ifneq (,$(findstring FPU_FPNEW,$(DEFINES_)))
INCDIRS_ += $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include \
            $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src \
            $(THIRD_PARTY_DIR)/cvfpu/src

CVFPU_RTLS := $(RTL_DIR)/fpu/patched_cvfpu/fpnew_pkg.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/lzc.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/rr_arb_tree.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_rounding.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_classifier.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_fma.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_opgroup_fmt_slice.sv \
            $(RTL_DIR)/fpu/patched_cvfpu/fpnew_opgroup_block.sv \
            $(RTL_DIR)/fpu/patched_cvfpu/fpnew_opgroup_multifmt_slice.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_top.sv

# Keep packages/modules order deterministic for VCS package imports.
RTLS := $(CVFPU_RTLS) $(RTLS)
endif

CFLAGS  := "-std=c++17 -Wall -Wextra -Wno-array-bounds -Wno-maybe-uninitialized -fPIC -I$(ROOT_DIR)/hw -I$(VORTEX_HOME)/hw -I$(VORTEX_HOME)/sim/common -I$(VORTEX_HOME)/hw/dpi -I$(RTL_DIR) -I$(THIRD_PARTY_DIR)/softfloat/source/include -DXLEN_$(XLEN)"
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
	$(MAKE) -C $(ROOT_DIR)/hw config
	mkdir -p logs reports

include $(SIM_EXEC).mk
