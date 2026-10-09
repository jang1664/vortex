#pragma once
#include <stdint.h>
#include <VX_config.h>
// Keep the existing wire structures; only disambiguate their C++ type names.
#undef _COMMON_H_
#define kernel_arg_t DecoderGemmArgs
#include "../fpint_gemm_ffn_hw/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderRmsArgs
#include "../rms_norm_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderRopeArgs
#include "../rope_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderHadamardArgs
#include "../hadamard_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderQuantArgs
#include "../kv_cache_quant_layout_fused_w4a16/common.h"
#include "../kv_cache_quant_layout_fused_w4a16/host_common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderSoftmaxArgs
#include "../softmax_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderConcatArgs
#include "../head_concat_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderSiluArgs
#include "../silu_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderElmulArgs
#include "../elmul_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderEladdArgs
#include "../eladd_layout_fused/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
