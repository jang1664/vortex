// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// The intrinsics implemented use RISC-V assembler pseudo-directives defined here:
// https://sourceware.org/binutils/docs/as/RISC_002dV_002dFormats.html

#ifndef __VX_INTRINSICS_H__
#define __VX_INTRINSICS_H__

#include <stddef.h>
#include <stdint.h>
#include <VX_types.h>

#if defined(__clang__)
#define __UNIFORM__   __attribute__((annotate("vortex.uniform")))
#else
#define __UNIFORM__
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define RISCV_CUSTOM0   0x0B
#define RISCV_CUSTOM1   0x2B
#define RISCV_CUSTOM2   0x5B
#define RISCV_CUSTOM3   0x7B

inline __attribute__((always_inline)) float vx_expf_hw(float x) {
    float ret;
    __asm__ volatile (".insn r %1, 0, 3, %0, %2, x0"
                      : "=f"(ret)
                      : "i"(RISCV_CUSTOM0), "f"(x));
    return ret;
}

#ifdef EXT_ADDR_GEN_ENABLE
// CUSTOM0 affine address-generator instructions. Stream and dimension must be
// compile-time constants because they occupy funct7 and funct3 respectively.
#define VX_ADDRGEN_STREAM_LD0 0
#define VX_ADDRGEN_STREAM_LD1 1
#define VX_ADDRGEN_STREAM_ST  2

#ifdef __cplusplus
#define __VX_ADDRGEN_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#define __VX_ADDRGEN_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif

#define __VX_ADDRGEN_CHECK_STREAM(stream)                                  \
    __VX_ADDRGEN_STATIC_ASSERT(__builtin_constant_p(stream),               \
                               "address-generator stream must be constant"); \
    __VX_ADDRGEN_STATIC_ASSERT((stream) >= VX_ADDRGEN_STREAM_LD0           \
                            && (stream) <= VX_ADDRGEN_STREAM_ST,            \
                               "invalid address-generator stream")

#define __VX_ADDRGEN_CHECK_DIM(dim)                                        \
    __VX_ADDRGEN_STATIC_ASSERT(__builtin_constant_p(dim),                  \
                               "address-generator dimension must be constant"); \
    __VX_ADDRGEN_STATIC_ASSERT((dim) >= 0 && (dim) < 3,                    \
                               "invalid address-generator dimension")

#define vx_addrgen_set_base(stream, base) do {                              \
    __VX_ADDRGEN_CHECK_STREAM(stream);                                      \
    uintptr_t __vx_addrgen_base = (uintptr_t)(base);                        \
    __asm__ volatile (".insn r %0, 0, %1, x0, %2, x0"                     \
                      :: "i"(RISCV_CUSTOM0), "i"(4 + (stream)),            \
                         "r"(__vx_addrgen_base) : "memory");               \
} while (0)

#define vx_addrgen_set_dim(stream, dim, stride_bytes, bound) do {           \
    __VX_ADDRGEN_CHECK_STREAM(stream);                                      \
    __VX_ADDRGEN_CHECK_DIM(dim);                                            \
    uintptr_t __vx_addrgen_stride = (uintptr_t)(intptr_t)(stride_bytes);    \
    uintptr_t __vx_addrgen_bound = (uintptr_t)(uint32_t)(bound);            \
    __asm__ volatile (".insn r %0, %1, %2, x0, %3, %4"                    \
                      :: "i"(RISCV_CUSTOM0), "i"(1 + (dim)),               \
                         "i"(4 + (stream)), "r"(__vx_addrgen_stride),       \
                         "r"(__vx_addrgen_bound) : "memory");              \
} while (0)

#define vx_addrgen_start(stream) do {                                       \
    __VX_ADDRGEN_CHECK_STREAM(stream);                                      \
    __asm__ volatile (".insn r %0, 4, %1, x0, x0, x0"                     \
                      :: "i"(RISCV_CUSTOM0), "i"(4 + (stream))             \
                      : "memory");                                         \
} while (0)

#define vx_addrgen_reset(stream) do {                                       \
    __VX_ADDRGEN_CHECK_STREAM(stream);                                      \
    __asm__ volatile (".insn r %0, 5, %1, x0, x0, x0"                     \
                      :: "i"(RISCV_CUSTOM0), "i"(4 + (stream))             \
                      : "memory");                                         \
} while (0)

inline __attribute__((always_inline)) uintptr_t vx_addrgen_pop_ld0() {
    uintptr_t address;
    __asm__ volatile (".insn r %1, 6, 4, %0, x0, x0"
                      : "=r"(address) : "i"(RISCV_CUSTOM0) : "memory");
    return address;
}

inline __attribute__((always_inline)) uintptr_t vx_addrgen_pop_ld1() {
    uintptr_t address;
    __asm__ volatile (".insn r %1, 6, 5, %0, x0, x0"
                      : "=r"(address) : "i"(RISCV_CUSTOM0) : "memory");
    return address;
}

inline __attribute__((always_inline)) uintptr_t vx_addrgen_pop_st() {
    uintptr_t address;
    __asm__ volatile (".insn r %1, 6, 6, %0, x0, x0"
                      : "=r"(address) : "i"(RISCV_CUSTOM0) : "memory");
    return address;
}
#endif

#define csr_read(csr) ({                        \
	size_t __r;	               		            \
	__asm__ __volatile__ ("csrr %0, %1" : "=r" (__r) : "i" (csr)); \
	__r;							            \
})

#define csr_write(csr, val)	({                  \
	size_t __v = (size_t)(val);                 \
	if (__builtin_constant_p(val) && __v < 32)  \
        __asm__ __volatile__ ("csrwi %0, %1" :: "i" (csr), "i" (__v));  \
    else                                        \
        __asm__ __volatile__ ("csrw %0, %1"	:: "i" (csr), "r" (__v));  \
})

#define csr_swap(csr, val) ({                   \
    size_t __r;                                 \
	size_t __v = (size_t)(val);	                \
	if (__builtin_constant_p(val) && __v < 32)  \
        __asm__ __volatile__ ("csrrwi %0, %1, %2" : "=r" (__r) : "i" (csr), "i" (__v)); \
    else                                        \
        __asm__ __volatile__ ("csrrw %0, %1, %2" : "=r" (__r) : "i" (csr), "r" (__v)); \
	__r;						                \
})

#define csr_read_set(csr, val) ({               \
	size_t __r;                                 \
	size_t __v = (size_t)(val);	                \
    if (__builtin_constant_p(val) && __v < 32)  \
	    __asm__ __volatile__ ("csrrsi %0, %1, %2" : "=r" (__r) : "i" (csr), "i" (__v)); \
    else                                        \
        __asm__ __volatile__ ("csrrs %0, %1, %2" : "=r" (__r) : "i" (csr), "r" (__v)); \
	__r;							            \
})

#define csr_set(csr, val) ({                    \
	size_t __v = (size_t)(val);	                \
    if (__builtin_constant_p(val) && __v < 32)  \
	    __asm__ __volatile__ ("csrsi %0, %1" :: "i" (csr), "i" (__v));  \
    else                                        \
        __asm__ __volatile__ ("csrs %0, %1"	:: "i" (csr), "r" (__v));  \
})

#define csr_read_clear(csr, val) ({             \
	size_t __r;                                 \
	size_t __v = (size_t)(val);	                \
    if (__builtin_constant_p(val) && __v < 32)  \
	    __asm__ __volatile__ ("csrrci %0, %1, %2" : "=r" (__r) : "i" (csr), "i" (__v)); \
    else                                        \
        __asm__ __volatile__ ("csrrc %0, %1, %2" : "=r" (__r) : "i" (csr), "r" (__v)); \
	__r;							            \
})

#define csr_clear(csr, val)	({                  \
	size_t __v = (size_t)(val);                 \
	if (__builtin_constant_p(val) && __v < 32)  \
        __asm__ __volatile__ ("csrci %0, %1" :: "i" (csr), "i" (__v)); \
    else                                        \
        __asm__ __volatile__ ("csrc %0, %1"	:: "i" (csr), "r" (__v)); \
})

// Set thread mask
inline void vx_tmc(int thread_mask) {
    __asm__ volatile (".insn r %0, 0, 0, x0, %1, x0" :: "i"(RISCV_CUSTOM0), "r"(thread_mask));
}

// disable all threads in the current warp
inline void vx_tmc_zero() {
    __asm__ volatile (".insn r %0, 0, 0, x0, x0, x0" :: "i"(RISCV_CUSTOM0));
}

// switch execution to single thread0
inline void vx_tmc_one() {
    __asm__ volatile (
        "li a0, 1\n\t"  // Load immediate value 1 into a0 (x10) register
        ".insn r %0, 0, 0, x0, a0, x0" :: "i"(RISCV_CUSTOM0) : "a0"
    );
}

// Set thread predicate
inline void vx_pred(int condition, int thread_mask) {
    __asm__ volatile (".insn r %0, 5, 0, x0, %1, %2" :: "i"(RISCV_CUSTOM0), "r"(condition), "r"(thread_mask));
}

// Set thread not predicate
inline void vx_pred_n(int condition, int thread_mask) {
    __asm__ volatile (".insn r %0, 5, 0, x1, %1, %2" :: "i"(RISCV_CUSTOM0), "r"(condition), "r"(thread_mask));
}

// Spawn warps
typedef void (*vx_wspawn_pfn)();
inline void vx_wspawn(int num_warps, vx_wspawn_pfn func_ptr) {
    __asm__ volatile (".insn r %0, 1, 0, x0, %1, %2" :: "i"(RISCV_CUSTOM0), "r"(num_warps), "r"(func_ptr));
}

// Split on a predicate
inline int vx_split(int predicate) {
    int ret;
    __asm__ volatile (".insn r %1, 2, 0, %0, %2, x0" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(predicate));
    return ret;
}

// Split on a not predicate
inline int vx_split_n(int predicate) {
    int ret;
    __asm__ volatile (".insn r %1, 2, 0, %0, %2, x1" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(predicate));
    return ret;
}

// Join
inline void vx_join(int stack_ptr) {
    __asm__ volatile (".insn r %0, 3, 0, x0, %1, x0" :: "i"(RISCV_CUSTOM0), "r"(stack_ptr));
}

// Warp Barrier
inline void vx_barrier(int barried_id, int num_warps) {
    __asm__ volatile (".insn r %0, 4, 0, x0, %1, %2" :: "i"(RISCV_CUSTOM0), "r"(barried_id), "r"(num_warps) : "memory");
}

// Return current thread identifier
inline __attribute__((const)) int vx_thread_id() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_THREAD_ID));
    return ret;
}

// Return current warp identifier
inline __attribute__((const)) int vx_warp_id() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_WARP_ID));
    return ret;
}

// Return current core identifier
inline __attribute__((const)) int vx_core_id() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_CORE_ID));
    return ret;
}

// Return active threads mask
inline __attribute__((const)) int vx_active_threads() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_ACTIVE_THREADS));
    return ret;
}

// Return active warps mask
inline __attribute__((const)) int vx_active_warps() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_ACTIVE_WARPS));
    return ret;
}

// Return the number of threads per warp
inline __attribute__((const)) int vx_num_threads() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_NUM_THREADS));
    return ret;
}

// Return the number of warps per core
inline __attribute__((const)) int vx_num_warps() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_NUM_WARPS));
    return ret;
}

// Return the number of cores per cluster
inline __attribute__((const)) int vx_num_cores() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_NUM_CORES));
    return ret;
}

// Return the hart identifier (thread id accross the processor)
inline __attribute__((const)) int vx_hart_id() {
    int ret;
    __asm__ volatile ("csrr %0, %1" : "=r"(ret) : "i"(VX_CSR_MHARTID));
    return ret;
}

inline void vx_fence() {
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}

// Returns 1 if every active lane’s predicate is true, 0 otherwise.
inline __attribute__((const)) int vx_vote_all(int predicate) {
    int ret;
    __asm__ volatile (".insn r %1, 0, 1, %0, %2, x0" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(predicate));
    return ret;
}

// Returns 1 if any active lane’s predicate is true, 0 if none are true.
inline __attribute__((const)) int vx_vote_any(int predicate) {
    int ret;
    __asm__ volatile (".insn r %1, 1, 1, %0, %2, x0" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(predicate));
    return ret;
}

//  Returns 1 if the predicate is uniform across all active lanes.
inline __attribute__((const)) int vx_vote_uni(int predicate) {
    int ret;
    __asm__ volatile (".insn r %1, 2, 1, %0, %2, x0" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(predicate));
    return ret;
}

// Returns a bitmask of the warp, with bit i set if lane i’s predicate is true.
inline __attribute__((const)) int vx_vote_ballot(int predicate) {
    int ret;
    __asm__ volatile (".insn r %1, 3, 1, %0, %2, x0" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(predicate));
    return ret;
}

// Shift values up by b lanes within each sub-group; out-of-range lanes keep their own value.
inline __attribute__((const)) int vx_shfl_up(size_t value, int bval, int cval, int mask) {
    int ret;
    int bc = (mask << 12) | (cval << 6) | bval;
    __asm__ volatile (".insn r %1, 4, 1, %0, %2, %3" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(value), "r"(bc));
    return ret;
}

// Shift values down by b lanes within each sub-group; out-of-range lanes keep their own value.
inline __attribute__((const)) int vx_shfl_down(size_t value, int bval, int cval, int mask) {
    int ret;
    int bc = (mask << 12) | (cval << 6) | bval;
    __asm__ volatile (".insn r %1, 5, 1, %0, %2, %3" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(value), "r"(bc));
    return ret;
}

// “Butterfly” exchange using XOR with b as a bit‐mask: each lane swaps with lane ⊕ b.
inline __attribute__((const)) int vx_shfl_bfly(size_t value, int bval, int cval, int mask) {
    int ret;
    int bc = (mask << 12) | (cval << 6) | bval;
    __asm__ volatile (".insn r %1, 6, 1, %0, %2, %3" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(value), "r"(bc));
    return ret;
}

// Gather from an explicit index: every lane reads the value from base + idx, where idx = b[i].
inline __attribute__((const)) int vx_shfl_idx(size_t value, int bval, int cval, int mask) {
    int ret;
    int bc = (mask << 12) | (cval << 6) | bval;
    __asm__ volatile (".insn r %1, 7, 1, %0, %2, %3" : "=r"(ret) : "i"(RISCV_CUSTOM0), "r"(value), "r"(bc));
    return ret;
}

#ifdef __cplusplus
}
#endif

#endif // __VX_INTRINSICS_H__
