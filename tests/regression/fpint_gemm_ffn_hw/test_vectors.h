#ifndef FPINT_GEMM_TEST_VECTORS_H
#define FPINT_GEMM_TEST_VECTORS_H

#include <cstdint>
#include <vector>

// Logical tensors shared by LMEM and TMEM tests. Only storage conversion
// belongs to the backend. Generation zero preserves the corrected defaults.
namespace fpint_gemm_test {

inline uint32_t identity_hash(uint32_t x) {
  x ^= x >> 16;
  x *= 0x7feb352du;
  x ^= x >> 15;
  x *= 0x846ca68bu;
  return x ^ (x >> 16);
}

inline int8_t unpack_int4(uint8_t byte, uint32_t lane) {
  const int bits = (byte >> (4 * (lane & 1))) & 15;
  return static_cast<int8_t>(bits < 8 ? bits : bits - 16);
}

template <typename Encode>
void initialize(uint32_t m_size, uint32_t k_size, uint32_t n_size,
                uint32_t logical_k, uint32_t logical_n, uint32_t qblk,
                uint32_t qdir, uint32_t generation, bool tagged,
                std::vector<uint16_t>& a, std::vector<int8_t>& w,
                std::vector<uint16_t>& scales, std::vector<int16_t>& zeros,
                Encode encode) {
  const uint32_t ngroups = (n_size + qblk - 1) / qblk;
  const uint32_t qsize = qdir ? k_size * ngroups
                            : ((k_size + qblk - 1) / qblk) * n_size;
  a.assign(m_size * k_size, 0);
  w.assign(k_size * n_size, 0);
  scales.assign(qsize, 0);
  zeros.assign(qsize, 0);
  for (uint32_t m = 0; m < m_size; ++m)
    for (uint32_t k = 0; k < logical_k; ++k) {
      const uint32_t identity = tagged ? identity_hash(m * logical_k + k)
                                       : m + k;
      a[m * k_size + k] = encode(1.0f + float((identity % 7 + generation % 7) % 7));
    }
  for (uint32_t k = 0; k < logical_k; ++k)
    for (uint32_t n = 0; n < logical_n; ++n) {
      const uint32_t identity = tagged ? identity_hash(k * logical_n + n + 0x9e3779b9u)
                                       : k * logical_n + n;
      w[k * n_size + n] = int8_t(int((identity % 7 + generation % 7) % 7) - 3);
    }
  const uint32_t rows = qdir ? logical_k : (logical_k + qblk - 1) / qblk;
  const uint32_t cols = qdir ? (logical_n + qblk - 1) / qblk : logical_n;
  const uint32_t stride = qdir ? ngroups : n_size;
  for (uint32_t row = 0; row < rows; ++row)
    for (uint32_t col = 0; col < cols; ++col) {
      // Integer A times these bounded dyadic scales is exact in FP16,
      // including the QROW pre-multiply. Consecutive jobs change S and Z.
      const float scale = 1.0f + float((row % 17 + generation % 17) % 17) / 16.0f
                         + float(col % 7) / 8.0f;
      scales[row * stride + col] = encode(scale);
      zeros[row * stride + col] = int16_t(int((3 * (row % 7) + col % 7 + generation % 7) % 7) - 3);
    }
}

// Decode W from the bytes prepared for upload, never from the initializer's
// formula. Expected tensors must be frozen before a device-side fault is injected.
template <typename Weight, typename Decode, typename Encode>
void reference(uint32_t m_size, uint32_t k_size, uint32_t n_size,
               uint32_t logical_k, uint32_t logical_n, uint32_t qblk,
               uint32_t qdir, const std::vector<uint16_t>& a,
               const std::vector<uint16_t>& scales,
               const std::vector<int16_t>& zeros, Weight weight,
               Decode decode, Encode encode, std::vector<uint16_t>& out) {
  const uint32_t ngroups = (n_size + qblk - 1) / qblk;
  out.assign(m_size * n_size, 0);
  for (uint32_t m = 0; m < m_size; ++m)
    for (uint32_t n = 0; n < logical_n; ++n) {
      float sum = 0;
      for (uint32_t k = 0; k < logical_k; ++k) {
        const uint32_t qi = qdir ? k * ngroups + n / qblk : (k / qblk) * n_size + n;
        const float av = decode(a[m * k_size + k]);
        const float scale = decode(scales[qi]);
        const float centered_w = float(weight(k, n)) - float(zeros[qi]);
        sum += qdir ? decode(encode(av * scale)) * centered_w
                    : av * (centered_w * scale);
      }
      out[m * n_size + n] = encode(sum);
    }
}

} // namespace fpint_gemm_test
#endif
