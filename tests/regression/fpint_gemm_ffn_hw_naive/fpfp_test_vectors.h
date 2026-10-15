#ifndef FPFP_GEMM_TEST_VECTORS_H
#define FPFP_GEMM_TEST_VECTORS_H

#include <algorithm>
#include <cstdint>
#include <vector>
#include "../fpint_gemm_ffn_hw/test_vectors.h"

// FPFP uses ordinary row-major half operands, with no quantization metadata.
// Keep the reference independent of RTL address generation and DMA tiling.
namespace fpfp_gemm_test {

template <typename Decode, typename Encode>
void initialize(uint32_t m_size, uint32_t k_size, uint32_t n_size,
                uint32_t tree_rows, uint32_t seed, uint32_t generation,
                bool tagged, bool subnormal,
                std::vector<uint16_t>& a, std::vector<uint8_t>& w_bytes,
                std::vector<uint16_t>& out, std::vector<double>& mathematical,
                bool compute_reference, Decode decode, Encode encode) {
  a.resize(size_t(m_size) * k_size);
  std::vector<uint16_t> w(size_t(k_size) * n_size);
  // Hashing the logical index makes vectors reproducible across WLOAD settings.
  auto sample = [&](uint32_t index, uint32_t salt) {
    const uint32_t bits = fpint_gemm_test::identity_hash(index ^ salt ^ seed
                          ^ (generation * 0x9e3779b9u));
    if (tagged)
      return encode(float(int(bits % 17) - 8) / 8.0f);
    // Finite, signed normal values, with all ten half mantissa bits varying.
    return uint16_t(((bits >> 16) & 0x8000u)
                    | ((11u + ((bits >> 10) % 5u)) << 10) | (bits & 0x3ffu));
  };
  for (uint32_t m = 0; m < m_size; ++m)
    for (uint32_t k = 0; k < k_size; ++k) {
      uint16_t value = sample(m * k_size + k, 0x12345678u);
      if (subnormal) {
        constexpr uint16_t directed[] = {0x0001, 0x03ff, 0x0400, 0x3555,
                                         0x3c00, 0xbc00, 0x0000, 0x8000};
        value = directed[k % 8] ^ (((m + generation) & 1) ? 0x8000u : 0u);
      }
      a[size_t(m) * k_size + k] = value;
    }
  for (uint32_t k = 0; k < k_size; ++k)
    for (uint32_t n = 0; n < n_size; ++n) {
      uint16_t value = sample(k * n_size + n, 0xabcdef01u);
      if (subnormal) {
        value = 0;
        switch (n % 8) {
          case 0: value = 0x3800; break;
          case 1: if (k == 0) value = 0x3c00; break;
          case 2: if (k == 1) value = 0x3c00; break;
          case 3: if (k == 2) value = 0xbc00; break;
          case 4: if (k == 3) value = 0x3c00; break;
          case 5: if (k == 4) value = 0x0001; break;
          case 6: if (k == 4) value = 0x03ff; break;
          case 7: if (k == 4 || k == 5) value = 0x3c00; break;
        }
      }
      w[size_t(k) * n_size + n] = value;
    }
  w_bytes.resize(w.size() * 2);
  for (size_t i = 0; i < w.size(); ++i) {
    w_bytes[2 * i] = uint8_t(w[i]);
    w_bytes[2 * i + 1] = uint8_t(w[i] >> 8);
  }
  out.assign(size_t(m_size) * n_size, 0);
  mathematical.clear();
  if (!compute_reference) return;
  mathematical.resize(out.size());
  std::vector<float> tree(tree_rows);
  for (uint32_t m = 0; m < m_size; ++m)
    for (uint32_t n = 0; n < n_size; ++n) {
      float accumulator = 0;
      double exact = 0;
      for (uint32_t k0 = 0; k0 < k_size; k0 += tree_rows) {
        std::fill(tree.begin(), tree.end(), 0.0f);
        for (uint32_t lane = 0; lane < tree_rows && k0 + lane < k_size; ++lane) {
          const float av = decode(a[size_t(m) * k_size + k0 + lane]);
          const float wv = decode(w[size_t(k0 + lane) * n_size + n]);
          tree[lane] = av * wv;  // Each finite half product is exact in FP32.
          exact += double(av) * double(wv);
        }
        for (uint32_t count = tree_rows; count > 1; count /= 2)
          for (uint32_t lane = 0; lane < count / 2; ++lane)
            tree[lane] = tree[2 * lane] + tree[2 * lane + 1];
        accumulator = accumulator + tree[0];
      }
      out[size_t(m) * n_size + n] = encode(accumulator);
      mathematical[size_t(m) * n_size + n] = exact;
    }
}

} // namespace fpfp_gemm_test
#endif
