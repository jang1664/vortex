#include "common.h"
#include <vx_spawn.h>
#include <vx_tensor.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<NUM_THREADS, vt::ITYPE, vt::OTYPE>;

// Type aliases
using input_t = ctx::input_t;    // fp16
using output_t = ctx::output_t;  // fp32 or fp16

// FP16 infinity constant
#define FP16_INFINITY 0x7C00

///////////////////////////////////////////////////////////////////////////////
// KERNEL 0: Dequantization (int4 -> fp16)
///////////////////////////////////////////////////////////////////////////////

// Helper: unpack int4 from byte (same as CPU version)
inline void unpack_int4(uint8_t packed, int8_t& v0, int8_t& v1) {
  v0 = (packed & 0x0F);
  v1 = (packed >> 4) & 0x0F;
  // Sign extend from 4-bit
  if (v0 & 0x08) v0 |= 0xF0;
  if (v1 & 0x08) v1 |= 0xF0;
}

// Helper: convert int8 to fp16
inline input_t int8_to_fp16(int8_t val) {
  float f = static_cast<float>(val);
  // Simple fp32 to fp16 conversion (assuming input_t is uint16_t)
  union { float f; uint32_t i; } u = {f};
  uint32_t sign = (u.i >> 16) & 0x8000;
  int32_t exp = ((u.i >> 23) & 0xFF) - 127 + 15;
  uint32_t mantissa = (u.i >> 13) & 0x3FF;
  
  if (exp <= 0) return sign;
  if (exp >= 31) return sign | 0x7C00;
  
  return sign | (exp << 10) | mantissa;
}

// Helper: convert fp16 to float
inline float fp16_to_float(input_t h) {
  uint32_t sign = (h >> 15) & 0x1;
  uint32_t exp = (h >> 10) & 0x1F;
  uint32_t mantissa = h & 0x3FF;
  
  if (exp == 0) {
    if (mantissa == 0) return sign ? -0.0f : 0.0f;
    float val = mantissa / 1024.0f;
    return sign ? -val / 16384.0f : val / 16384.0f;
  }
  if (exp == 31) {
    // Return a large value instead of INFINITY for device compatibility
    return sign ? -65504.0f : 65504.0f;  // Max fp16 value
  }
  
  uint32_t f = (sign << 31) | ((exp - 15 + 127) << 23) | (mantissa << 13);
  float result;
  __builtin_memcpy(&result, &f, sizeof(float));
  return result;
}

// Helper: convert float to fp16
inline input_t float_to_fp16(float f) {
  uint32_t i;
  __builtin_memcpy(&i, &f, sizeof(float));
  uint32_t sign = (i >> 16) & 0x8000;
  int32_t exp = ((i >> 23) & 0xFF) - 127 + 15;
  uint32_t mantissa = (i >> 13) & 0x3FF;
  
  if (exp <= 0) return sign;
  if (exp >= 31) return sign | 0x7C00;
  
  return sign | (exp << 10) | mantissa;
}

void kernel_dequant(kernel_arg_t *__UNIFORM__ arg) {
  auto pW_int4 = reinterpret_cast<uint8_t *>(arg->W_int4_addr);   // packed int4
  auto pW_fp16 = reinterpret_cast<input_t *>(arg->W_fp16_addr);   // output fp16
  auto pScales = reinterpret_cast<input_t *>(arg->scales_addr);
  auto pZeros = reinterpret_cast<input_t *>(arg->zeros_addr);
  
  uint32_t K = arg->K;
  uint32_t N = arg->N;
  uint32_t group_size = arg->group_size;
  
  // Parallelize over K*N elements
  // Each thread processes multiple elements
  uint32_t total_threads = gridDim.x * gridDim.y * blockDim.x * blockDim.y;
  uint32_t thread_id = (blockIdx.y * gridDim.x + blockIdx.x) * (blockDim.x * blockDim.y) +
                       (threadIdx.y * blockDim.x + threadIdx.x);
  
  uint32_t total_elements = K * N;
  
  for (uint32_t elem_idx = thread_id; elem_idx < total_elements; elem_idx += total_threads) {
    uint32_t k = elem_idx / N;
    uint32_t n = elem_idx % N;
    
    // Get group for this k
    uint32_t group_id = k / group_size;
    
    // Load scale and zero for this group and column
    input_t scale_fp16 = pScales[group_id * N + n];
    input_t zero_fp16 = pZeros[group_id * N + n];
    
    // Load packed int4
    uint32_t packed_idx = elem_idx / 2;
    uint8_t packed = pW_int4[packed_idx];
    
    // Unpack
    int8_t v0, v1;
    unpack_int4(packed, v0, v1);
    int8_t int4_val = (elem_idx % 2 == 0) ? v0 : v1;
    
    // Dequantize: w_fp16 = (w_int4 - zero) * scale
    // Convert to float for arithmetic
    float scale = fp16_to_float(scale_fp16);
    float zero = fp16_to_float(zero_fp16);
    float dequant_val = (static_cast<float>(int4_val) - zero) * scale;
    
    // Convert back to fp16
    input_t val_fp16 = float_to_fp16(dequant_val);
    
    // Store result
    pW_fp16[elem_idx] = val_fp16;
  }
}

///////////////////////////////////////////////////////////////////////////////
// KERNEL 1: Standard GEMM (fp16 x fp16)
///////////////////////////////////////////////////////////////////////////////
void kernel_gemm(kernel_arg_t *__UNIFORM__ arg) {
  auto pA = reinterpret_cast<input_t *>(arg->A_addr);
  auto pB = reinterpret_cast<input_t *>(arg->B_addr);  // already dequantized
  auto pC = reinterpret_cast<output_t *>(arg->C_addr);

  uint32_t M = arg->M;
  uint32_t N = arg->N;
  uint32_t K = arg->K;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;

  // Calculate tile position
  uint32_t tile_row = blockIdx.y * ctx::tileM;
  uint32_t tile_col = blockIdx.x * ctx::tileN;

  // Initialize accumulator to zero
  ctx::fill_fragment(fragC, 0);

  // GEMM loop over K dimension
  for (uint32_t i = 0; i < K; i += ctx::tileK) {
    // Load A tile (activations)
    auto pTileA = pA + tile_row * K + i;
    ctx::load_matrix_sync(fragA, pTileA, K);

    // Load B tile (weights)
    if constexpr (vt::ITYPE::bits < 8) {
      // Sub-byte types need col-major
      auto pTileB = pB + tile_col * K + i;
      ctx::load_matrix_sync<vt::col_major>(fragB, pTileB, K);
    } else {
      auto pTileB = pB + i * N + tile_col;
      ctx::load_matrix_sync(fragB, pTileB, N);
    }

    // Matrix multiply-accumulate
    ctx::mma_sync(fragC, fragA, fragB, fragC);
  }

  // Store result
  auto pTileC = pC + tile_row * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);
}

///////////////////////////////////////////////////////////////////////////////
// KERNEL 2: Fused Dequant + GEMM
///////////////////////////////////////////////////////////////////////////////
void kernel_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto pA = reinterpret_cast<input_t *>(arg->A_addr);
  auto pW_int4 = reinterpret_cast<uint8_t *>(arg->W_int4_addr);   // packed int4
  auto pScales = reinterpret_cast<input_t *>(arg->scales_addr);
  auto pZeros = reinterpret_cast<input_t *>(arg->zeros_addr);
  auto pC = reinterpret_cast<output_t *>(arg->C_addr);

  uint32_t M = arg->M;
  uint32_t N = arg->N;
  uint32_t K = arg->K;
  uint32_t group_size = arg->group_size;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;

  // Calculate tile position
  uint32_t tile_row = blockIdx.y * ctx::tileM;
  uint32_t tile_col = blockIdx.x * ctx::tileN;

  // Initialize accumulator to zero
  ctx::fill_fragment(fragC, 0);

  // Temporary buffer for dequantized weights
  input_t temp_weights[ctx::tileK * ctx::tileN];

  // GEMM loop with on-the-fly dequantization
  for (uint32_t k_tile = 0; k_tile < K; k_tile += ctx::tileK) {
    // Load A tile (activations)
    auto pTileA = pA + tile_row * K + k_tile;
    ctx::load_matrix_sync(fragA, pTileA, K);

    // On-the-fly dequantization for B tile
    // 1. Load and dequantize int4 weights for this tile
    for (uint32_t k = 0; k < ctx::tileK && (k_tile + k) < K; ++k) {
      uint32_t group_id = (k_tile + k) / group_size;
      
      for (uint32_t n = 0; n < ctx::tileN && (tile_col + n) < N; ++n) {
        // Get scale and zero for this position
        input_t scale_fp16 = pScales[group_id * N + (tile_col + n)];
        input_t zero_fp16 = pZeros[group_id * N + (tile_col + n)];
        
        // Load packed int4
        uint32_t global_idx = (k_tile + k) * N + (tile_col + n);
        uint32_t packed_idx = global_idx / 2;
        uint8_t packed = pW_int4[packed_idx];
        
        // Unpack
        int8_t v0, v1;
        unpack_int4(packed, v0, v1);
        int8_t int4_val = (global_idx % 2 == 0) ? v0 : v1;
        
        // Dequantize and store in temp buffer
        float scale = fp16_to_float(scale_fp16);
        float zero = fp16_to_float(zero_fp16);
        float dequant_val = (static_cast<float>(int4_val) - zero) * scale;
        input_t val_fp16 = float_to_fp16(dequant_val);
        temp_weights[k * ctx::tileN + n] = val_fp16;
      }
    }
    
    // 2. Load from temp buffer into fragB using proper layout
    if constexpr (vt::ITYPE::bits < 8) {
      // Sub-byte: col-major
      ctx::load_matrix_sync<vt::col_major>(fragB, temp_weights, ctx::tileK);
    } else {
      // Row-major for this temp buffer (stored as K x N within tile)
      ctx::load_matrix_sync(fragB, temp_weights, ctx::tileN);
    }

    // Matrix multiply-accumulate
    ctx::mma_sync(fragC, fragA, fragB, fragC);
  }

  // Store result
  auto pTileC = pC + tile_row * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_DEQUANT:
      kernel_dequant(arg);
      break;
    case KERNEL_GEMM:
      kernel_gemm(arg);
      break;
    case KERNEL_FUSED:
      kernel_fused(arg);
      break;
    default:
      break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(2, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher, arg);
} 