ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := fp16_zfh

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp
VX_SRCS := $(SRC_DIR)/kernel.cpp

VX_CFLAGS += -ffp-contract=off
OPTS ?=

include ../common.mk
