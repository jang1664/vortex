ROOT_DIR := $(realpath ../../..)
XLEN ?= 64
include $(ROOT_DIR)/config.mk

PROJECT := fpfp_gemm_ffn_hw_naive
VORTEX_RT_PATH ?= $(ROOT_DIR)/runtime
LD_LIBRARY_PATH := $(VORTEX_HOME)/third_party/ramulator:$(LD_LIBRARY_PATH)
STARTUP_ADDR ?= 0x80000000

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)
NAIVE_DIR := $(VORTEX_HOME)/tests/regression/fpint_gemm_ffn_hw_naive
SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp
VX_SRCS := $(SRC_DIR)/kernel.cpp
CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include -include $(SRC_DIR)/config_check.h
VX_CFLAGS += -include $(SRC_DIR)/config_check.h
LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk

$(PROJECT) kernel.elf: $(NAIVE_DIR)/common.h $(NAIVE_DIR)/config_check.h $(SRC_DIR)/config_check.h
$(PROJECT): $(NAIVE_DIR)/main.cpp $(NAIVE_DIR)/fpfp_test_vectors.h
kernel.elf: $(NAIVE_DIR)/kernel.cpp

$(PROJECT)_bench: $(NAIVE_DIR)/bench_main.cpp $(NAIVE_DIR)/common.h $(NAIVE_DIR)/fpfp_test_vectors.h
