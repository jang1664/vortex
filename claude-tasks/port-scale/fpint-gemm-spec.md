# FPINT GEMM Accelerator Specification

**Status**: REVISION (2026-04-09) — DMA 1:1 channel-bank mapping, gemm_dma_ctrl 8-channel decomposition, HBM remap
**Branch**: fpint_improve

---

## 1. Overview

W4A16 mixed-precision GEMM accelerator: `C[M,N] = A[M,K] @ dequant(W_int4[K,N], scales, zeros)`

Extension of Vortex RISC-V core EX stage with a GEMM node. Key components:
- **MXU**: 32x32 FP-INT GEMM unit (adder tree, pre/post processor)
- **TMEM**: 8-bank dedicated SRAM (64B/bank, interleaved addressing)
- **DMA Engine**: 8-channel HBM-to-TMEM bulk transfer (1:1 channel-bank mapping)
- **Local DMA**: TMEM-to-GEMM unit data movement (4 channels: input/weight/sz/output)
- **GEMM Ctrl + DMA Ctrl**: HW FSM for tiling, sync, and DMA channel decomposition

LMEM is dedicated to LSU only; TMEM is dedicated to GEMM only.

---

## 2. Architecture

### 2.1 GEMM Node (Core Internal)

```
HBM (AXI x8, 1:1 channel-bank mapping)
    |
    v
+----------+  membus x8   +-------------------------------+
|   DMA    |-------------->|  5:1 arbiter -> TMEM bank x8  |
|(ch N ->  |  (ch N ->     |  (VX_sp_ram, 1-port each,     |
| bank N)  |   bank N      |   32KB default, param SIZE)   |
|          |   direct)     |                               |
+----------+               +---------------+---------------+
                     +---------------------+---------------------+
                     v                     v                      v
               +-----------+       +-----------+          +-----------+
               |1:8 switch |       |1:8 switch |          |1:8 switch |
               |(input)    |       |(weight)   |          |(scale_zp) |
               +-----+-----+       +-----+-----+          +-----+-----+
                     v                    v                       v
               +-----------+       +-----------+          +-----------+
               |input      |       |weight     |          |scale_zp   |
               |local DMA  |       |local DMA  |          |local DMA  |
               +-----+-----+       +-----+-----+          +-----+-----+
                     v                    v                       v
               +-------------------------------------------------------------+
               |              GEMM Unit (MXU 32x32)                           |
               |  input:     64B VX_mem_bus_if                                |
               |  weight:    64B VX_mem_bus_if (4 rows per read)              |
               |  scale_zp:  64B VX_mem_bus_if                                |
               |  output:    64B VX_mem_bus_if                                |
               +-----------------------+------------------------------------- +
                                       v
                                +-----------+
                                |output     |
                                |local DMA  |
                                +-----+-----+
                                      v
                                +-----------+
                                |1:8 switch |
                                +-----+-----+
                                      v
                              5:1 arbiter -> TMEM bank x8
```

### 2.2 TMEM Bank Access Arbitration

Each TMEM bank uses a single-port `VX_sp_ram`. Multiple requestors are serialized through an arbiter:

```
Requestors per bank N (5:1 arbiter):
  [0] DMA ch N membus port (direct 1:1, bank-local address)
  [1] input switch output[N] (interleaved addr -> switch converts to bank-local)
  [2] weight switch output[N]
  [3] scale_zp switch output[N]
  [4] output switch output[N]
     -> VX_mem_arb (5:1) -> VX_sp_ram (1-port)
```

**The DMA port does not go through a switch.** gemm_dma_ctrl pre-computes bank-local addresses for each DMA channel, so DMA ch N's membus connects directly to bank N's arbiter port 0.

### 2.3 Switch (Bidirectional Mux/Demux)

- Handles both req/rsp directions of `VX_mem_bus_if`
- 1:8 switch: routes local DMA requests to one of 8 banks
- Address-based routing: `addr[2:0]` -> bank select, `addr >> 3` -> bank-local addr
- Response path: round-robin arbiter merges bank responses back to local DMA

### 2.4 Upper Hierarchy

```
+------------+  cache_master   +--------------+  mem_master   +-------------+
|VX_core x N |---------------->| cache system |-------------->| axi adapter |
|            |                 +--------------+               +------+------+
|            |  dma_master[8] (AXI_BUS)                              |
|            |--------------------------------------+                v
+------------+                                      |        +------------+
                                                    +------->|1:8 switch  |
                                                    |        +-----+------+
                                                    v              v
                                              +-----------------------------+
                                              |      AXI Arbiter            |
                                              |  (axi_mux from third_party) |
                                              |  slave[8 + 8*NUM_CORES]     |
                                              |  master[8] -> HBM           |
                                              +-----------------------------+
```

AXI arbiter slave port mapping:
- `slave[(1+NUM_CORES)*j + 0]` = LSU (axi adapter -> 1:8 switch -> port j)
- `slave[(1+NUM_CORES)*j + i+1]` = core[i].dma_master[j]

### 2.5 GEMM Control Flow

```
SW kernel (MMIO writes) -> Job Frontend -> CMD Constructor
  -> GEMM Ctrl (MXU commands: load weight/input/qparam, store output)
  -> GEMM DMA Ctrl (DMA commands: load/store, 8-channel decomposition)
  -> GEMM Sync (wait/notify between DMA and MXU)
```

- **CMD Constructor**: MMIO registers -> unified command struct (`gemm_unified_cmd_t`)
- **GEMM Ctrl**: MXU tiling FSM, double buffering orchestration
- **GEMM DMA Ctrl**: Decomposes SW interleaved CMD into 8-channel configs -> DMA config registers
- **GEMM Sync**: Barrier-style synchronization (wait/notify/clear)

### 2.6 HBM / HMSS

- Xilinx U55C: 2 HBM stacks, 16 channels, 32 pseudo-channels (PC)
- HMSS (Xilinx IP): 32 AXI3 slave ports
  - **Non-global mode**: each AXI slave maps to one PC
  - **Default address map: contiguous** (PC0=0~512MB, PC1=512MB~1GB, ...)
  - Vortex uses 8 AXI master ports -> HMSS 8:32 interconnection
- HW must remap interleaved -> contiguous addresses (see section 4.7)

---

## 3. Address Space

### 3.1 XLEN64 Memory Map

| Region | Address Range | Size | Access Method |
|--------|--------------|------|---------------|
| IO_GEMM0 | `0x1080` | 1KB | GEMM MMIO |
| IO_GEMM1 | `0x1480` | 1KB | DMA MMIO |
| USER | `0x10000~` | 8GB | malloc, load/store |
| STARTUP_ADDR | `0x80000000` | image size | IFetch + load/store |
| STACK | `0x1FFFF0000` (grows down) | 8KB/hart | load/store |
| LMEM | `0x1FFFF0000` | 16KB | LSU local (core-local) |
| TMEM | (internal to GEMM node) | 256KB (32KB x 8) | DMA/local DMA only |

- LMEM: LSU-only. Core-local scratchpad.
- TMEM: GEMM-only. Not addressable externally. Accessed only by DMA and local DMA.

### 3.2 CSR / DCR / Host MMIO

| Space | Address | Scope | Access Method |
|-------|---------|-------|---------------|
| CSR | 12-bit (0x000~0xFFF) | core-local | csrr/csrw |
| DCR | 0x001~0x005 | host -> core fanout | Host MMIO DCR write |
| Host AFU MMIO | 0x00~0x30 | host-device | PCIe/XRT register R/W |

---

## 4. TMEM Address Space and DMA Channel Decomposition

### 4.1 TMEM Address Space (Interleaved)

TMEM uses 8-bank x 64B interleaved addressing.
**All components, including SW, always think in interleaved address space.**

```
NUM_BANKS = 8, DATA_SIZE = 64B

Word address -> bank mapping:
  word_addr[2:0] = bank_id
  word_addr[...:3] = bank_local_addr

Byte address -> bank mapping:
  bank_id = (byte_addr / 64) % 8
  bank_local_byte_offset = (byte_addr / 512) * 64 + (byte_addr % 64)

Example (byte addresses):
  Bank 0: 0, 512, 1024, 1536, 2048, ...
  Bank 1: 64, 576, 1088, 1600, 2112, ...
  ...
  Bank 7: 448, 960, 1472, 1984, 2496, ...
```

### 4.2 HBM Address Space (Interleaved, SW View)

From the SW perspective, HBM uses the same interleaving scheme:

```
HBM port N = byte addresses where (byte_addr / 64) % 8 == N (SW view)

Example:
  HBM port 0: 0, 512, 1024, ...
  HBM port 1: 64, 576, 1088, ...
```

### 4.3 1:1 Mapping Constraint

DMA ch N <-> TMEM bank N <-> HBM port N are directly connected 1:1:

```
hbm_addr % 512 == tmem_addr % 512
```

Data at HBM byte addr `A` is always stored at TMEM byte addr `A`. Both belong to the same bank, so channel N handles them.

### 4.4 gemm_dma_ctrl 8-Channel Decomposition

**SW sends DMA CMDs in interleaved TMEM address space.**
**HW (`gemm_dma_ctrl`) decomposes these into 8 per-channel configs** and programs each DMA channel.

```
SW CMD: src_base(HBM), dst_base(TMEM), stride, bound, seg_size (all interleaved addresses)

gemm_dma_ctrl decomposition:
  for ch = 0..7:
    ch_src_base = HBM address of ch's 64B block from src_base (with remap applied)
    ch_dst_base = bank-local address (strip bank_sel bits from interleaved addr)
    ch_stride   = convert interleaved stride to bank-local stride
    ch_bound    = same (number of segments each bank processes)
    -> program DMA cfg_reg_if[ch]
```

Example: SW requests filling TMEM addr 0~4095 (64 x 64B):
- ch0: HBM byte 0,512,1024,...,3584 -> TMEM bank 0 local addr 0,1,2,...,7
- ch1: HBM byte 64,576,1088,...,3648 -> TMEM bank 1 local addr 0,1,2,...,7
- ...
- ch7: HBM byte 448,960,1472,...,4032 -> TMEM bank 7 local addr 0,1,2,...,7

**Each DMA channel writes to its TMEM bank using bank-local addresses. No switch involved.**

### 4.5 Local DMA -> TMEM (Via Switch)

Local DMA uses interleaved addresses -> `VX_tmem_switch` selects bank via `addr[2:0]` and converts upper bits to bank-local address.

Since SW computes all addresses in interleaved space from the start, addresses passed to local DMA are already interleaved.

### 4.6 TMEM <-> MXU Address Alignment

```
input:      base_addr(input[x, 32y+:32]) % 64 == 0
weight:     base_addr(weight[4x+:4, 32y+:32]) % 64 == 0
output:     base_addr(output[x, 32y+:32]) % 64 == 0
scale/zp:   base_addr(scale[x, 32y+:32]) % 64 == 0  (qdir==0)
            base_addr(scale[32x+:32, y]) % 64 == 0  (qdir==1)
```

### 4.7 HBM Address Remap (Interleaved -> Contiguous)

HMSS maps each PC to a contiguous address region (PC0=0~512MB, PC1=512MB~1GB, ...).
SW thinks in interleaved addresses, so **Vortex HW (AXI adapter or DMA) must remap**:

```
When sending SW interleaved byte addr A to AXI port N:
  N = (A / 64) % 8
  Actual address on AXI port N = (N * 512MB) + floor(A / 512) * 64 + (A % 64)

Example: SW accesses addr 0~2048
  AXI port 0: addr 0, 64, 128, ... (contiguous within PC0 space)
  AXI port 1: addr 512MB+0, 512MB+64, ... (contiguous within PC1 space)
```

---

## 5. Data Types and Quantization

### 5.1 Operand Types
- **Activation (A):** fp16 `[M, K]`
- **Weight (W):** int4 packed into uint8 `[K, N/2]` (low nibble first)
- **Scales:** fp16
- **Zero-points (zp):** int16
- **Output (C):** fp16 `[M, N]`

### 5.2 Quantization Directions

| QDIR | Name | Scale/ZP shape | Use case |
|------|------|----------------|----------|
| 0 | `QDIR_COL` | `[K/QBLK, N]` | QKV gen, FFN |
| 1 | `QDIR_ROW` | `[K, N/QBLK]` | PV attention |

### 5.3 Weight Transpose

| WTRANS | Layout | Use case |
|--------|--------|----------|
| 0 | `[K, N/2]` row-major | QKV gen, FFN |
| 1 | `[N, K/2]` transposed | QK^T attention |

---

## 6. SW Stack (HW FSM Path)

### 6.1 Execution Flow

```
Host (main.cpp) -> allocate DRAM buffers -> compute TMEM layout -> upload kernel_arg
  -> Device Kernel (kernel.cpp) -> MMIO writes -> HW GEMM FSM
    -> DMA tiles: HBM -> TMEM (double-buffered)
    -> MXU computes: fp16 x int4 with dequant
    -> DMA stores: TMEM -> HBM
```

### 6.2 kernel_arg_t

```c
typedef struct {
  uint32_t grid_dim[2], block_dim[2];
  uint32_t M, N, K, QBLK, WTRANS, QDIR;

  uint64_t input_base, weight_base, output_base;  // DRAM addresses
  uint64_t scale_base, zp_base;

  // TMEM scratch addresses (computed by host, interleaved address space)
  uint64_t tmem_ibuf0_base, tmem_ibuf1_base;   // input double buffer
  uint64_t tmem_wbuf0_base, tmem_wbuf1_base;   // weight double buffer
  uint64_t tmem_scbuf0_base, tmem_scbuf1_base; // scale double buffer
  uint64_t tmem_zpbuf0_base, tmem_zpbuf1_base; // zp double buffer
  uint64_t tmem_obuf_base;                      // output buffer

  uint32_t status, job_eid, job_generation, last_ctrl;
} kernel_arg_t;
```

### 6.3 TMEM Buffer Layout

Host computes TMEM addresses for 9 scratch buffers with 64-byte alignment (interleaved address space):
```
[ibuf0][ibuf1][wbuf0][wbuf1][scbuf0][scbuf1][zpbuf0][zpbuf1][obuf]
```

Buffer sizes (DMA_MT = DMA_NT = DMA_KT = 128):
- ibuf: `DMA_MT * DMA_KT * 2` bytes (fp16)
- wbuf: `DMA_KT * (DMA_NT+1)/2` bytes (packed int4)
- scbuf/zpbuf: `groups_tile * DMA_NT * 2` or `DMA_KT * ng_tile * 2` bytes
- obuf: `DMA_MT * DMA_NT * 2` bytes (fp16)

### 6.4 MMIO Register Map (40 x 32-bit)

| Index | Name | Description |
|-------|------|-------------|
| 0 | REG_CONTROL | Start (write 1) / completion status (read) |
| 1-10 | REG_*_BASE | DRAM base addresses (5 x 64-bit) |
| 11-28 | REG_TMEM_* | TMEM scratch buffer addresses (9 x 64-bit) |
| 29-32 | REG_M/N/K/QBLK_ORIG | Original problem dimensions |
| 33-37 | REG_M/N/K_TARGET, M/N_START | Per-core partition |
| 38-39 | REG_WTRANS, REG_QDIR | Flags |

### 6.5 Instruction Opcodes (HW FSM)

| Opcode | Instruction | Description |
|--------|-------------|-------------|
| 1 | DMA_LOAD | Load HBM -> TMEM |
| 2 | DMA_STORE | Store TMEM -> HBM |
| 3 | NOTIFY | Set/increment sync register |
| 4 | WAIT | Wait until sync register >= value |
| 5 | MXU_LOAD_WEIGHT | Load weight into MXU register |
| 6 | MXU_LOAD_QPARAM | Load scale/zp into MXU |
| 7 | MXU_LOAD_INPUT | Issue GEMM (input + accumulate) |
| 8 | MXU_STORE_OUTPUT | Store accumulator to TMEM |
| 9 | CLEAR | Clear and terminate |

### 6.6 Tiling and Double Buffering

```
MT = 128, NT = 128, KT = 128      (DMA tile)
MXU_KT = 32, MXU_NT = 32          (MXU tile)
```

Two levels of double buffering:
1. **DMA-tile level:** buf0/buf1 alternation for input, weight, scale/zp
2. **MXU-tile level:** weight/scale_zp register alternation within one DMA tile

### 6.7 Multi-Core Partitioning

The M x N output space is partitioned into rectangular tiles per core:
- K dimension is not partitioned (each core processes the full K)
- See `compute_partition()` in kernel.cpp

### 6.8 Constraints

- M, N: multiples of 32 (MXU_NT)
- K: multiple of 128 (KT)
- QBLK: power of 2, divides K (QDIR_COL)
- QDIR_ROW: QBLK == N
- KT % QBLK == 0 (QDIR_COL)
- N must be even (int4 packing)

### 6.9 PyTorch Integration

```python
# Registered as vortex::mm_w4a16
torch.ops.vortex.mm_w4a16(input, weight_int4, scales, zeros, group_size, N, wtrans=0, qdir=0)
```

Implementation: `pytorch/csrc/aten/VortexExtra.cpp`

---

## 7. Modules

### 7.1 New Modules

| Module | File | Description |
|--------|------|-------------|
| `VX_tensor_mem_bank` | `hw/rtl/mem/VX_tensor_mem_bank.sv` | Single TMEM bank. VX_sp_ram 1-port + VX_mem_arb(5:1). 32KB default. |
| `VX_tmem_subsystem` | `hw/rtl/mem/VX_tmem_subsystem.sv` | TMEM bank x8 + switch x4 + DMA 1:1 direct connection. |
| `VX_dma_engine` | `hw/rtl/mem/VX_dma_engine.sv` | 8-channel HBM<->TMEM DMA. ch N -> bank N direct. |
| `VX_tmem_switch` | `hw/rtl/mem/VX_tmem_switch.sv` | Interleaved address -> bank routing (for local DMA). |

### 7.2 Modified Modules

| Module | File | Change |
|--------|------|--------|
| `VX_gemm_dma_ctrl` | `hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv` | Add 8-channel decomposition. Convert SW interleaved CMD to per-channel bank-local addr/stride + HBM remap. |
| `VX_gemm_node` | `hw/rtl/core/gemm/VX_gemm_node.sv` | Remove LMEM path. Instantiate VX_tmem_subsystem. Expose DMA AXI ports. |
| `VX_tmem_subsystem` | `hw/rtl/mem/VX_tmem_subsystem.sv` | Change DMA ch N -> bank N direct (currently ch0-only via switch -> 8ch 1:1 direct). |
| `VX_core` | `hw/rtl/core/VX_core.sv` | Add `AXI_BUS.Master dma_axi[8]` port. |
| `VX_lmem_switch` | `hw/rtl/mem/VX_lmem_switch.sv` | Remove GEMM path. LSU-only. |

### 7.3 Third-party (from third_party/axi)

`AXI_BUS`, `axi_from_mem`, `axi_mux`, `axi_demux`, `axi_pkg`, `axi/typedef.svh`, `axi/assign.svh`

---

## 8. Constraints & Assumptions

1. **DMA ch N -> TMEM bank N -> HBM port N: 1:1 direct** — DMA bypasses switches, uses bank-local addresses.
2. **Local DMA accesses TMEM via switch using interleaved addresses** — switch handles bank selection and address conversion.
3. **SW always thinks in interleaved address space** — gemm_dma_ctrl performs per-channel decomposition in HW.
4. **HBM remap required** — HMSS uses contiguous addressing; HW must convert interleaved -> contiguous.
5. **TMEM is GEMM-only**, LMEM is LSU-only.
6. **512-bit data width** unified across DMA, TMEM, and switches.
7. **GEMM unit ports are 64B `VX_mem_bus_if`**.
8. **DMA AXI ports bypass cache** — connect directly to AXI arbiter.
9. **TMEM bank is 1-port**: VX_sp_ram + 5:1 arbiter.
10. **DMA is SW-controlled**: stride, bound come from CMD. HW does not compute tiling (only channel decomposition).

---

## 9. Performance Analysis

### 9.1 FPGA Equivalent Gate Area

ENS (Equivalent Number of Slices) — COMET paper (arXiv 2510.03516):
```
ENS = LUTs/4 + DSP_used x 102.4 + BRAM18K_used x 116.2
ASIC_gate_equiv ~ ENS x 24
```

### 9.2 Algorithmic Operation Intensity (AOI)

Reference: Llama-2 7B (H=4096, I=11008), A16W4KV4

**Prefill** (N_prefill = B x S):
- Q/K/V/O proj: `OI = 2048*B*S / (B*S + 512)`
- Gate/Up/Down proj: `OI ~ 2985.2*B*S / (B*S + 746.3)`
- Fused self-attention: `OI = S/2`

**Decode** (N_decode = B):
- Q/K/V/O proj: `OI = 2048*B / (B + 512)`
- Gate/Up/Down proj: `OI ~ 2985.2*B / (B + 746.3)`
- Fused decode attention: `OI = 4*L / (L + 4)` (saturates at ~4 as L grows)

**Key insight**: Prefill is compute-bound (OI proportional to B x S). Decode is memory-bound (attention OI <= 4).

### 9.3 Bandwidth / Throughput (100MHz)

| Memory | Configuration | Bandwidth |
|--------|--------------|-----------|
| HBM | N_PC x 64B port | 6.25 x N_PC GB/s (N_PC=32 -> 200 GB/s) |
| TMEM | 8 banks x 64B, single port | 50 GB/s |
| LMEM | 8 banks, 64-bit port | 6.25 GB/s |
| Cache (L2) | 64B cache line, 1 port | 6.25 GB/s |

| Unit | Operation | Throughput |
|------|-----------|-----------|
| MXU 32x32 | FP-INT GEMM | 200 GOps/s |
| MXU input | 32 x 2B/cycle | 6.25 GB/s |
| MXU weight | 512B/cycle | 50 GB/s |

### 9.4 Data Path Diagram

```
                        1536 b/cyc read
  Register File (4 banks) ------------>  TCU/MXU
                          <------------
                          512 b/cyc write

  Register File <--------------------->  LSU (512 b/cyc)
                                          |
  LMEM (8 banks) <-------------------->  LSU (512 b/cyc)
                                          |
  L2 Cache <---------------------------->  L1 bypass (512 b/cyc)
                                          |
  HBM <-------------------------------->  AXI (512 b/cyc per port)
```

---

## 10. Key Files

| File | Role |
|------|------|
| `hw/rtl/core/gemm/VX_gemm_node.sv` | GEMM node top (MXU + TMEM subsystem) |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv` | DMA command decode + 8-channel decomposition |
| `hw/rtl/core/gemm/VX_gemm_ctrl.sv` | MXU tiling FSM |
| `hw/rtl/core/gemm/VX_cmd_constructor.sv` | MMIO -> unified command |
| `hw/rtl/core/gemm/VX_gemm_sync.sv` | Wait/notify synchronization |
| `hw/rtl/mem/VX_dma_engine.sv` | 8-channel DMA engine |
| `hw/rtl/mem/VX_tmem_subsystem.sv` | TMEM banks + switches + DMA wiring |
| `hw/rtl/mem/VX_tmem_switch.sv` | Interleaved address -> bank routing |
| `hw/rtl/mem/VX_tensor_mem_bank.sv` | Single TMEM bank |
| `hw/rtl/core/VX_dma_unit_misal.sv` | 3D strided DMA FSM |
| `tests/regression/fpint_gemm_ffn_hw/` | HW FSM test (host + kernel) |
| `kernel/src/fi_gemm.c` | ISA-level instruction stream reference |
| `pytorch/csrc/aten/VortexExtra.cpp` | PyTorch custom op |
