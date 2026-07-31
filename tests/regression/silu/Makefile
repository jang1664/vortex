ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := silu

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

SILU_VARIANT ?= linear
SILU_VARIANTS := chunk32 linear
ifneq ($(filter $(SILU_VARIANT),$(SILU_VARIANTS)),$(SILU_VARIANT))
  $(error Unsupported SILU_VARIANT=$(SILU_VARIANT); expected one of: $(SILU_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(SILU_VARIANT).cpp
ifeq ($(SILU_VARIANT),linear)
  CXXFLAGS += -DSILU_VARIANT_TAG=1
  VX_CFLAGS += -DSILU_VARIANT_TAG=1
else
  CXXFLAGS += -DSILU_VARIANT_TAG=0
  VX_CFLAGS += -DSILU_VARIANT_TAG=0
endif

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
