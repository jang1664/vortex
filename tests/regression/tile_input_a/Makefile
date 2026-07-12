ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := tile_input_a

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

TILE_INPUT_A_VARIANT ?= packed4
TILE_INPUT_A_VARIANTS := packed2 packed4
ifneq ($(filter $(TILE_INPUT_A_VARIANT),$(TILE_INPUT_A_VARIANTS)),$(TILE_INPUT_A_VARIANT))
  $(error Unsupported TILE_INPUT_A_VARIANT=$(TILE_INPUT_A_VARIANT); expected one of: $(TILE_INPUT_A_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(TILE_INPUT_A_VARIANT).cpp
ifeq ($(TILE_INPUT_A_VARIANT),packed4)
  CXXFLAGS += -DTILE_INPUT_A_VARIANT_TAG=1
  VX_CFLAGS += -DTILE_INPUT_A_VARIANT_TAG=1
else
  CXXFLAGS += -DTILE_INPUT_A_VARIANT_TAG=0
  VX_CFLAGS += -DTILE_INPUT_A_VARIANT_TAG=0
endif

include ../common.mk
