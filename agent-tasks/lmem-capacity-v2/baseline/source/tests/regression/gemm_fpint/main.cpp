#include <iostream>
#include <unistd.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <vortex.h>
#include "common.h"
#include <tensor_cfg.h>

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
     cleanup();                                                 \
     exit(-1);                                                  \
   } while (false)

///////////////////////////////////////////////////////////////////////////////
// Configuration
///////////////////////////////////////////////////////////////////////////////
namespace vt = vortex::tensor;
using cfg = vt::wmma_config_t<NUM_THREADS, vt::ITYPE, vt::OTYPE>;
using itype_t = typename vt::ITYPE::dtype;
using otype_t = typename vt::OTYPE::dtype;

const char* kernel_file = "kernel.vxbin";
uint32_t M = 32;
uint32_t N = 32;
uint32_t K = 64;
uint32_t group_size = 32;  // Quantization group size

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;

// Buffers for different kernels
vx_buffer_h A_buffer = nullptr;       // Activations (fp16)
vx_buffer_h W_int4_buffer = nullptr;  // Quantized weights (int4, packed)
vx_buffer_h W_fp16_buffer = nullptr;  // Dequantized weights (fp16)
vx_buffer_h scales_buffer = nullptr;  // Scales (fp16)
vx_buffer_h zeros_buffer = nullptr;   // Zero points (fp16)
vx_buffer_h C_buffer = nullptr;       // Output

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////

static void cleanup() {
  if (A_buffer) vx_mem_free(A_buffer);
  if (W_int4_buffer) vx_mem_free(W_int4_buffer);
  if (W_fp16_buffer) vx_mem_free(W_fp16_buffer);
  if (scales_buffer) vx_mem_free(scales_buffer);
  if (zeros_buffer) vx_mem_free(zeros_buffer);
  if (C_buffer) vx_mem_free(C_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void show_usage() {
  std::cout << "Usage: [-m M] [-n N] [-k K] [-g group_size] [-h]" << std::endl;
}

static void parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "m:n:k:g:h")) != -1) {
    switch (c) {
    case 'm': M = atoi(optarg); break;
    case 'n': N = atoi(optarg); break;
    case 'k': K = atoi(optarg); break;
    case 'g': group_size = atoi(optarg); break;
    case 'h': show_usage(); exit(0); break;
    default: show_usage(); exit(-1);
    }
  }
}

// FP16 conversion helpers
static uint16_t float_to_fp16(float f) {
  union { float f; uint32_t i; } u = {f};
  uint32_t sign = (u.i >> 16) & 0x8000;
  int32_t exp = ((u.i >> 23) & 0xFF) - 127 + 15;
  uint32_t mantissa = (u.i >> 13) & 0x3FF;
  
  if (exp <= 0) return sign;  // underflow
  if (exp >= 31) return sign | 0x7C00;  // overflow to inf
  
  return sign | (exp << 10) | mantissa;
}

static float fp16_to_float(uint16_t h) {
  uint32_t sign = (h >> 15) & 0x1;
  uint32_t exp = (h >> 10) & 0x1F;
  uint32_t mantissa = h & 0x3FF;
  
  if (exp == 0) {
    if (mantissa == 0) return sign ? -0.0f : 0.0f;
    // Denormal
    float val = mantissa / 1024.0f;
    return sign ? -val / 16384.0f : val / 16384.0f;
  }
  if (exp == 31) return sign ? -INFINITY : INFINITY;
  
  uint32_t f = (sign << 31) | ((exp - 15 + 127) << 23) | (mantissa << 13);
  return *reinterpret_cast<float*>(&f);
}

// Pack two int4 values into one byte
static uint8_t pack_int4(int8_t v0, int8_t v1) {
  return ((v1 & 0x0F) << 4) | (v0 & 0x0F);
}

// Unpack int4 from byte
static void unpack_int4(uint8_t packed, int8_t& v0, int8_t& v1) {
  v0 = (packed & 0x0F);
  v1 = (packed >> 4) & 0x0F;
  // Sign extend from 4-bit
  if (v0 & 0x08) v0 |= 0xF0;
  if (v1 & 0x08) v1 |= 0xF0;
}

// Simple quantization: map float value to int4 [0, 15]
static int8_t quantize_to_int4(float val, float scale, float zero) {
  int q = static_cast<int>(val / scale + zero);
  return std::max(0, std::min(15, q));
}

///////////////////////////////////////////////////////////////////////////////
// Initialize test data
///////////////////////////////////////////////////////////////////////////////

static void init_test_data(std::vector<uint16_t>& h_A,
                           std::vector<uint8_t>& h_W_int4,
                           std::vector<uint16_t>& h_scales,
                           std::vector<uint16_t>& h_zeros) {
  uint32_t num_groups = K / group_size;
  
  h_A.resize(M * K);
  h_W_int4.resize((K * N + 1) / 2);
  h_scales.resize(num_groups * N);
  h_zeros.resize(num_groups * N);
  
  // Activations: random fp16 values
  for (uint32_t i = 0; i < M * K; ++i) {
    float val = static_cast<float>(rand()) / RAND_MAX - 0.5f;
    h_A[i] = float_to_fp16(val);
  }
  
  // Generate random fp16 weights first
  std::vector<float> h_W_float(K * N);
  for (uint32_t i = 0; i < K * N; ++i) {
    h_W_float[i] = static_cast<float>(rand()) / RAND_MAX - 0.5f;
  }
  
  // Quantization: compute scales and zeros per group
  for (uint32_t g = 0; g < num_groups; ++g) {
    for (uint32_t col = 0; col < N; ++col) {
      // Find min/max in this group
      float min_val = 1e10f, max_val = -1e10f;
      for (uint32_t k = g * group_size; k < (g + 1) * group_size; ++k) {
        float val = h_W_float[k * N + col];
        min_val = std::min(min_val, val);
        max_val = std::max(max_val, val);
      }
      
      // Compute scale and zero (unsigned int4: 0-15)
      float scale = (max_val - min_val) / 15.0f;
      if (scale < 1e-6f) scale = 1e-6f;  // avoid division by zero
      float zero = -min_val / scale;
      h_scales[g * N + col] = float_to_fp16(scale);
      h_zeros[g * N + col] = float_to_fp16(zero);
      
      // Quantize this group
      for (uint32_t k = g * group_size; k < (g + 1) * group_size; k += 2) {
        float v0 = h_W_float[k * N + col];
        float v1 = h_W_float[(k + 1) * N + col];
        int8_t q0 = quantize_to_int4(v0, scale, zero);
        int8_t q1 = quantize_to_int4(v1, scale, zero);
        
        // Pack two int4 into one byte
        uint32_t idx = (k * N + col) / 2;
        h_W_int4[idx] = pack_int4(q0, q1);
      }
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
///////////////////////////////////////////////////////////////////////////////

static void cpu_dequantize(std::vector<float>& W_fp16, 
                           const std::vector<uint8_t>& W_int4,
                           const std::vector<uint16_t>& scales,
                           const std::vector<uint16_t>& zeros,
                           uint32_t K, uint32_t N, uint32_t group_size) {
  uint32_t num_groups = K / group_size;
  W_fp16.resize(K * N);
  
  for (uint32_t k = 0; k < K; ++k) {
    uint32_t group_id = k / group_size;
    for (uint32_t n = 0; n < N; ++n) {
      // Get packed value
      uint32_t idx = (k * N + n) / 2;
      uint8_t packed = W_int4[idx];
      
      // Unpack
      int8_t v0, v1;
      unpack_int4(packed, v0, v1);
      int8_t val = ((k * N + n) % 2 == 0) ? v0 : v1;
      
      // Dequantize
      float scale = fp16_to_float(scales[group_id * N + n]);
      float zero = fp16_to_float(zeros[group_id * N + n]);
      W_fp16[k * N + n] = (val - zero) * scale;
    }
  }
}

static void cpu_matmul(std::vector<float>& C,
                       const std::vector<uint16_t>& A_fp16,
                       const std::vector<float>& B,
                       uint32_t M, uint32_t N, uint32_t K) {
  C.resize(M * N, 0.0f);
  
  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t n = 0; n < N; ++n) {
      float sum = 0.0f;
      for (uint32_t k = 0; k < K; ++k) {
        float a = fp16_to_float(A_fp16[m * K + k]);
        float b = B[k * N + n];
        sum += a * b;
      }
      C[m * N + n] = sum;
    }
  }
}

static int verify_results(vx_buffer_h C_buffer, 
                          const std::vector<float>& C_ref,
                          uint32_t M, uint32_t N,
                          const char* kernel_name) {
  // Copy results from device
  std::vector<float> C_gpu(M * N);
  RT_CHECK(vx_copy_from_dev(C_gpu.data(), C_buffer, 0, M * N * sizeof(float)));
  
  // Compare
  int errors = 0;
  float max_diff = 0.0f;
  for (uint32_t i = 0; i < M * N; ++i) {
    float diff = std::abs(C_gpu[i] - C_ref[i]);
    max_diff = std::max(max_diff, diff);
    
    // Relative error tolerance for fp16
    float threshold = std::max(0.01f, std::abs(C_ref[i]) * 0.05f);
    if (diff > threshold) {
      if (errors < 10) {
        printf("  Error [%d]: expected=%.6f, got=%.6f, diff=%.6f\n", 
               i, C_ref[i], C_gpu[i], diff);
      }
      errors++;
    }
  }
  
  printf("  %s: errors=%d/%d, max_diff=%.6f\n", 
         kernel_name, errors, M * N, max_diff);
  return errors;
}

///////////////////////////////////////////////////////////////////////////////
// Run kernels
///////////////////////////////////////////////////////////////////////////////

static void run_kernel(uint32_t kernel_id, kernel_arg_t& kargs) {
  kargs.kernel_id = kernel_id;
  
  // Free old args_buffer if exists
  if (args_buffer) {
    vx_mem_free(args_buffer);
    args_buffer = nullptr;
  }
  
  // Upload new args
  RT_CHECK(vx_upload_bytes(device, &kargs, sizeof(kargs), &args_buffer));
  
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  
  // Print cumulative performance statistics after this kernel
  printf("\n[KERNEL_%d Performance]\n", kernel_id);
  vx_dump_perf(device, stdout);
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////

int main(int argc, char *argv[]) {
  parse_args(argc, argv);
  
  printf("Matrix dimensions: M=%d, N=%d, K=%d\n", M, N, K);
  printf("Quantization group size: %d\n", group_size);
  printf("Using kernel: %s\n", kernel_file);
  
  // Open device
  RT_CHECK(vx_dev_open(&device));
  
  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  
  printf("Device: cores=%ld, warps=%ld, threads=%ld\n", 
         num_cores, num_warps, num_threads);
  
  // Allocate buffers
  uint32_t num_groups = K / group_size;
  
  printf("Initializing test data...\n");
  std::vector<uint16_t> h_A;
  std::vector<uint8_t> h_W_int4;
  std::vector<uint16_t> h_scales;
  std::vector<uint16_t> h_zeros;
  init_test_data(h_A, h_W_int4, h_scales, h_zeros);
  
  RT_CHECK(vx_mem_alloc(device, M * K * sizeof(uint16_t), VX_MEM_READ, &A_buffer));
  RT_CHECK(vx_mem_alloc(device, (K * N + 1) / 2, VX_MEM_READ, &W_int4_buffer));
  RT_CHECK(vx_mem_alloc(device, K * N * sizeof(uint16_t), VX_MEM_READ | VX_MEM_WRITE, &W_fp16_buffer));
  RT_CHECK(vx_mem_alloc(device, num_groups * N * sizeof(uint16_t), VX_MEM_READ, &scales_buffer));
  RT_CHECK(vx_mem_alloc(device, num_groups * N * sizeof(uint16_t), VX_MEM_READ, &zeros_buffer));
  RT_CHECK(vx_mem_alloc(device, M * N * sizeof(float), VX_MEM_WRITE, &C_buffer));
  
  // Upload data to device
  printf("Uploading data to device...\n");
  RT_CHECK(vx_copy_to_dev(A_buffer, h_A.data(), 0, M * K * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(W_int4_buffer, h_W_int4.data(), 0, (K * N + 1) / 2));
  RT_CHECK(vx_copy_to_dev(scales_buffer, h_scales.data(), 0, num_groups * N * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(zeros_buffer, h_zeros.data(), 0, num_groups * N * sizeof(uint16_t)));
  
  // Upload kernel
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));
  
  // Prepare kernel arguments
  kernel_arg_t kargs = {};
  kargs.M = M;
  kargs.N = N;
  kargs.K = K;
  kargs.group_size = group_size;
  
  RT_CHECK(vx_mem_address(A_buffer, &kargs.A_addr));
  RT_CHECK(vx_mem_address(W_int4_buffer, &kargs.W_int4_addr));
  RT_CHECK(vx_mem_address(W_fp16_buffer, &kargs.W_fp16_addr));
  kargs.B_addr = kargs.W_fp16_addr;  // alias
  RT_CHECK(vx_mem_address(scales_buffer, &kargs.scales_addr));
  RT_CHECK(vx_mem_address(zeros_buffer, &kargs.zeros_addr));
  RT_CHECK(vx_mem_address(C_buffer, &kargs.C_addr));
  
  
  kargs.grid_dim[0] = (N + cfg::tileN - 1) / cfg::tileN;
  kargs.grid_dim[1] = (M + cfg::tileM - 1) / cfg::tileM;
  kargs.block_dim[0] = NUM_THREADS;  // warp size
  kargs.block_dim[1] = 1;
  
  // Compute CPU reference
  printf("\nComputing CPU reference...\n");
  std::vector<float> W_fp16_cpu;
  cpu_dequantize(W_fp16_cpu, h_W_int4, h_scales, h_zeros, K, N, group_size);
  
  std::vector<float> C_ref;
  cpu_matmul(C_ref, h_A, W_fp16_cpu, M, N, K);
  printf("CPU reference computed.\n");
  
  printf("\n=== Running Kernels ===\n");
  printf("Grid: [%d, %d], Block: [%d, %d]\n", 
         kargs.grid_dim[0], kargs.grid_dim[1],
         kargs.block_dim[0], kargs.block_dim[1]);
  printf("Tiles: tileM=%d, tileN=%d, tileK=%d\n",
         cfg::tileM, cfg::tileN, cfg::tileK);
  
  int total_errors = 0;
  
  // Kernel 0: Dequantization only
  printf("\n[KERNEL 0: Dequantization]\n");
  run_kernel(KERNEL_DEQUANT, kargs);
  
  // Kernel 1: Standard GEMM (using pre-dequantized weights)
  printf("\n[KERNEL 1: Standard GEMM]\n");
  run_kernel(KERNEL_GEMM, kargs);
  total_errors += verify_results(C_buffer, C_ref, M, N, "GEMM");

  // Kernel 2: Fused Dequant + GEMM
  
  
  printf("\n=== Performance Summary ===\n");
  
  cleanup();
  
  if (total_errors != 0) {
    printf("\nFAILED! - %d total errors\n", total_errors);
    return -1;
  }
  
  printf("\nPASSED!\n");
  return 0;
}