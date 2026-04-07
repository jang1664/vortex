# FPINT GEMM Software Stack Guide

W4A16 mixed-precision GEMM: fp16 activations x int4 quantized weights.

## Overview

FPINT GEMM computes `C[M,N] = A[M,K] @ dequant(W_int4[K,N], scales, zeros)` where `dequant(w, s, zp) = (w - zp) * s`.

Two implementation paths exist:

| Path | Test dir | Kernel | Interface | Status |
|------|----------|--------|-----------|--------|
| HW FSM (production) | `tests/regression/fpint_gemm_ffn_hw/` | `kernel.cpp` (MMIO driver) | MMIO job descriptor regs | Active, PyTorch-integrated |
| SW thread model | `tests/regression/gemm_fpint/` | `kernel.cpp` (WMMA API) | `vx_spawn_threads` + TCU | Prototype/reference |

The HW FSM path is the production flow used by PyTorch.

---

## 1. Data Types and Quantization

### Operand Types
- **Activation (A):** fp16 `[M, K]`
- **Weight (W):** int4 packed into uint8 `[K, N/2]` (two int4 values per byte, low nibble first)
- **Scales:** fp16
- **Zero-points (zp):** int16
- **Output (C):** fp16 `[M, N]`

### Quantization Directions
| QDIR | Name | Scale/ZP shape | Meaning |
|------|------|----------------|---------|
| 0 | `QDIR_COL` | `[K/QBLK, N]` | Quantize along K-dimension (default, used for QKV/FFN) |
| 1 | `QDIR_ROW` | `[K, N/QBLK]` | Quantize along N-dimension (used for PV attention) |

### Weight Transpose (WTRANS)
| WTRANS | Layout | Use case |
|--------|--------|----------|
| 0 | `[K, N/2]` row-major | QKV gen, FFN |
| 1 | `[N, K/2]` (transposed) | QK^T attention |

### Common Combinations
| Use case | WTRANS | QDIR |
|----------|--------|------|
| QKV generation, FFN | 0 | 0 |
| QK^T (attention) | 1 | 0 |
| PV (attention) | 0 | 1 (QBLK = N) |

### Int4 Packing
Two int4 values packed into one uint8:
```
byte = (hi_nibble << 4) | (lo_nibble & 0x0F)
```
- Low nibble: even-indexed element
- High nibble: odd-indexed element

---

## 2. HW FSM Path (Production): `fpint_gemm_ffn_hw`

### Architecture
```
Host (main.cpp)
  |-- allocates DRAM buffers (A, W, scales, zp, C)
  |-- computes LMEM layout for double-buffered scratch
  |-- uploads kernel_arg_t via MMIO
  |-- launches kernel
  v
Device Kernel (kernel.cpp)
  |-- each core computes its tile partition (M x N space)
  |-- MMIO alloc: reads job entry from HW job frontend
  |-- programs 40 x 32-bit MMIO registers per job entry
  |-- polls REG_CONTROL for job completion
  v
HW GEMM FSM (RTL: VX_gemm_node.sv)
  |-- DMA engine tiles data: DRAM -> LMEM (double-buffered)
  |-- MXU computes fp16 x int4 with on-the-fly dequant
  |-- DMA stores results: LMEM -> DRAM
```

### Key Files
| File | Role |
|------|------|
| `tests/regression/fpint_gemm_ffn_hw/main.cpp` | Host test driver |
| `tests/regression/fpint_gemm_ffn_hw/kernel.cpp` | Device MMIO driver kernel |
| `tests/regression/fpint_gemm_ffn_hw/common.h` | Shared structs and register map |
| `kernel/src/fi_gemm.c` | ISA-level kernel reference (DMA/MXU instruction stream) |

### kernel_arg_t Structure
```c
typedef struct {
  uint32_t grid_dim[2];    // [num_cores, 1]
  uint32_t block_dim[2];   // [1, 1]

  uint32_t M, N, K;        // Problem dimensions
  uint32_t QBLK;           // Quantization block size (power of 2)
  uint32_t WTRANS;         // 0: normal, 1: transposed weight
  uint32_t QDIR;           // 0: col, 1: row

  uint64_t input_base;     // DRAM address of A [M x K] fp16
  uint64_t weight_base;    // DRAM address of W [K x N/2] packed int4
  uint64_t output_base;    // DRAM address of C [M x N] fp16
  uint64_t scale_base;     // DRAM address of scales
  uint64_t zp_base;        // DRAM address of zero-points

  // LMEM scratch addresses (computed by host)
  uint64_t lmem_ibuf0_base, lmem_ibuf1_base;   // input double buffer
  uint64_t lmem_wbuf0_base, lmem_wbuf1_base;   // weight double buffer
  uint64_t lmem_scbuf0_base, lmem_scbuf1_base; // scale double buffer
  uint64_t lmem_zpbuf0_base, lmem_zpbuf1_base; // zp double buffer
  uint64_t lmem_obuf_base;                      // output buffer

  uint32_t status;          // Result status code
  uint32_t job_eid;         // Job entry ID
  uint32_t job_generation;  // Job generation counter
  uint32_t last_ctrl;       // Last control register value
} kernel_arg_t;
```

### MMIO Register Map (40 x 32-bit)
| Index | Name | Description |
|-------|------|-------------|
| 0 | `REG_CONTROL` | Start (write 1) / completion status (read) |
| 1-2 | `REG_INPUT_BASE` | DRAM input base (64-bit) |
| 3-4 | `REG_WEIGHT_BASE` | DRAM weight base (64-bit) |
| 5-6 | `REG_OUTPUT_BASE` | DRAM output base (64-bit) |
| 7-8 | `REG_SCALE_BASE` | DRAM scale base (64-bit) |
| 9-10 | `REG_ZP_BASE` | DRAM zero-point base (64-bit) |
| 11-28 | `REG_LMEM_*` | LMEM scratch buffer addresses (9 x 64-bit) |
| 29-32 | `REG_M/N/K/QBLK_ORIG` | Original problem dimensions |
| 33-37 | `REG_M/N/K_TARGET, M/N_START` | Per-core partition info |
| 38-39 | `REG_WTRANS, REG_QDIR` | Flags |

### LMEM Layout
Host computes LMEM addresses for 9 scratch buffers with 64-byte alignment:
```
[ibuf0][ibuf1][wbuf0][wbuf1][scbuf0][scbuf1][zpbuf0][zpbuf1][obuf]
```
Buffer sizes:
- ibuf: `DMA_MT * DMA_KT * 2` bytes (fp16)
- wbuf: `DMA_KT * (DMA_NT+1)/2` bytes (packed int4)
- scbuf: `groups_tile * DMA_NT * 2` or `DMA_KT * ng_tile * 2` bytes
- zpbuf: same as scbuf
- obuf: `DMA_MT * DMA_NT * 2` bytes (fp16)

Where `DMA_MT = DMA_NT = DMA_KT = 128`.

### Multi-Core Partitioning
When multiple cores are available, the M x N output space is partitioned:
- Each core gets a rectangular tile region `[m_start..m_start+target_M, n_start..n_start+target_N]`
- Partition is computed in `compute_partition()` in `kernel.cpp`
- K dimension is not partitioned (each core processes full K)

### Status Codes
| Code | Name | Meaning |
|------|------|---------|
| 0 | `MMIO_STATUS_INIT` | Not yet started |
| 1 | `MMIO_STATUS_OK` | Completed successfully |
| 2 | `MMIO_STATUS_ALLOC_FAIL` | Job allocation failed |
| 3 | `MMIO_STATUS_WAIT_STUCK` | Polling timeout |
| 4 | `MMIO_STATUS_BAD_EID` | Invalid entry ID |

---

## 3. HW FSM Instruction Stream: `fi_gemm.c`

`kernel/src/fi_gemm.c` is the ISA-level reference showing the instruction stream that the HW FSM executes. This is **not** compiled as a device kernel — it documents the DMA and MXU instruction sequence.

### Tiling Parameters
```
MT = 128, NT = 128, KT = 128      (DMA tile)
MXU_KT = 32, MXU_NT = 32          (MXU tile)
```

### Double Buffering
Two levels of double buffering:
1. **DMA-tile level:** alternates between buf0/buf1 for input, weight, scale/zp tiles
2. **MXU-tile level:** alternates weight and scale/zp registers within one DMA tile

### Instruction Opcodes (from ISA)
| Opcode | Instruction | Description |
|--------|-------------|-------------|
| 1 | `DMA_LOAD` | Load DRAM -> TMEM (3-word instruction) |
| 2 | `DMA_STORE` | Store TMEM -> DRAM (3-word instruction) |
| 3 | `NOTIFY` | Set/increment sync register |
| 4 | `WAIT` | Wait until sync register >= value |
| 5 | `MXU_LOAD_WEIGHT` | Load weight into MXU register |
| 6 | `MXU_LOAD_QPARAM` | Load scale/zp into MXU |
| 7 | `MXU_LOAD_INPUT` | Issue GEMM (input + accumulate) |
| 8 | `MXU_STORE_OUTPUT` | Store accumulator to TMEM |
| 9 | `CLEAR` | Clear and terminate |

### Sync Registers (RID)
| RID | Name | Purpose |
|-----|------|---------|
| 0-1 | `RID_LD0/1` | DMA tile load done (per double buffer) |
| 2-3 | `RID_W0/1` | MXU weight load done |
| 4-5 | `RID_SZ0/1` | MXU scale/zp load done |
| 6-7 | `RID_G0/1` | GEMM computation done |
| 8-9 | `RID_O0/1` | Output accumulator-to-TMEM done |
| 10 | `RID_ST` | DMA store done |

### Execution Flow (per DMA tile)
```
1. WAIT for DMA tile data ready
2. For each MXU tile (kt_mxu x nt_mxu):
   a. Preload next MXU weight + scale/zp (double buffer)
   b. WAIT for current weight + scale/zp ready
   c. MXU_LOAD_INPUT (triggers GEMM compute)
   d. WAIT for GEMM done
   e. If last K iteration: MXU_STORE_OUTPUT -> output TMEM
3. DMA_STORE output tile back to DRAM
```

---

## 4. SW Thread Model Path: `gemm_fpint`

### Architecture
Uses the standard Vortex WMMA (Warp Matrix Multiply-Accumulate) API:
```
Host (main.cpp)
  |-- allocates buffers, generates test data
  |-- dispatches via vx_spawn_threads
  v
Device Kernel (kernel.cpp)
  |-- KERNEL_DEQUANT: int4 -> fp16 (parallel over K*N)
  |-- KERNEL_GEMM: fp16 x fp16 WMMA
  |-- KERNEL_FUSED: on-the-fly dequant + WMMA (incomplete)
```

### Key APIs
```cpp
#include <vx_tensor.h>
using ctx = vt::wmma_context<NUM_THREADS, vt::ITYPE, vt::OTYPE>;

ctx::fragment_a fragA;
ctx::fragment_b fragB;
ctx::fragment_acc fragC;

ctx::load_matrix_sync(fragA, ptr, stride);
ctx::mma_sync(fragC, fragA, fragB, fragC);
ctx::store_matrix_sync(ptr, fragC, stride);
```

---

## 5. PyTorch Integration

### Custom Op Registration
```python
# Registered as vortex::mm_w4a16
torch.ops.vortex.mm_w4a16(input, weight_int4, scales, zeros, group_size, N, wtrans=0, qdir=0)
```

### Parameters
| Param | Type | Description |
|-------|------|-------------|
| `input` | `Tensor fp16 [M, K]` | Activation matrix |
| `weight_int4` | `Tensor uint8 [K, N/2]` | Packed int4 weights |
| `scales` | `Tensor fp16 [groups, N]` | Per-group scales |
| `zeros` | `Tensor int16 [groups, N]` | Per-group zero-points |
| `group_size` | `int` | Elements per quantization group |
| `N` | `int` | Output dimension |
| `wtrans` | `int` | Weight transposed flag (0/1) |
| `qdir` | `int` | Quantization direction (0=col, 1=row) |

### Implementation Flow (VortexExtra.cpp)
1. Validate tensor shapes and dtypes
2. Allocate output tensor `[M, N]` fp16
3. Query device capabilities (num_cores, local_mem_size)
4. Compute LMEM layout (`compute_fpint_lmem_layout`)
5. Build `fpint_gemm_kernel_arg_t` matching `common.h`
6. Launch `fpint_gemm_ffn_hw` kernel via `launch_kernel()`

### Key Files
| File | Role |
|------|------|
| `pytorch/csrc/aten/VortexExtra.cpp` | Op registration and launch logic |
| `pytorch/test/test_native_mm_w4a16.py` | End-to-end PyTorch test |

---

## 6. Running Tests

### HW FSM Test (rtlsim)
```bash
cd build
CONFIGS="-DNUM_CORES=1 -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34"
./ci/blackbox.sh --driver=rtlsim --app=fpint_gemm_ffn_hw --debug=3 \
  --args="-m 32 -n 128 -k 64 -q 32 -t 0 -d 0"
```

### Sweep Test
```bash
cd build
bash tests/regression/fpint_gemm_ffn_hw/test.sh
# Or with specific cases:
bash tests/regression/fpint_gemm_ffn_hw/test.sh "-m 2 -n 32 -k 32 -q 32 -t 0 -d 0"
```

### Test Arguments
| Arg | Description | Default |
|-----|-------------|---------|
| `-m` | M dimension | 2 |
| `-n` | N dimension | 32 |
| `-k` | K dimension | 32 |
| `-q` | QBLK (quant block size) | 32 |
| `-t` | WTRANS (0 or 1) | 0 |
| `-d` | QDIR (0 or 1) | 0 |

### Constraints
- M, N must be multiples of 32 (MXU_NT)
- K must be a multiple of 128 (KT)
- QBLK must be a power of 2 and divide K (for QDIR_COL)
- For QDIR_ROW, QBLK must equal N
- KT % QBLK == 0 (for QDIR_COL)
- N must be even (int4 packing)

---

## 7. Constraints Summary

| Constraint | Reason |
|------------|--------|
| `QBLK` is power of 2 | HW uses log2 encoding |
| `K % QBLK == 0` (QDIR_COL) | Groups must tile evenly |
| `QBLK == N` (QDIR_ROW) | Row-quantization assumes full-N group |
| `KT % MXU_KT == 0` | MXU tiling |
| `NT % MXU_NT == 0` | MXU tiling |
| LMEM must fit 9 buffers | Each is ~32KB for default tile sizes |
