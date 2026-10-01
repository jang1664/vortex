ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := detile_output

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

DETILE_OUTPUT_VARIANT ?= packed_pair
DETILE_OUTPUT_VARIANTS := baseline packed_pair
ifneq ($(filter $(DETILE_OUTPUT_VARIANT),$(DETILE_OUTPUT_VARIANTS)),$(DETILE_OUTPUT_VARIANT))
  $(error Unsupported DETILE_OUTPUT_VARIANT=$(DETILE_OUTPUT_VARIANT); expected one of: $(DETILE_OUTPUT_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(DETILE_OUTPUT_VARIANT).cpp
ifeq ($(DETILE_OUTPUT_VARIANT),packed_pair)
  CXXFLAGS += -DDETILE_OUTPUT_VARIANT_TAG=1
  VX_CFLAGS += -DDETILE_OUTPUT_VARIANT_TAG=1
else
  CXXFLAGS += -DDETILE_OUTPUT_VARIANT_TAG=0
  VX_CFLAGS += -DDETILE_OUTPUT_VARIANT_TAG=0
endif

include ../common.mk
