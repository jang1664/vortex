#ifndef LLAMA_DECODER_C4_COMMON_H
#define LLAMA_DECODER_C4_COMMON_H
#include <stdint.h>
enum class DecoderOp : uint32_t {
  gemm, rms, rope, hadamard, quant, softmax, concat, silu, elmul, eladd
};
struct DecoderDispatch {
  uint64_t args_address;
  DecoderOp operation;
  uint32_t reserved;
};
#endif
