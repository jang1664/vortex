ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := kv_cache_quant_w4a16

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

KV_CACHE_QUANT_VARIANT ?= groupwise
KV_CACHE_QUANT_VARIANTS := baseline groupwise
ifneq ($(filter $(KV_CACHE_QUANT_VARIANT),$(KV_CACHE_QUANT_VARIANTS)),$(KV_CACHE_QUANT_VARIANT))
  $(error Unsupported KV_CACHE_QUANT_VARIANT=$(KV_CACHE_QUANT_VARIANT); expected one of: $(KV_CACHE_QUANT_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(KV_CACHE_QUANT_VARIANT).cpp

ifeq ($(KV_CACHE_QUANT_VARIANT),groupwise)
  CXXFLAGS += -DKV_CACHE_QUANT_VARIANT=KV_CACHE_QUANT_VARIANT_GROUPWISE
else
  CXXFLAGS += -DKV_CACHE_QUANT_VARIANT=KV_CACHE_QUANT_VARIANT_BASELINE
endif

include ../common.mk
