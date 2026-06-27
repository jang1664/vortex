ROOT_DIR := $(realpath ../../..)
XLEN ?= 64
include $(ROOT_DIR)/config.mk

PROJECT := mmio_burst_proto

VORTEX_RT_PATH ?= $(VORTEX_HOME)/build/runtime
STARTUP_ADDR ?= 0x80000000

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

VX_SRCS := $(SRC_DIR)/kernel.cpp

include ../common.mk
