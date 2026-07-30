ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := hadamard

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

HADAMARD_VARIANT ?= r3_shuffle
HADAMARD_VARIANTS := multiwarp_row adaptive_row r3_shuffle
ifneq ($(filter $(HADAMARD_VARIANT),$(HADAMARD_VARIANTS)),$(HADAMARD_VARIANT))
  $(error Unsupported HADAMARD_VARIANT=$(HADAMARD_VARIANT); expected one of: $(HADAMARD_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.cpp

ifeq ($(HADAMARD_VARIANT),r3_shuffle)
  CXXFLAGS += -DHADAMARD_VARIANT_TAG=2
  VX_CFLAGS += -DHADAMARD_VARIANT_TAG=2
else ifeq ($(HADAMARD_VARIANT),adaptive_row)
  CXXFLAGS += -DHADAMARD_VARIANT_TAG=1
  VX_CFLAGS += -DHADAMARD_VARIANT_TAG=1
else
  CXXFLAGS += -DHADAMARD_VARIANT_TAG=0
  VX_CFLAGS += -DHADAMARD_VARIANT_TAG=0
endif

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
