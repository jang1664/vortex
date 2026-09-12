// Compile once per backend; identical digest lines prove logical tensor parity.
#define main fpint_app_main
#ifdef P0_IMPROVE
#include "../../tests/regression/fpint_gemm_ffn_hw/main.cpp"
#else
#include "../../tests/regression/fpint_gemm_ffn_hw_naive/main.cpp"
#endif
#undef main
#include <cassert>
#include <set>

static uint64_t hash_word(uint64_t h, uint16_t value) {
  return (h ^ value) * 1099511628211ull;
}

int main() {
  for (auto shape : {std::vector<uint32_t>{4, 512, 512},
                     std::vector<uint32_t>{256, 512, 512},
                     std::vector<uint32_t>{3, 65, 33}}) {
    M = shape[0];
    const uint32_t lk = shape[1], ln = shape[2];
#ifdef P0_IMPROVE
    K_logical = lk; N_logical = ln;
    K = ((lk + DMA_MXU_KT - 1) / DMA_MXU_KT) * DMA_MXU_KT;
    N = ((ln + DMA_MXU_NT - 1) / DMA_MXU_NT) * DMA_MXU_NT;
#else
    K = lk; N = ln;
#endif
    QBLK = 32;
    for (QDIR = 0; QDIR < 2; ++QDIR)
      for (WTRANS = 0; WTRANS < 2; ++WTRANS)
        for (int tagged = 0; tagged < 2; ++tagged) {
          TAGGED_VECTORS = tagged;
          uint64_t previous[5] = {};
          for (uint32_t generation = 0; generation < 3; ++generation) {
            std::vector<uint16_t> a, scales, expected;
            std::vector<int16_t> zeros;
#ifdef P0_IMPROVE
            std::vector<int8_t> raw;
            build_test_vectors(a, raw, scales, zeros, expected, true, generation);
            std::vector<uint8_t> packed;
            convert_weight_tiled(raw, packed);
            auto weight = [&](uint32_t k, uint32_t n) { return tiled_weight_at(packed, k, n); };
            for (uint32_t k = 0; k < K; ++k)
              for (uint32_t n = 0; n < N; ++n)
                assert(weight(k, n) == raw[k * N + n]);
#else
            std::vector<uint8_t> packed;
            build_test_vectors(a, packed, scales, zeros, expected, true, generation);
            auto weight = [&](uint32_t k, uint32_t n) {
              const uint32_t stride = WTRANS ? (K + 1) / 2 : (N + 1) / 2;
              const uint8_t byte = packed[WTRANS ? n * stride + k / 2 : k * stride + n / 2];
              const int bits = (byte >> (4 * ((WTRANS ? k : n) & 1))) & 15;
              return bits < 8 ? bits : bits - 16;
            };
#endif
            uint64_t digest[5] = {1, 1, 1, 1, 1};
            std::set<std::vector<uint16_t>> rows;
            for (uint32_t m = 0; m < M; ++m) {
              std::vector<uint16_t> row(a.begin() + m * K, a.begin() + m * K + lk);
              rows.insert(row);
              for (auto v : row) digest[0] = hash_word(digest[0], v);
            }
            if (tagged) assert(rows.size() == M);
            for (uint32_t k = 0; k < lk; ++k)
              for (uint32_t n = 0; n < ln; ++n)
                digest[1] = hash_word(digest[1], uint16_t(weight(k, n)));
            const uint32_t qr = QDIR ? lk : (lk + QBLK - 1) / QBLK;
            const uint32_t qc = QDIR ? (ln + QBLK - 1) / QBLK : ln;
            const uint32_t qs = QDIR ? (N + QBLK - 1) / QBLK : N;
            for (uint32_t r = 0; r < qr; ++r)
              for (uint32_t c = 0; c < qc; ++c) {
                digest[2] = hash_word(digest[2], scales[r * qs + c]);
                digest[3] = hash_word(digest[3], zeros[r * qs + c]);
              }
            // Independent double-precision accumulation checks the production
            // packed-byte oracle; bounded dyadic A*S is exactly representable.
            for (uint32_t m = 0; m < M; ++m)
              for (uint32_t n = 0; n < ln; ++n) {
                double sum = 0;
                for (uint32_t k = 0; k < lk; ++k) {
                  const uint32_t qi = QDIR ? k * qs + n / QBLK : (k / QBLK) * qs + n;
                  const double av = fp16_to_float(a[m * K + k]);
                  const double sv = fp16_to_float(scales[qi]);
                  if (QDIR) assert(fp16_to_float(float_to_fp16(av * sv)) == av * sv);
                  sum += av * sv * (weight(k, n) - zeros[qi]);
                }
                const auto e = expected[m * N + n];
                assert(e == float_to_fp16(float(sum)));
                assert(std::isfinite(fp16_to_float(e)));
                assert(!compare_fp16(0x7e00, e, FP16_TOL));
                assert(!compare_fp16(0xffff, e, FP16_TOL));
                digest[4] = hash_word(digest[4], e);
              }
            if (tagged && lk == 512 && ln == 512) {
              // All 16x16 weight microtiles have distinct complete payloads.
              std::set<std::vector<int>> tiles;
              for (uint32_t kb = 0; kb < lk; kb += 16)
                for (uint32_t nb = 0; nb < ln; nb += 16) {
                  std::vector<int> tile;
                  for (uint32_t k = kb; k < kb + 16; ++k)
                    for (uint32_t n = nb; n < nb + 16; ++n) tile.push_back(weight(k, n));
                  assert(tiles.insert(tile).second);
                }
            }
            if (tagged && generation == 0 && lk == 512 && ln == 512) {
              // The default W pattern aliases K microtile 7 with microtile 0.
              // A tagged replacement must produce a rejected numerical result.
              auto stale_weight = [&](uint32_t k, uint32_t n) {
                return weight((k >= 112 && k < 128 && n < 16) ? k - 112 : k, n);
              };
              std::vector<uint16_t> stale;
              fpint_gemm_test::reference(1, K, N, lk, ln, QBLK, QDIR, a,
                  scales, zeros, stale_weight, fp16_to_float, float_to_fp16, stale);
              bool rejected = false;
              for (uint32_t n = 0; n < 16; ++n)
                rejected |= !compare_fp16(stale[n], expected[n], FP16_TOL);
              assert(rejected);
              if (M > 7) {
                // Default A rows 0 and 7 alias. Check tagged row misaddressing.
                rejected = false;
                for (uint32_t n = 0; n < ln; ++n)
                  rejected |= !compare_fp16(expected[n], expected[7 * N + n], FP16_TOL);
                assert(rejected);
              }
            }
            for (unsigned i = 0; i < 5; ++i) {
              if (generation) assert(digest[i] != previous[i]);
              previous[i] = digest[i];
            }
            printf("M%u K%u N%u Q%u W%u tagged%d gen%u", M, lk, ln, QDIR, WTRANS, tagged, generation);
            for (auto d : digest) printf(" %016llx", static_cast<unsigned long long>(d));
            printf("\n");
          }
        }
  }
}
