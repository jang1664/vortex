ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := kv_cache_quant_layout_fused_w4a16

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT ?= baseline
KV_CACHE_QUANT_LAYOUT_FUSED_VARIANTS := baseline qparam_warp
ifneq ($(filter $(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT),$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANTS)),$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT))
  $(error Unsupported KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT=$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT); expected one of: $(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT).cpp

# Variant wrappers include the shared implementation; make does not otherwise
# discover device-side include dependencies.
kernel.elf: $(SRC_DIR)/kernel.cpp

include ../common.mk
