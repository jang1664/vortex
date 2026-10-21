ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk
SRC_DIR := $(VORTEX_HOME)/tests/regression/llama_decoder_common
SRCS := $(SRC_DIR)/main.cpp $(SRC_DIR)/decoder.cpp
VX_SRCS := $(SRC_DIR)/kernel.cpp $(wildcard $(SRC_DIR)/device_*.cpp)
# C1 defaults to the arithmetic engine present in the selected hardware image.
C1_GEMM_BACKEND ?= auto
C2_ATTN_BACKEND ?= auto
C1_SELECTED_GEMM_BACKEND := $(C1_GEMM_BACKEND)
ifeq ($(C1_SELECTED_GEMM_BACKEND),auto)
ifneq (,$(findstring -DGEMM_NAIVE_FP16_ENABLE,$(CONFIGS)))
C1_SELECTED_GEMM_BACKEND := fpfp
else
C1_SELECTED_GEMM_BACKEND := tcu
endif
endif
ifeq ($(filter $(C1_SELECTED_GEMM_BACKEND),tcu fpfp),)
$(error C1_GEMM_BACKEND must be auto, tcu or fpfp)
endif
ifeq ($(DECODER_CANDIDATE),1)
ifeq ($(C1_SELECTED_GEMM_BACKEND),tcu)
VX_SRCS := $(filter-out $(SRC_DIR)/device_naive.cpp,$(VX_SRCS))
else
VX_SRCS := $(filter-out $(SRC_DIR)/device_tcu.cpp,$(VX_SRCS))
CXXFLAGS += -DDECODER_C1_FPFP=1
VX_CFLAGS += -DDECODER_C1_FPFP=1
endif
endif
ifeq ($(DECODER_CANDIDATE),2)
C2_SELECTED_ATTN_BACKEND := $(C2_ATTN_BACKEND)
ifeq ($(C2_SELECTED_ATTN_BACKEND),auto)
ifneq (,$(findstring -DGEMM_NAIVE_FP16_ENABLE,$(CONFIGS)))
C2_SELECTED_ATTN_BACKEND := fpfp
else
C2_SELECTED_ATTN_BACKEND := tcu
endif
endif
ifeq ($(filter $(C2_SELECTED_ATTN_BACKEND),tcu fpfp),)
$(error C2_ATTN_BACKEND must be auto, tcu or fpfp)
endif
ifeq ($(C2_SELECTED_ATTN_BACKEND),fpfp)
VX_SRCS := $(filter-out $(SRC_DIR)/device_tcu.cpp,$(VX_SRCS))
CXXFLAGS += -DDECODER_C2_FPFP=1
VX_CFLAGS += -DDECODER_C2_FPFP=1
endif
endif
ifeq ($(DECODER_CANDIDATE),3)
VX_SRCS := $(filter-out $(SRC_DIR)/device_tcu.cpp,$(VX_SRCS))
endif
FLAGS := -DDECODER_CANDIDATE=$(DECODER_CANDIDATE) -DSGEMM_TCU_VARIANT=1 -DRMSNORM_VARIANT_TAG=1 -DROPE_VARIANT_TAG=1 -DHADAMARD_VARIANT_TAG=2 -DKV_CACHE_QUANT_ARITH_FP16=1
FLAGS += -DKV_CACHE_QUANT_VARIANT=2 -DKV_CACHE_DEQUANT_VARIANT=3 -DKV_CACHE_DEQUANT_ARITH_FP16=1 -DHEAD_CONCAT_VARIANT_TAG=1
FLAGS += -DROPE_OUTPUT_HEAD_MAJOR=1 -DKV_CACHE_QUANT_INPUT_STRIDE=1 -DSGEMM_TCU_RUNTIME_B_LAYOUT=1
CXXFLAGS += $(FLAGS)
VX_CFLAGS += $(FLAGS)
include ../common.mk
kernel.elf: $(wildcard $(SRC_DIR)/*.h) $(wildcard $(SRC_DIR)/../kv_cache_common/*.h) $(wildcard $(SRC_DIR)/../softmax_common/*.h)
# Device wrappers include these sources directly; track their implementation too.
REUSED_APPS := sgemm_tcu rmsnorm rope hadamard kv_cache_quant_w4a16 kv_cache_dequant_w4a16 softmax head_concat silu elmul eladd fpint_gemm_ffn_hw_naive vector_common
kernel.elf: $(foreach app,$(REUSED_APPS),$(wildcard $(SRC_DIR)/../$(app)/*.cpp) $(wildcard $(SRC_DIR)/../$(app)/*.h))
