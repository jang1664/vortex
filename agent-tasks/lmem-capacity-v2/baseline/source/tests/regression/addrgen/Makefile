ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := addrgen
SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp
VX_SRCS := $(SRC_DIR)/kernel.cpp

CXXFLAGS += -I$(VORTEX_HOME)/tests/common
VX_CFLAGS += -DEXT_ADDR_GEN_ENABLE

include ../common.mk
