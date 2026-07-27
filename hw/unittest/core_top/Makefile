UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

PROJECT := core_top

RTL_DIR := $(VORTEX_HOME)/hw/rtl
DPI_DIR := $(VORTEX_HOME)/hw/dpi

SRC_DIR := $(VORTEX_HOME)/hw/unittest/$(PROJECT)

CXXFLAGS := -I$(SRC_DIR) -I$(VORTEX_HOME)/hw/unittest/common -I$(SW_COMMON_DIR)
CXXFLAGS += -I$(ROOT_DIR)/hw

SRCS := $(DPI_DIR)/util_dpi.cpp
SRCS += $(SRC_DIR)/main.cpp

DBG_TRACE_FLAGS := -DDBG_TRACE_CACHE

RTL_PKGS := $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv

RTL_INCLUDE := -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs
RTL_INCLUDE += -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/mem -I$(RTL_DIR)/fpu -I$(RTL_DIR)/core

# Match the canonical fpnew package/source order used by xrtsim.  Verilator
# must see these packages before it resolves VX_fpu_fpnew from RTL_INCLUDE.
ifneq (,$(findstring -DFPU_FPNEW,$(CONFIGS)))
RTL_PKGS += $(RTL_DIR)/fpu/patched_cvfpu/fpnew_pkg.sv
RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg.sv
RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv
RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv \
            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv
RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include
RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src
RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl
RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src
endif

# VX_core exposes an AXI_BUS port even when the optional GEMM datapath is not
# enabled.  Compile the canonical package/interface pair before the core.
AXI_DIR := $(THIRD_PARTY_DIR)/axi
RTL_PKGS += $(AXI_DIR)/src/axi_pkg.sv
RTL_PKGS += $(AXI_DIR)/src/axi_intf.sv
RTL_INCLUDE += -I$(AXI_DIR)/include

TOP := VX_core_top

include ../common.mk

# Full-core dependency discovery produces a large set of visible warnings;
# keep them non-fatal for this elaboration-only unittest.
VL_FLAGS += -Wno-fatal

# Pinned cvfpu drives stage zero combinationally and later indexed pipeline
# stages sequentially in the same unpacked arrays.  Verilator 5.028 reports
# that established pattern as BLKANDNBLK, so suppress it only for this fpnew
# full-core elaboration smoke test.  VCS blackbox remains authoritative.
ifneq (,$(findstring -DFPU_FPNEW,$(CONFIGS)))
VL_FLAGS += -Wno-BLKANDNBLK
endif

# tools/verify_rtl.py uses a uniform compile-then-run contract.  Keep the
# standard all target while exposing the full-core elaboration as compile.
.PHONY: compile
compile: $(DESTDIR)/$(PROJECT)
