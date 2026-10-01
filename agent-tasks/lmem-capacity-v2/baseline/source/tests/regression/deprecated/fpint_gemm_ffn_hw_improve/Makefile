ROOT_DIR := $(realpath ../../..)
XLEN ?= 64
include $(ROOT_DIR)/config.mk

PROJECT := fpint_gemm_ffn_hw_improve

VORTEX_RT_PATH ?= $(ROOT_DIR)/runtime
LD_LIBRARY_PATH := $(VORTEX_HOME)/third_party/ramulator:$(LD_LIBRARY_PATH)
STARTUP_ADDR ?= 0x80000000

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

VX_SRCS := $(SRC_DIR)/kernel.cpp

include ../common.mk
