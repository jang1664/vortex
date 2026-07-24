ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := rope

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

ROPE_VARIANT ?= task_chunk16
ROPE_VARIANTS := baseline task_chunk16
ifneq ($(filter $(ROPE_VARIANT),$(ROPE_VARIANTS)),$(ROPE_VARIANT))
  $(error Unsupported ROPE_VARIANT=$(ROPE_VARIANT); expected one of: $(ROPE_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(ROPE_VARIANT).cpp

ifeq ($(ROPE_VARIANT),task_chunk16)
  CXXFLAGS += -DROPE_VARIANT_TAG=1
  VX_CFLAGS += -DROPE_VARIANT_TAG=1
else
  CXXFLAGS += -DROPE_VARIANT_TAG=0
  VX_CFLAGS += -DROPE_VARIANT_TAG=0
endif

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
