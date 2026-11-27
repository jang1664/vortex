ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := kivi_quant_layout_fused

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

VX_SRCS := $(SRC_DIR)/kernel.prefill_reuse_inline_group1_source_weight_cursor.cpp
CXXFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=9
VX_CFLAGS += -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=9

# Variant wrappers include the shared implementation; make does not otherwise
# discover device-side include dependencies.
kernel.elf: $(SRC_DIR)/kernel.cpp
ORIGINAL_HEADERS := $(SRC_DIR)/../kv_cache_quant_layout_fused_w4a16
kernel.elf: $(SRC_DIR)/common.h $(ORIGINAL_HEADERS)/common.h

include ../common.mk

$(PROJECT) $(BENCH_PROJECT): $(SRC_DIR)/host_common.h $(SRC_DIR)/common.h \
    $(ORIGINAL_HEADERS)/host_common.h $(ORIGINAL_HEADERS)/common.h

# Shared numeric helpers affect both source and variant wrappers.
kernel.elf: $(VORTEX_HOME)/tests/regression/vector_common/fp16_preserve.h $(VORTEX_HOME)/tests/regression/kv_cache_common/kv_cache_w4a16.h
$(PROJECT): $(VORTEX_HOME)/tests/regression/kv_cache_common/quant_host_patterns.h
kernel.elf: $(VORTEX_HOME)/tests/regression/kv_cache_common/kivi_int4.h
$(PROJECT): $(VORTEX_HOME)/tests/regression/kv_cache_common/kivi_reference.h
