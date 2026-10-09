#pragma once
#include <VX_config.h>
#undef _COMMON_H_
#define kernel_arg_t DecoderTcuArgs
#include "../sgemm_tcu/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderRmsArgs
#include "../rmsnorm/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderRopeArgs
#include "../rope/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderHadamardArgs
#include "../hadamard/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderQuantArgs
#include "../kv_cache_quant_w4a16/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderDequantArgs
#include "../kv_cache_dequant_w4a16/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderSoftmaxArgs
#include "../softmax/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderConcatArgs
#include "../head_concat/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderSiluArgs
#include "../silu/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderElmulArgs
#include "../elmul/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
#define kernel_arg_t DecoderEladdArgs
#include "../eladd/common.h"
#undef kernel_arg_t
#if DECODER_CANDIDATE != 1
#include "naive_args.h"
#endif
