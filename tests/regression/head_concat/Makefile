ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := head_concat

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

HEAD_CONCAT_VARIANT ?= chunk16_packed
HEAD_CONCAT_VARIANTS := baseline chunk16_packed
ifneq ($(filter $(HEAD_CONCAT_VARIANT),$(HEAD_CONCAT_VARIANTS)),$(HEAD_CONCAT_VARIANT))
  $(error Unsupported HEAD_CONCAT_VARIANT=$(HEAD_CONCAT_VARIANT); expected one of: $(HEAD_CONCAT_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(HEAD_CONCAT_VARIANT).cpp

ifeq ($(HEAD_CONCAT_VARIANT),chunk16_packed)
  CXXFLAGS += -DHEAD_CONCAT_VARIANT_TAG=1
  VX_CFLAGS += -DHEAD_CONCAT_VARIANT_TAG=1
else
  CXXFLAGS += -DHEAD_CONCAT_VARIANT_TAG=0
  VX_CFLAGS += -DHEAD_CONCAT_VARIANT_TAG=0
endif

include ../common.mk
