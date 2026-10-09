#pragma once

// Use the standalone naive regression ABI without changing that application.
#undef _COMMON_H_
#define kernel_arg_t DecoderNaiveArgs
#include "../fpint_gemm_ffn_hw_naive/common.h"
#undef kernel_arg_t
#undef _COMMON_H_
