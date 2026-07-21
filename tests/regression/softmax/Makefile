ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := softmax

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp

SOFTMAX_VARIANT ?= dma_serial
SOFTMAX_VARIANTS := rev1 rev2 opt opt_align dma_row dma_serial
ifneq ($(filter $(SOFTMAX_VARIANT),$(SOFTMAX_VARIANTS)),$(SOFTMAX_VARIANT))
  $(error Unsupported SOFTMAX_VARIANT=$(SOFTMAX_VARIANT); expected one of: $(SOFTMAX_VARIANTS))
endif

VX_KERNEL ?= kernel.$(SOFTMAX_VARIANT).cpp
VX_SRCS := $(SRC_DIR)/$(VX_KERNEL)

ifeq ($(SOFTMAX_VARIANT),rev2)
kernel.elf: $(VORTEX_HOME)/tests/regression/softmax_common/kernel.simt_cached.h
endif

CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include
ifeq ($(SOFTMAX_VARIANT),dma_serial)
  CXXFLAGS += -DSOFTMAX_VARIANT=SOFTMAX_VARIANT_DMA_SERIAL
else ifeq ($(SOFTMAX_VARIANT),dma_row)
  CXXFLAGS += -DSOFTMAX_VARIANT=SOFTMAX_VARIANT_DMA_ROW
else ifeq ($(SOFTMAX_VARIANT),opt_align)
  CXXFLAGS += -DSOFTMAX_VARIANT=SOFTMAX_VARIANT_OPT_ALIGN
else ifeq ($(SOFTMAX_VARIANT),opt)
  CXXFLAGS += -DSOFTMAX_VARIANT=SOFTMAX_VARIANT_OPT
else ifeq ($(SOFTMAX_VARIANT),rev2)
  CXXFLAGS += -DSOFTMAX_VARIANT=SOFTMAX_VARIANT_REV2
else
  CXXFLAGS += -DSOFTMAX_VARIANT=SOFTMAX_VARIANT_REV1
endif

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

include ../common.mk
