ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := rmsnorm

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

RMSNORM_VARIANT ?= adaptive_m_rows
RMSNORM_VARIANTS := baseline adaptive_m_rows
ifneq ($(filter $(RMSNORM_VARIANT),$(RMSNORM_VARIANTS)),$(RMSNORM_VARIANT))
  $(error Unsupported RMSNORM_VARIANT=$(RMSNORM_VARIANT); expected one of: $(RMSNORM_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(RMSNORM_VARIANT).cpp

ifeq ($(RMSNORM_VARIANT),adaptive_m_rows)
  CXXFLAGS += -DRMSNORM_VARIANT_TAG=1
  VX_CFLAGS += -DRMSNORM_VARIANT_TAG=1
else
  CXXFLAGS += -DRMSNORM_VARIANT_TAG=0
  VX_CFLAGS += -DRMSNORM_VARIANT_TAG=0
endif

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
