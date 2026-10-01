ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := eladd

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

ELADD_VARIANT ?= row_coalesced_cursor
ELADD_VARIANTS := baseline row_coalesced_cursor
ifneq ($(filter $(ELADD_VARIANT),$(ELADD_VARIANTS)),$(ELADD_VARIANT))
  $(error Unsupported ELADD_VARIANT=$(ELADD_VARIANT); expected one of: $(ELADD_VARIANTS))
endif

SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

VX_SRCS := $(SRC_DIR)/kernel.cpp

ifeq ($(ELADD_VARIANT),row_coalesced_cursor)
  ELADD_ROW_SIZE ?= 4096
  VX_CFLAGS += -DELADD_ROW_COALESCED_CURSOR -DELADD_ROW_SIZE=$(ELADD_ROW_SIZE)
endif

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
