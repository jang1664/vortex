#include <iostream>
#include <unistd.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <algorithm>
#include <vortex.h>
#include "common.h"

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
     cleanup();                                                 \
     exit(-1);                                                  \
   } while (false)

static const char* kernel_file = "kernel.vxbin";

static uint32_t M = 2;
static uint32_t N = 32;
static uint32_t K = 32;
static uint32_t QBLK = 32;

static vx_device_h device = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;

static vx_buffer_h A_buffer = nullptr;       // fp16 [M x K]
static vx_buffer_h W_int4_buffer = nullptr;  // packed int4 [K x N]
static vx_buffer_h scales_buffer = nullptr;  // fp16 [KG x N]
static vx_buffer_h zeros_buffer = nullptr;   // int16 [KG x N]
static vx_buffer_h C_buffer = nullptr;       // fp16 [M x N]

static constexpr float FP16_TOL = 0.01f;
static constexpr uint64_t HOST_WAIT_TIMEOUT_MS = 3000000;

static constexpr uint64_t LMEM_LAYOUT_ALIGN_BYTES = 4096;
static constexpr uint64_t DMA_MT = GEMM_FSM_MT;
static constexpr uint64_t DMA_NT = GEMM_FSM_NT;
static constexpr uint64_t DMA_KT = GEMM_FSM_KT;

static constexpr uint64_t GEMM_MMIO_BASE_ADDR_CPP = 0x0000000000001080ull;

static constexpr uint64_t align_up_u64(uint64_t x, uint64_t a) {
  return (a == 0) ? x : ((x + a - 1) / a) * a;
}

static const char* status_to_str(uint32_t status) {
  switch (status) {
  case MMIO_STATUS_INIT: return "INIT";
  case MMIO_STATUS_OK: return "OK";
  case MMIO_STATUS_ALLOC_FAIL: return "ALLOC_FAIL";
  case MMIO_STATUS_WAIT_STUCK: return "WAIT_STUCK";
  case MMIO_STATUS_BAD_EID: return "BAD_EID";
  default: return "UNKNOWN";
  }
}

static void cleanup() {
  if (A_buffer) vx_mem_free(A_buffer);
  if (W_int4_buffer) vx_mem_free(W_int4_buffer);
  if (scales_buffer) vx_mem_free(scales_buffer);
  if (zeros_buffer) vx_mem_free(zeros_buffer);
  if (C_buffer) vx_mem_free(C_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);

  A_buffer = nullptr;
  W_int4_buffer = nullptr;
  scales_buffer = nullptr;
  zeros_buffer = nullptr;
  C_buffer = nullptr;
  krnl_buffer = nullptr;
  args_buffer = nullptr;
  device = nullptr;
}

static void show_usage() {
  std::cout << "Usage: [-m M] [-n N] [-k K] [-q QBLK] [-h]" << std::endl;
}

static void parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "m:n:k:q:h")) != -1) {
    switch (c) {
    case 'm': M = atoi(optarg); break;
    case 'n': N = atoi(optarg); break;
    case 'k': K = atoi(optarg); break;
    case 'q': QBLK = atoi(optarg); break;
    case 'h': show_usage(); exit(0); break;
    default: show_usage(); exit(-1);
    }
  }
}

static uint16_t float_to_fp16(float f) {
  union { float f; uint32_t i; } u = {f};
  uint32_t sign = (u.i >> 16) & 0x8000;
  int32_t exp = ((u.i >> 23) & 0xFF) - 127 + 15;
  uint32_t mantissa = (u.i >> 13) & 0x3FF;

  if (exp <= 0) return sign;
  if (exp >= 31) return sign | 0x7C00;

  return sign | (exp << 10) | mantissa;
}

static float fp16_to_float(uint16_t h) {
  uint32_t sign = (h >> 15) & 0x1;
  uint32_t exp = (h >> 10) & 0x1F;
  uint32_t mantissa = h & 0x3FF;

  if (exp == 0) {
    if (mantissa == 0) return sign ? -0.0f : 0.0f;
    float val = mantissa / 1024.0f;
    return sign ? -val / 16384.0f : val / 16384.0f;
  }
  if (exp == 31) return sign ? -INFINITY : INFINITY;

  uint32_t f = (sign << 31) | ((exp - 15 + 127) << 23) | (mantissa << 13);
  float out;
  __builtin_memcpy(&out, &f, sizeof(float));
  return out;
}

static uint8_t pack_int4_pair(int8_t lo, int8_t hi) {
  return uint8_t((uint8_t(hi) & 0x0F) << 4) | uint8_t(lo & 0x0F);
}

static int8_t unpack_int4_from_byte(uint8_t packed, bool high_nibble) {
  uint8_t v = high_nibble ? ((packed >> 4) & 0x0F) : (packed & 0x0F);
  return (v & 0x08) ? int8_t(v | 0xF0) : int8_t(v);
}

static void build_test_vectors(std::vector<uint16_t>& h_A,
                               std::vector<uint8_t>& h_W_int4,
                               std::vector<uint16_t>& h_scales,
                               std::vector<int16_t>& h_zeros,
                               std::vector<uint16_t>& h_ref_out_fp16) {
  uint32_t groups_total = (K + QBLK - 1) / QBLK;

  h_A.resize(M * K);
  h_W_int4.resize(K * ((N + 1) / 2));
  h_scales.resize(groups_total * N);
  h_zeros.resize(groups_total * N);
  h_ref_out_fp16.resize(M * N);

  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t k = 0; k < K; ++k) {
      float v = 1.0f + float((m + k) % 7);
      h_A[m * K + k] = float_to_fp16(v);
    }
  }

  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n_pair = 0; n_pair < ((N + 1) / 2); ++n_pair) {
      uint32_t n0 = n_pair * 2;
      uint32_t n1 = n0 + 1;
      int8_t w0 = int8_t(int((k * N + n0) % 7) - 3);
      int8_t w1 = 0;
      if (n1 < N) {
        w1 = int8_t(int((k * N + n1) % 7) - 3);
      }
      h_W_int4[k * ((N + 1) / 2) + n_pair] = pack_int4_pair(w0, w1);
    }
  }

  for (uint32_t kg = 0; kg < groups_total; ++kg) {
    for (uint32_t n = 0; n < N; ++n) {
      float scale = 1.0f + float(n % 7);
      int16_t zp = int16_t(int(n % 7) - 3);
      h_scales[kg * N + n] = float_to_fp16(scale);
      h_zeros[kg * N + n] = zp;
    }
  }

  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t n = 0; n < N; ++n) {
      float sum = 0.0f;
      for (uint32_t k = 0; k < K; ++k) {
        float a = fp16_to_float(h_A[m * K + k]);
        uint32_t group_id = k / QBLK;
        float scale = fp16_to_float(h_scales[group_id * N + n]);
        float zp = float(h_zeros[group_id * N + n]);

        uint32_t packed_idx = k * ((N + 1) / 2) + (n / 2);
        uint8_t packed = h_W_int4[packed_idx];
        int8_t w = unpack_int4_from_byte(packed, (n & 1) != 0);

        float dequant = (float(w) - zp) * scale;
        sum += a * dequant;
      }
      h_ref_out_fp16[m * N + n] = float_to_fp16(sum);
    }
  }
}

static bool compare_fp16(uint16_t actual, uint16_t expected, float tolerance) {
  float a = fp16_to_float(actual);
  float e = fp16_to_float(expected);

  float diff;
  if (e == 0.0f) {
    diff = std::abs(a);
  } else {
    diff = std::abs((a - e) / e);
  }
  return diff <= tolerance;
}

static int verify_results(vx_buffer_h out_buffer, const std::vector<uint16_t>& ref) {
  std::vector<uint16_t> got(ref.size());
  RT_CHECK(vx_copy_from_dev(got.data(), out_buffer, 0, ref.size() * sizeof(uint16_t)));

  int errors = 0;
  for (uint32_t i = 0; i < ref.size(); ++i) {
    if (!compare_fp16(got[i], ref[i], FP16_TOL)) {
      if (errors < 10) {
        printf("Mismatch[%u]: got=0x%04x (%f), exp=0x%04x (%f)\n",
               i,
               unsigned(got[i]), fp16_to_float(got[i]),
               unsigned(ref[i]), fp16_to_float(ref[i]));
      }
      ++errors;
    }
  }

  return errors;
}

static bool compute_lmem_layout(kernel_arg_t& kargs, uint64_t local_mem_size) {
  uint64_t groups_tile = (DMA_KT + uint64_t(QBLK) - 1ull) / uint64_t(QBLK);

  uint64_t lmem_ibuf_bytes  = DMA_MT * DMA_KT * 2ull;
  uint64_t lmem_wbuf_bytes  = DMA_KT * ((DMA_NT + 1ull) / 2ull);
  uint64_t lmem_scbuf_bytes = groups_tile * DMA_NT * 2ull;
  uint64_t lmem_zpbuf_bytes = groups_tile * DMA_NT * 2ull;
  uint64_t lmem_obuf_bytes  = DMA_MT * DMA_NT * 2ull;

  uint64_t cur = 0;

  kargs.lmem_ibuf0_base = cur;
  cur += align_up_u64(lmem_ibuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_ibuf1_base = cur;
  cur += align_up_u64(lmem_ibuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_wbuf0_base = cur;
  cur += align_up_u64(lmem_wbuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_wbuf1_base = cur;
  cur += align_up_u64(lmem_wbuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_scbuf0_base = cur;
  cur += align_up_u64(lmem_scbuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_scbuf1_base = cur;
  cur += align_up_u64(lmem_scbuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_zpbuf0_base = cur;
  cur += align_up_u64(lmem_zpbuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_zpbuf1_base = cur;
  cur += align_up_u64(lmem_zpbuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);

  kargs.lmem_obuf_base = cur;

  uint64_t total_needed = align_up_u64(cur + lmem_obuf_bytes, LMEM_LAYOUT_ALIGN_BYTES);
  return total_needed <= local_mem_size;
}

int main(int argc, char *argv[]) {
  parse_args(argc, argv);

  if (QBLK == 0) {
    std::cout << "QBLK must be > 0" << std::endl;
    return -1;
  }

  uint32_t groups_total = (K + QBLK - 1) / QBLK;

  std::cout << "TB-style GEMM MMIO test" << std::endl;
  std::cout << "M=" << M << ", N=" << N << ", K=" << K << ", QBLK=" << QBLK << std::endl;

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  uint64_t local_mem_size = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));
  std::cout << "Device: cores=" << num_cores
            << ", warps=" << num_warps
            << ", threads=" << num_threads << std::endl;
  std::cout << "Device: local_mem_size=" << local_mem_size << " bytes" << std::endl;

  std::vector<uint16_t> h_A;
  std::vector<uint8_t> h_W_int4;
  std::vector<uint16_t> h_scales;
  std::vector<int16_t> h_zeros;
  std::vector<uint16_t> h_ref_out_fp16;

  build_test_vectors(h_A, h_W_int4, h_scales, h_zeros, h_ref_out_fp16);

  RT_CHECK(vx_mem_alloc(device, h_A.size() * sizeof(uint16_t), VX_MEM_READ, &A_buffer));
  RT_CHECK(vx_mem_alloc(device, h_W_int4.size() * sizeof(uint8_t), VX_MEM_READ, &W_int4_buffer));
  RT_CHECK(vx_mem_alloc(device, h_scales.size() * sizeof(uint16_t), VX_MEM_READ, &scales_buffer));
  RT_CHECK(vx_mem_alloc(device, h_zeros.size() * sizeof(int16_t), VX_MEM_READ, &zeros_buffer));
  RT_CHECK(vx_mem_alloc(device, h_ref_out_fp16.size() * sizeof(uint16_t), VX_MEM_WRITE, &C_buffer));

  RT_CHECK(vx_copy_to_dev(A_buffer, h_A.data(), 0, h_A.size() * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(W_int4_buffer, h_W_int4.data(), 0, h_W_int4.size() * sizeof(uint8_t)));
  RT_CHECK(vx_copy_to_dev(scales_buffer, h_scales.data(), 0, h_scales.size() * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(zeros_buffer, h_zeros.data(), 0, h_zeros.size() * sizeof(int16_t)));

  std::vector<uint16_t> zero_out(h_ref_out_fp16.size(), 0);
  RT_CHECK(vx_copy_to_dev(C_buffer, zero_out.data(), 0, zero_out.size() * sizeof(uint16_t)));

  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  kernel_arg_t kargs = {};
  kargs.grid_dim[0] = static_cast<uint32_t>(num_cores);
  kargs.grid_dim[1] = 1;
  kargs.block_dim[0] = 1;
  kargs.block_dim[1] = 1;

  kargs.M = M;
  kargs.N = N;
  kargs.K = K;
  kargs.QBLK = QBLK;

  RT_CHECK(vx_mem_address(A_buffer, &kargs.input_base));
  RT_CHECK(vx_mem_address(W_int4_buffer, &kargs.weight_base));
  RT_CHECK(vx_mem_address(scales_buffer, &kargs.scale_base));
  RT_CHECK(vx_mem_address(zeros_buffer, &kargs.zp_base));
  RT_CHECK(vx_mem_address(C_buffer, &kargs.output_base));

  if (!compute_lmem_layout(kargs, local_mem_size)) {
    std::cerr << "LMEM layout does not fit device local memory (size=" << local_mem_size << ")" << std::endl;
    cleanup();
    return -1;
  }

  kargs.status = MMIO_STATUS_INIT;
  kargs.job_eid = 0;
  kargs.job_generation = 0;
  kargs.last_ctrl = 0;

  RT_CHECK(vx_upload_bytes(device, &kargs, sizeof(kargs), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  {
    int wait_ret = vx_ready_wait(device, HOST_WAIT_TIMEOUT_MS);
    if (wait_ret != 0) {
      std::cerr << "vx_ready_wait timeout/error: ret=" << wait_ret << std::endl;

      int arg_ret = vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs));
      if (arg_ret == 0) {
        std::cerr << "Kernel status after wait failure: status=" << kargs.status
                  << " (" << status_to_str(kargs.status) << ")"
                  << ", eid=" << kargs.job_eid
                  << ", gen=" << kargs.job_generation
                  << ", ctrl=0x" << std::hex << kargs.last_ctrl << std::dec
                  << std::endl;
      } else {
        std::cerr << "Failed to read args buffer after wait failure, ret=" << arg_ret << std::endl;
      }

      cleanup();
      return -1;
    }
  }

  RT_CHECK(vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs)));

  if (kargs.status != MMIO_STATUS_OK) {
    std::cout << "MMIO kernel failed: status=" << kargs.status
              << " (" << status_to_str(kargs.status) << ")"
              << ", eid=" << kargs.job_eid
              << ", gen=" << kargs.job_generation
              << ", ctrl=0x" << std::hex << kargs.last_ctrl << std::dec
              << std::endl;
    cleanup();
    return -1;
  }

  int errors = verify_results(C_buffer, h_ref_out_fp16);

  cleanup();

  if (errors != 0) {
    std::cout << "FAILED: errors=" << errors << std::endl;
    return -1;
  }

  std::cout << "PASSED" << std::endl;
  return 0;
}
