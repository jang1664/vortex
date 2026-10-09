#pragma once
#include <stdint.h>
enum class DecoderOp : uint32_t { gemm, tcu, rms, rope, hadamard, quant, dequant, softmax, concat, silu, elmul, eladd, reorder };
struct DecoderDispatch { DecoderOp operation; uint64_t args_address; };
struct DecoderReorderArgs { uint32_t grid_dim[3], block_dim[3]; uint64_t input, output; uint32_t batch, seq, heads, dim, kind; };
