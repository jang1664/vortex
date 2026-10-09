ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk
PROJECT := llama_decoder_C4
SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)
SRCS := $(SRC_DIR)/main.cpp $(SRC_DIR)/decoder.cpp $(wildcard $(SRC_DIR)/ops/host_*.cpp)
VX_SRCS := $(SRC_DIR)/kernel.cpp $(wildcard $(SRC_DIR)/ops/device_*.cpp)
# Tags must match the reused variant sources in ops/device_*.cpp.
DECODER_VARIANT_FLAGS := -DHADAMARD_LAYOUT_FUSED_VARIANT_TAG=3 \
  -DRMS_NORM_LAYOUT_FUSED_VARIANT_TAG=2 -DROPE_LAYOUT_FUSED_VARIANT_TAG=1 \
  -DSOFTMAX_LAYOUT_FUSED_VARIANT=10 -DSOFTMAX_LAYOUT_FUSED_VARIANT_KERNEL=10 -DSILU_LAYOUT_FUSED_VARIANT_TAG=2 \
  -DELMUL_LAYOUT_FUSED_VARIANT_TAG=2 -DELADD_LAYOUT_FUSED_VARIANT_TAG=3 \
  -DHEAD_CONCAT_LAYOUT_FUSED_VARIANT_TAG=1 -DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG=9
CXXFLAGS += $(DECODER_VARIANT_FLAGS) -include $(VORTEX_HOME)/tests/regression/vector_common/config_check.h
VX_CFLAGS += $(DECODER_VARIANT_FLAGS) -include $(VORTEX_HOME)/tests/regression/vector_common/config_check.h
include ../common.mk
.PHONY: check-host
check-host:
	/usr/bin/g++ -std=c++17 -O2 $(SRC_DIR)/layout_check.cpp -o layout_check
	./layout_check
# The wrappers include the original source. Track its dependencies too.
kernel.elf: $(wildcard $(SRC_DIR)/../*_layout_fused/*.cpp) \
  $(wildcard $(SRC_DIR)/../*_layout_fused/*.h) \
  $(wildcard $(SRC_DIR)/../kv_cache_quant_layout_fused_w4a16/*.*) \
  $(wildcard $(SRC_DIR)/../fpint_gemm_ffn_hw/*.h) \
  $(SRC_DIR)/../fpint_gemm_ffn_hw/kernel.cpp \
  $(wildcard $(SRC_DIR)/../softmax_common/*.h) \
  $(wildcard $(SRC_DIR)/../vector_common/*.h) $(SRC_DIR)/common.h
