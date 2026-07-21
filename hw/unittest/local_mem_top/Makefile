UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

export CC := /usr/bin/gcc
export CXX := /usr/bin/g++

PROJECT := local_mem_top

RTL_DIR := $(VORTEX_HOME)/hw/rtl
DPI_DIR := $(VORTEX_HOME)/hw/dpi

SRC_DIR := $(VORTEX_HOME)/hw/unittest/$(PROJECT)

CXXFLAGS := -I$(SRC_DIR) -I$(VORTEX_HOME)/hw/unittest/common -I$(SW_COMMON_DIR)
CXXFLAGS += -I$(ROOT_DIR)/hw

SRCS := $(DPI_DIR)/util_dpi.cpp
SRCS += $(SRC_DIR)/main.cpp

DBG_TRACE_FLAGS :=

# Exercise the target local-memory shape and expose the topology-neutral
# legacy bank-stall counter to the C++ scoreboard.
NUM_REQS ?= 32
NUM_BANKS ?= 32
PARAMS := -GNUM_REQS=$(NUM_REQS) -GNUM_BANKS=$(NUM_BANKS) -GWORD_SIZE=8 -GSIZE=4096 -GTAG_WIDTH=16
CXXFLAGS += -DTB_NUM_REQS=$(NUM_REQS) -DTB_NUM_BANKS=$(NUM_BANKS)
PERF ?= 1

RTL_PKGS := $(RTL_DIR)/VX_gpu_pkg.sv

RTL_INCLUDE := -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs
RTL_INCLUDE += -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/mem

TOP := VX_local_mem_top

include ../common.mk

.PHONY: compile
compile: $(DESTDIR)/$(PROJECT)
