// Exercise the production initializer and verifier without a device/runtime.
#define main naive_app_main
#include "../../tests/regression/fpint_gemm_ffn_hw_naive/main.cpp"
#undef main
#include <cassert>

static std::vector<uint16_t> reference_from_payload(
    const std::vector<uint16_t>& a, const std::vector<uint8_t>& w,
    const std::vector<uint16_t>& scales, const std::vector<int16_t>& zeros,
    bool wrong_scale, bool wrong_zero, std::vector<double>* sums = nullptr) {
  std::vector<uint16_t> result(M * N);
  if (sums) sums->resize(M * N);
  const uint32_t groups = (K + QBLK - 1) / QBLK;
  const uint32_t ngroups = (N + QBLK - 1) / QBLK;
  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t n = 0; n < N; ++n) {
      double sum = 0;
      for (uint32_t k = 0; k < K; ++k) {
        const uint32_t wi = WTRANS ? n * ((K + 1) / 2) + k / 2
                                   : k * ((N + 1) / 2) + n / 2;
        const uint32_t shift = ((WTRANS ? k : n) & 1) * 4;
        const int bits = (w[wi] >> shift) & 15;
        const int weight = bits < 8 ? bits : bits - 16;
        const uint32_t qi = QDIR ? k * ngroups + n / QBLK
                                 : (k / QBLK) * N + n;
        // Wrong K group/row with unchanged expected metadata, separately for S/Z.
        const uint32_t bad = QDIR ? ((k + 1) % K) * ngroups + n / QBLK
                                  : ((k / QBLK + 1) % groups) * N + n;
        const float av = fp16_to_float(a[m * K + k]);
        const float scale = fp16_to_float(scales[wrong_scale ? bad : qi]);
        const int zero = zeros[wrong_zero ? bad : qi];
        if (QDIR)
          assert(fp16_to_float(float_to_fp16(av * scale)) == av * scale);
        sum += double(av) * double(weight - zero) * double(scale);
      }
      result[m * N + n] = float_to_fp16(float(sum));
      if (sums) (*sums)[m * N + n] = sum;
    }
  }
  return result;
}

static unsigned rejected(const std::vector<uint16_t>& actual,
                         const std::vector<uint16_t>& expected, float tolerance) {
  unsigned count = 0;
  for (size_t i = 0; i < actual.size(); ++i)
    count += !compare_fp16(actual[i], expected[i], tolerance);
  return count;
}

static void check_local_faults() {
  M = 4; K = 512; N = 512; QBLK = 32; QDIR = 0; WTRANS = 0;
  std::vector<uint16_t> a, scales, expected;
  std::vector<uint8_t> w;
  std::vector<int16_t> zeros;
  build_test_vectors(a, w, scales, zeros, expected, true);
  auto stale = scales;
  stale[N] = scales[0];
  const auto actual = reference_from_payload(a, w, stale, zeros, false, false);
  assert(rejected(actual, expected, 0.01f) == 0); // Historical review counterexample.
  assert(rejected(actual, expected, FP16_TOL) == 4);
  printf("Review single-scale counterexample: rejected=0 at 1%%, rejected=4 at 0.1%%\n");

  // Exhaustive historical fault family: one QCOL scale element replaced by
  // the preceding group's value. Use unrounded sums, not rounded FP16 C,
  // when applying the isolated group's delta.
  std::vector<double> sums;
  assert(reference_from_payload(a, w, scales, zeros, false, false, &sums) == expected);
  unsigned total = 0, unchanged = 0, missed_old = 0, missed_new = 0;
  for (uint32_t kg = 1; kg < K / QBLK; ++kg) {
    for (uint32_t n = 0; n < N; ++n) {
      bool changed = false, old_detected = false, new_detected = false;
      const double delta_scale = fp16_to_float(scales[(kg - 1) * N + n])
                               - fp16_to_float(scales[kg * N + n]);
      for (uint32_t m = 0; m < M; ++m) {
        double delta = 0;
        for (uint32_t k = kg * QBLK; k < (kg + 1) * QBLK; ++k) {
          const int bits = (w[k * ((N + 1) / 2) + n / 2] >> ((n & 1) * 4)) & 15;
          const int weight = bits < 8 ? bits : bits - 16;
          delta += fp16_to_float(a[m * K + k])
                 * double(weight - zeros[kg * N + n]) * delta_scale;
        }
        const uint16_t bad = float_to_fp16(float(sums[m * N + n] + delta));
        changed |= bad != expected[m * N + n];
        old_detected |= !compare_fp16(bad, expected[m * N + n], 0.01f);
        new_detected |= !compare_fp16(bad, expected[m * N + n], FP16_TOL);
      }
      ++total;
      unchanged += !changed;
      missed_old += changed && !old_detected;
      missed_new += changed && !new_detected;
    }
  }
  assert(total == 7680 && missed_old == 1390);
  assert(unchanged == 0 && missed_new == 0);
  printf("Single-scale census: total=%u output_unchanged=%u changed_but_pass_1pct=%u changed_but_pass_0.1pct=%u\n",
         total, unchanged, missed_old, missed_new);

  unsigned local_cases = 0;
  for (QDIR = 0; QDIR != 2; ++QDIR) {
    for (WTRANS = 0; WTRANS != 2; ++WTRANS) {
      build_test_vectors(a, w, scales, zeros, expected, true);
      // Isolate one K position so local payload errors cannot be diluted by
      // hundreds of correct products. This is additional oracle coverage;
      // the production default initializer remains unchanged.
      std::fill(a.begin(), a.end(), uint16_t(0));
      const uint32_t active_k = QDIR ? 1 : QBLK;
      for (uint32_t m = 0; m < M; ++m)
        a[m * K + active_k] = float_to_fp16(1.0f);
      expected = reference_from_payload(a, w, scales, zeros, false, false);
      const uint32_t stride = QDIR ? (N + QBLK - 1) / QBLK : N;
      // One element, an 8-byte lane, and a 32-byte payload block. Each
      // refers to S/Z array bytes, not a claim about a device bus mapping.
      for (uint32_t elements : {1u, 4u, 16u}) {
        for (unsigned fault = 1; fault <= 2; ++fault) {
          auto bad_scales = scales;
          auto bad_zeros = zeros;
          for (uint32_t j = 0; j < elements; ++j) {
            if (fault == 1) bad_scales[stride + j] = scales[j];
            else bad_zeros[stride + j] = zeros[j];
          }
          const auto bad = reference_from_payload(a, w, bad_scales, bad_zeros, false, false);
          const unsigned failures = rejected(bad, expected, FP16_TOL);
          assert(failures > 0);
          printf("Sparse local fault QDIR=%u WTRANS=%u elements=%u resource=%s rejected=%u\n",
                 QDIR, WTRANS, elements, fault == 1 ? "S" : "Z", failures);
          ++local_cases;
        }
      }
    }
  }
  printf("PASS: %u sparse local-payload controls\n", local_cases);
}

int main() {
  static_assert(FP16_TOL == 0.001f, "User requires 0.1% numerical tolerance");
  const uint16_t zero = float_to_fp16(0.0f);
  const uint16_t one = float_to_fp16(1.0f);
  assert(compare_fp16(float_to_fp16(1.0f / 1024), zero, FP16_TOL));
  assert(!compare_fp16(float_to_fp16(2.0f / 1024), zero, FP16_TOL));
  assert(compare_fp16(float_to_fp16(1.0f + 1.0f / 1024), one, FP16_TOL));
  assert(!compare_fp16(float_to_fp16(1.0f + 2.0f / 1024), one, FP16_TOL));
  unsigned cases = 0;
  for (auto shape : {std::vector<uint32_t>{4, 512, 512}, {3, 64, 48}, {16, 256, 128}}) {
    M = shape[0]; K = shape[1]; N = shape[2]; QBLK = 32;
    for (QDIR = 0; QDIR != 2; ++QDIR) {
      for (WTRANS = 0; WTRANS != 2; ++WTRANS) {
        std::vector<uint16_t> a, scales, expected;
        std::vector<uint8_t> w;
        std::vector<int16_t> zeros;
        build_test_vectors(a, w, scales, zeros, expected, true);
        const auto correct = reference_from_payload(a, w, scales, zeros, false, false);
        assert(correct == expected);
        for (auto v : expected) assert(std::isfinite(fp16_to_float(v)));
        for (unsigned fault = 1; fault <= 3; ++fault) {
          const auto wrong = reference_from_payload(a, w, scales, zeros, fault & 1, fault & 2);
          unsigned mismatches = 0;
          for (size_t i = 0; i < wrong.size(); ++i)
            mismatches += !compare_fp16(wrong[i], expected[i], FP16_TOL);
          assert(mismatches > 0);
          printf("M=%u K=%u N=%u QDIR=%u WTRANS=%u fault=%u rejected=%u\n",
                 M, K, N, QDIR, WTRANS, fault, mismatches);
        }
        ++cases;
      }
    }
  }
  printf("PASS: %u shapes/modes; correct payload reference and 36 negative controls\n", cases);
  check_local_faults();
}
