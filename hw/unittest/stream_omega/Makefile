UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

# A source-tree unittest must compile the RTL from this worktree even when a
# configured config.mk was copied from a sibling checkout.
VORTEX_HOME := $(ROOT_DIR)

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

PROJECT := stream_omega

RTL_DIR := $(VORTEX_HOME)/hw/rtl
DPI_DIR := $(VORTEX_HOME)/hw/dpi
SRC_DIR := $(VORTEX_HOME)/hw/unittest/$(PROJECT)

CXXFLAGS := -I$(SRC_DIR) -I$(VORTEX_HOME)/hw/unittest/common -I$(SW_COMMON_DIR)

SRCS := $(DPI_DIR)/util_dpi.cpp
SRCS += $(SRC_DIR)/main.cpp

DBG_TRACE_FLAGS :=
RTL_PKGS := $(RTL_DIR)/VX_gpu_pkg.sv
RTL_INCLUDE := -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs -I$(SRC_DIR)
TOP := VX_stream_omega_top

include ../common.mk

.PHONY: compile
compile: $(DESTDIR)/$(PROJECT)
