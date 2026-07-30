ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := dequant_hbm_energy

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp
VX_SRCS := $(SRC_DIR)/kernel.cpp
CXXFLAGS += -I$(VORTEX_HOME)/tests/common

DEQUANT_HBM_FP16_PROFILE := $(and $(findstring -DEXT_D_DISABLE,$(CONFIGS)),$(findstring -DEXT_ZFH_ENABLE,$(CONFIGS)))
ifneq (,$(DEQUANT_HBM_FP16_PROFILE))
  CXXFLAGS += -DDEQUANT_HBM_ARITH_FP16=1
  VX_CFLAGS += -DDEQUANT_HBM_ARITH_FP16=1
else
  CXXFLAGS += -DDEQUANT_HBM_ARITH_FP32=1
  VX_CFLAGS += -DDEQUANT_HBM_ARITH_FP32=1
endif

OPTS ?= -k 128 -n 128 -q 32 -d 0 --mode full --buffer-copies 1

include ../common.mk
