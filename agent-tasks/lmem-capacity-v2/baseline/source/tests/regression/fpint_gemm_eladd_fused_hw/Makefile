ROOT_DIR := $(realpath ../../..)
XLEN ?= 64
include $(ROOT_DIR)/config.mk

PROJECT := fpint_gemm_eladd_fused_hw

LD_LIBRARY_PATH := $(VORTEX_HOME)/third_party/ramulator:$(LD_LIBRARY_PATH)
STARTUP_ADDR ?= 0x80000000

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

VX_SRCS := $(SRC_DIR)/kernel.cpp

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
