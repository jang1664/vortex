// Feed the existing A packer directly into the production C verifier.
// Only the device readback is replaced; no layout formula is copied here.
#define main fpint_regression_main
#include "tests/regression/fpint_gemm_ffn_hw/main.cpp"
#undef main

#include <cstring>

extern "C" int vx_copy_from_dev(void* dst, vx_buffer_h buffer,
                                uint64_t offset, uint64_t bytes) {
  const auto& packed = *static_cast<const std::vector<uint8_t>*>(buffer);
  if (offset > packed.size() || bytes > packed.size() - offset)
    return -1;
  std::memcpy(dst, packed.data() + offset, bytes);
  return 0;
}

int main() {
  static_assert(DMA_NT == DMA_KT && DMA_MXU_NT == DMA_MXU_KT,
                "Direct A/C reuse requires matching tile widths");
  unsigned cases = 0;
  for (unsigned rows : {1u, 3u, 4u, 8u, 9u, 128u, 132u, 256u}) {
    for (unsigned cols : {16u, 17u, 32u, 48u, 128u, 129u, 144u, 256u}) {
      M = rows;
      N_logical = cols;
      N = K = uint32_t(fpint_gemm_layout::align_up(cols, DMA_MXU_NT));
      std::vector<uint16_t> values(size_t(M) * N);
      for (unsigned m = 0; m < M; ++m)
        for (unsigned n = 0; n < N; ++n)
          values[size_t(m) * N + n] = float_to_fp16(
              float(int((m * 17 + n * 3) % 127) - 63) * 0.25f);
      std::vector<uint8_t> packed;
      convert_input_tiled(values, packed);
      if (verify_results_tiled(&packed, values) != 0)
        return 1;
      ++cases;
    }
  }
  printf("HOST A/C LAYOUT CHECK PASSED: %u shapes\n", cases);
  return 0;
}
