ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := kv_cache_quant_layout_fused_w4a16

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT ?= prefill_reuse_inline_group1_source_weight_cursor
KV_CACHE_QUANT_LAYOUT_FUSED_VARIANTS := baseline qparam_warp persistent_warp prefill_reuse prefill_reuse_inline_all prefill_reuse_inline_group1 prefill_reuse_inline_group1_cursor prefill_reuse_inline_group1_cursor_pow2 prefill_reuse_inline_group1_cursor_pow2_weight_cursor prefill_reuse_inline_group1_source_weight_cursor prefill_reuse_inline_group1_source_cursor_wtrans1_cursor
ifneq ($(filter $(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANTS)),$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT))
  $(error Unsupported KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT=$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT); expected one of: $(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT).cpp

ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse_inline_group1_source_cursor_wtrans1_cursor)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=10
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=10
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse_inline_group1_source_weight_cursor)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=9
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=9
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse_inline_group1_cursor_pow2_weight_cursor)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=8
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=8
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse_inline_group1_cursor_pow2)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=7
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=7
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse_inline_group1_cursor)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=6
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=6
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse_inline_group1)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=5
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=5
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse_inline_all)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=4
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=4
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),prefill_reuse)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=3
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=3
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),persistent_warp)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=2
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=2
else ifeq ($(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),qparam_warp)
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=1
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=1
else
  CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=0
  VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=0
endif

# Variant wrappers include the shared implementation; make does not otherwise
# discover device-side include dependencies.
kernel.elf: $(SRC_DIR)/kernel.cpp

include ../common.mk
