ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := hadamard_base
SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)
SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

HADAMARD_BASE_VARIANT ?= grouped4
HADAMARD_BASE_VARIANTS := baseline grouped4
ifneq ($(filter $(HADAMARD_BASE_VARIANT),$(HADAMARD_BASE_VARIANTS)),$(HADAMARD_BASE_VARIANT))
  $(error Unsupported HADAMARD_BASE_VARIANT=$(HADAMARD_BASE_VARIANT); expected one of: $(HADAMARD_BASE_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.cpp

ifeq ($(HADAMARD_BASE_VARIANT),grouped4)
  CXXFLAGS += -DHADAMARD_BASE_VARIANT_TAG=1
  VX_CFLAGS += -DHADAMARD_BASE_VARIANT_TAG=1
else
  CXXFLAGS += -DHADAMARD_BASE_VARIANT_TAG=0
  VX_CFLAGS += -DHADAMARD_BASE_VARIANT_TAG=0
endif

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include
LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
