#include "common.h"
#include <VX_config.h>
#include <vx_spawn.h>
#include "../vector_common/fp16.h"
#include "../softmax_common/warp_reduce_full.h"

#ifndef LMEM_ENABLE
#error "lmem_reduction_raw requires local memory"
#endif

// One asm block keeps store/load adjacent. The data dependency forces the
// following accumulation to consume the load, rather than a forwarded C++ value.
#define RAW_ASM_GAP "nop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\t"

template <bool Fence, bool Gap>
static inline float roundtrip(float value, float* address, float* read_address = nullptr) {
  if (!read_address) read_address = address;
  float loaded;
  if (Fence && Gap)
    asm volatile("fsw %1, 0(%2)\n\tfence iorw, iorw\n\t" RAW_ASM_GAP "flw %0, 0(%3)"
        : "=f"(loaded) : "f"(value), "r"(address), "r"(read_address) : "memory");
  else if (Fence)
    asm volatile("fsw %1, 0(%2)\n\tfence iorw, iorw\n\tflw %0, 0(%3)"
        : "=f"(loaded) : "f"(value), "r"(address), "r"(read_address) : "memory");
  else if (Gap)
    asm volatile("fsw %1, 0(%2)\n\t" RAW_ASM_GAP "flw %0, 0(%3)"
        : "=f"(loaded) : "f"(value), "r"(address), "r"(read_address) : "memory");
  else
    asm volatile("fsw %1, 0(%2)\n\tflw %0, 0(%3)"
        : "=f"(loaded) : "f"(value), "r"(address), "r"(read_address) : "memory");
  return loaded;
}

template <bool Fence, bool Gap>
static inline uint32_t roundtrip(uint32_t value, uint32_t* address) {
  uint32_t loaded;
  if (Fence && Gap)
    asm volatile("sw %1, 0(%2)\n\tfence iorw, iorw\n\t" RAW_ASM_GAP "lw %0, 0(%2)"
        : "=r"(loaded) : "r"(value), "r"(address) : "memory");
  else if (Fence)
    asm volatile("sw %1, 0(%2)\n\tfence iorw, iorw\n\tlw %0, 0(%2)"
        : "=r"(loaded) : "r"(value), "r"(address) : "memory");
  else if (Gap)
    asm volatile("sw %1, 0(%2)\n\t" RAW_ASM_GAP "lw %0, 0(%2)"
        : "=r"(loaded) : "r"(value), "r"(address) : "memory");
  else
    asm volatile("sw %1, 0(%2)\n\tlw %0, 0(%2)"
        : "=r"(loaded) : "r"(value), "r"(address) : "memory");
  return loaded;
}

template <raw_mode_t Mode, bool Fence, bool Gap>
static void body(kernel_arg_t* __UNIFORM__ arg) {
  const uint32_t lane = threadIdx.x;
  const uint32_t width = blockDim.x;
  const uint32_t iterations = arg->iterations;
  const uint32_t count = active_lanes(blockIdx.x, NUM_THREADS, arg->active);
  // Reserve one disjoint scratch range per simultaneously resident workgroup.
  const uint32_t local_bytes = LMEM_SIZE / (NUM_WARPS / arg->warps);
  auto scratch = reinterpret_cast<volatile float*>(__local_mem(local_bytes));
  float* slot = const_cast<float*>(scratch + lane * arg->stride);
  float result = 0.0f;
  if (Mode == RAW_EXCHANGE) {
    // Admission-order diagnostic: full-warp store immediately followed by a
    // peer load, without the runtime barrier instructions hiding bank backlog.
    // Without a fence this intentionally tests the warp-ordering assumption;
    // it is not a portable inter-thread synchronization primitive.
    float* peer_slot = const_cast<float*>(scratch + (lane ^ (width / 2)) * arg->stride);
    for (uint32_t i = 0; i < iterations; ++i)
      result += roundtrip<Fence, Gap>(float(lane + 1 + i), slot, peer_slot);
  } else if (Mode == RAW_PEER) {
    // lane 0 reads a producer in the other hierarchical-arbiter slice.
    // stride=32 on TH16/XLEN64 puts every float in bank zero, at distinct words.
    const uint32_t peer = lane ^ (width / 2);
    for (uint32_t i = 0; i < iterations; ++i) {
      scratch[lane * arg->stride] = float(lane + 1 + (i & 1u));
      if (Fence) vx_fence();
      __syncthreads();
      if (Gap) asm volatile(RAW_ASM_GAP ::: "memory");
      result += scratch[peer * arg->stride];
      // Prevent reuse across rounds at the intended workgroup boundary.
      if (Fence) vx_fence();
      __syncthreads();
    }
  } else if (Mode == RAW_TREE) {
    // An in-place LMEM butterfly, mirroring Hadamard's cross-lane scratch use.
    // Each stage has read/read -> add -> write and a workgroup boundary.
    for (uint32_t i = 0; i < iterations; ++i) {
      scratch[lane * arg->stride] = float(lane + 1 + (i & 1u));
      if (Fence) vx_fence();
      __syncthreads();
      for (uint32_t offset = 1; offset < width; offset <<= 1) {
        const float own = scratch[lane * arg->stride];
        const float other = scratch[(lane ^ offset) * arg->stride];
        if (Fence) vx_fence();
        __syncthreads();
        if (Gap) asm volatile(RAW_ASM_GAP ::: "memory");
        scratch[lane * arg->stride] = own + other;
        if (Fence) vx_fence();
        __syncthreads();
      }
      result += scratch[lane * arg->stride];
      if (Fence) vx_fence();
      __syncthreads();
    }
  } else if (Mode == RAW_WARP || Mode == RAW_LMEM_WARP) {
    // All lanes participate in SHFL, including the inactive causal tail.
    for (uint32_t i = 0; i < iterations; ++i) {
      float value = lane < count ? float(lane + 1 + (i & 1u)) : 0.0f;
      if (Mode == RAW_LMEM_WARP) value = roundtrip<Fence, Gap>(value, slot);
      result += softmax_warp_sum_full(value);
    }
  } else if (lane < count) {
    if (Mode == RAW_INT) {
      uint32_t sum = 0;
      for (uint32_t i = 0; i < iterations; ++i)
        sum = roundtrip<Fence, Gap>(sum, reinterpret_cast<uint32_t*>(slot)) + lane + 1;
      result = float(sum);
    } else {
      for (uint32_t i = 0; i < iterations; ++i) {
        float delta = float(lane + 1);
        if (Mode == RAW_FP16) {
          // Actual H2S conversion under a partial warp mask, immediately before
          // the LMEM recurrence. Lane-specific exact dyadic inputs detect a
          // swapped conversion lane without introducing rounding ambiguity.
          const uint32_t offset = lane & 15u;
          delta = fp16_to_float((i & 1u)
              ? fp16_t(0x3c00 + offset * 32u)
              : fp16_t(0x3800 + offset * 64u));
        }
        result = roundtrip<Fence, Gap>(result, slot) + delta;
      }
    }
  }
  // No diagnostic stores, comparisons, or printf within the measured loop.
  reinterpret_cast<float*>(arg->output_addr)[blockIdx.x * width + lane] = result;
}

template <raw_mode_t Mode>
static void dispatch(kernel_arg_t* __UNIFORM__ arg) {
  if (arg->fence) {
    if (arg->gap) body<Mode, true, true>(arg);
    else body<Mode, true, false>(arg);
  } else {
    if (arg->gap) body<Mode, false, true>(arg);
    else body<Mode, false, false>(arg);
  }
}

static void kernel_body(kernel_arg_t* __UNIFORM__ arg) {
  switch (arg->mode) {
    case RAW_INT: dispatch<RAW_INT>(arg); break;
    case RAW_FP32: dispatch<RAW_FP32>(arg); break;
    case RAW_FP16: dispatch<RAW_FP16>(arg); break;
    case RAW_WARP: dispatch<RAW_WARP>(arg); break;
    case RAW_LMEM_WARP: dispatch<RAW_LMEM_WARP>(arg); break;
    case RAW_PEER: dispatch<RAW_PEER>(arg); break;
    case RAW_TREE: dispatch<RAW_TREE>(arg); break;
    case RAW_EXCHANGE: dispatch<RAW_EXCHANGE>(arg); break;
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  uint32_t grid[] = {arg->groups, 1, 1};
  uint32_t block[] = {NUM_THREADS * arg->warps, 1, 1};
  return vx_spawn_threads(1, grid, block,
      reinterpret_cast<vx_kernel_func_cb>(kernel_body), arg);
}
