#pragma once
#include <stdint.h>
#ifndef DECODER_C1_FPFP
#define DECODER_C1_FPFP 0
#endif
#ifndef DECODER_C2_FPFP
#define DECODER_C2_FPFP 0
#endif
#define DECODER_ATTN_FPFP (DECODER_C1_FPFP || DECODER_C2_FPFP)
#define DECODER_HAS_TCU (DECODER_CANDIDATE != 3 && !DECODER_ATTN_FPFP)
#define DECODER_HAS_NAIVE (DECODER_CANDIDATE != 1 || DECODER_C1_FPFP)
enum class DecoderOp : uint32_t { gemm, tcu, rms, rope, hadamard, quant, dequant, softmax, concat, silu, elmul, eladd, reorder };
struct DecoderDispatch { DecoderOp operation; uint64_t args_address; };
struct DecoderReorderArgs { uint32_t grid_dim[3], block_dim[3]; uint64_t input, output; uint32_t batch, seq, heads, dim, kind; };
