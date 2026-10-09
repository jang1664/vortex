ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk
SRC_DIR := $(VORTEX_HOME)/tests/regression/llama_decoder_common
SRCS := $(SRC_DIR)/main.cpp $(SRC_DIR)/decoder.cpp
VX_SRCS := $(SRC_DIR)/kernel.cpp $(wildcard $(SRC_DIR)/device_*.cpp)
ifeq ($(DECODER_CANDIDATE),1)
VX_SRCS := $(filter-out $(SRC_DIR)/device_naive.cpp,$(VX_SRCS))
endif
ifeq ($(DECODER_CANDIDATE),3)
VX_SRCS := $(filter-out $(SRC_DIR)/device_tcu.cpp,$(VX_SRCS))
endif
FLAGS := -DDECODER_CANDIDATE=$(DECODER_CANDIDATE) -DSGEMM_TCU_VARIANT=1 -DRMSNORM_VARIANT_TAG=1 -DROPE_VARIANT_TAG=1 -DHADAMARD_VARIANT_TAG=2 -DKV_CACHE_QUANT_ARITH_FP16=1
FLAGS += -DKV_CACHE_QUANT_VARIANT=2 -DKV_CACHE_DEQUANT_VARIANT=3 -DKV_CACHE_DEQUANT_ARITH_FP16=1 -DHEAD_CONCAT_VARIANT_TAG=1
CXXFLAGS += $(FLAGS)
VX_CFLAGS += $(FLAGS)
include ../common.mk
kernel.elf: $(wildcard $(SRC_DIR)/*.h) $(wildcard $(SRC_DIR)/../kv_cache_common/*.h) $(wildcard $(SRC_DIR)/../softmax_common/*.h)
# Device wrappers include these sources directly; track their implementation too.
REUSED_APPS := sgemm_tcu rmsnorm rope hadamard kv_cache_quant_w4a16 kv_cache_dequant_w4a16 softmax head_concat silu elmul eladd fpint_gemm_ffn_hw_naive vector_common
kernel.elf: $(foreach app,$(REUSED_APPS),$(wildcard $(SRC_DIR)/../$(app)/*.cpp) $(wildcard $(SRC_DIR)/../$(app)/*.h))
