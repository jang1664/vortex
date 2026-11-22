ROOT_DIR := $(realpath ../../..)
XLEN ?= 64
include $(ROOT_DIR)/config.mk

PROJECT := flash_attn

STARTUP_ADDR ?= 0x80000000
SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp
VX_SRCS := $(SRC_DIR)/kernel.cpp

CXXFLAGS += -I$(VORTEX_HOME)/kernel/include

include ../common.mk

kernel.elf: $(SRC_DIR)/common.h $(VORTEX_HOME)/kernel/include/vx_flash_attention.h $(VORTEX_HOME)/kernel/include/vx_sram_fusion.h
kernel.elf: $(SRC_DIR)/../softmax_common/warp_reduce_full.h
