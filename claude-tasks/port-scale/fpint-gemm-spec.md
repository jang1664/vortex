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
- **GEMM Ctrl + DMA Ctrl**: HW FSM for command execution, sync, and DMA channel decomposition

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

### 2.4 Upper Hierarchy (Vortex_axi.sv)

**Terminology**:
- `NUM_HBM_MAS_PORTS = 8` — number of AXI master ports exiting Vortex_axi to HMSS (or sim). Previously called `C_M_AXI_MEM_NUM_BANKS` in RTL / `NUM_BANKS` in TB — **rename these to `NUM_HBM_MAS_PORTS`** to avoid confusion with `PLATFORM_MEMORY_NUM_BANKS` (= 32, the number of HBM pseudo-channels).

```
+------------+  cache_master   +--------------+  mem_master   +------------------+
|VX_core x N |---------------->| cache system |-------------->| VX_axi_adapter   |
|            |                 +--------------+               | (NUM_BANKS_OUT=8 |
|            |                                                |  INTERLEAVE=1)   |
|            |                                                +--------+---------+
|            |                                                         |
|            |  dma_master[8] (AXI_BUS)                                v
|            |--------------------------------------+          +------------+
+------------+                                      |          | axi_demux  |
                                                    |          | addr[8:6]  |
                                                    |          +-----+------+
                                                    v                v
                                              +-----------------------------+
                                              |      axi_mux (per port j)  |
                                              |  slave[0] = LSU demux[j]   |
                                              |  slave[1..] = DMA[j] x N   |
                                              +-----------------------------+
                                                         |
                                              m_axi[0..7] (NUM_HBM_MAS_PORTS)
                                                         |
                                                    +---------+
                                                    |  HMSS   |
                                                    | (32 PC) |
                                                    +---------+
```

**LSU AXI path** (VX_axi_adapter → axi_demux → axi_mux → m_axi):
1. VX_axi_adapter splits interleaved word addr: `bank_sel = word_addr[2:0]`, `bank_addr = word_addr >> 3`
2. Routes request to port `bank_sel`
3. Reconstructs AXI byte addr: `(bank_addr << 9) | (bank_sel << 6)` **= original SW byte addr**
4. axi_demux uses `addr[8:6]` for routing (same as bank_sel) — identity

**DMA AXI path** (each DMA ch has its own AXI port, enters axi_mux directly):
- DMA ch j → `axi_mux[j].slave[1+core_id]` → `m_axi[j]`
- The axi_mux routes by address: `addr[8:6]` selects master port
- **DMA must produce AXI addresses where `addr[8:6] == j`** to stay on port j

**AXI address constraint** (INTERLEAVE mode):
All AXI requests on port j must satisfy: `axi_addr = 512*n + 64*j` for some integer n.
This is the natural interleaved address pattern and is automatically satisfied by VX_axi_adapter.

### 2.5 GEMM Control Flow

```
SW kernel (MMIO writes) -> Job Frontend -> CMD Constructor
  -> GEMM Ctrl (MXU commands: load weight/input/qparam, store output)
  -> GEMM DMA Ctrl (DMA commands: load/store, 8-channel decomposition)
  -> GEMM Sync (wait/notify between DMA and MXU)
```

- **CMD Constructor**: MMIO registers -> unified command struct (`gemm_unified_cmd_t`)
- **GEMM Ctrl**: Executes MXU commands (load weight/input/qparam, store output) from the instruction stream. Does not compute tiling — SW pre-computes all tile addresses and emits commands.
- **GEMM DMA Ctrl**: Decomposes SW interleaved CMD into 8-channel configs -> DMA config registers
- **GEMM Sync**: Barrier-style synchronization (wait/notify/clear)

### 2.6 HBM / HMSS

- Xilinx U55C: 2 HBM stacks, 16 channels, 32 pseudo-channels (PC)
- HMSS (Xilinx IP): 32 AXI3 slave ports
  - **Default address map: contiguous** (PC0=0~512MB, PC1=512MB~1GB, ...)
  - Vortex uses `NUM_HBM_MAS_PORTS=8` AXI master ports → HMSS 8:32 interconnection
  - `PLATFORM_MEMORY_NUM_BANKS=32` — how many PCs the SW runtime uses for allocation
- For real FPGA: HMSS switch routes each AXI port to its assigned PCs based on contiguous address map
- For simulation: xrt_sim_vcs passes AXI address through to flat RAM directly (see section 4.8)

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
**DMA command addresses are byte addresses and may be sub-64B misaligned.**

```
NUM_TMEM_BANKS = 8, DATA_SIZE = 64B

Word address -> bank mapping:
  word_addr[2:0] = bank_id
  word_addr[...:3] = bank_local_addr

Byte address -> bank mapping:
  bank_id = (byte_addr / 64) % 8
  bank_local_byte_offset = (byte_addr / 512) * 64 + (byte_addr % 64)

Equivalent bit form:
  byte_addr[5:0]   = byte offset within one 64B bank line
  byte_addr[8:6]   = bank_id
  byte_addr[63:9]  = bank-local line index

  bank_local_byte_addr = ((byte_addr >> 9) << 6) | byte_addr[5:0]

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

As long as `hbm_addr % 512 == tmem_addr % 512`, the corresponding 64B block falls on the same channel N, so the 1:1 DMA path can handle the transfer. HBM and TMEM addresses do not need to be equal.

This equality is byte-granular. In particular, the low 6 bits are part of the
constraint and must be preserved through TMEM bank-local address conversion.

### 4.4 gemm_dma_ctrl 8-Channel Decomposition

**SW sends DMA CMDs in interleaved TMEM address space.**
**HW (`gemm_dma_ctrl`) decomposes these into 8 per-channel configs** and programs each DMA channel.

Each DMA channel has two address spaces:
- **HBM side (AXI)**: original SW interleaved address (INTERLEAVE mode, identity — see section 4.7)
- **TMEM side (membus)**: bank-local address (connects directly to bank N, no switch)

#### Decomposition rules

```
SW CMD (DMA_LOAD): src=HBM(interleaved), dst=TMEM(interleaved), stride, bound, seg_size
NUM_PORTS = NUM_HBM_MAS_PORTS (= 8)

num_words = seg_size / 64                    // total 64B bus words
start_ch = (src_base / 64) % NUM_PORTS       // must equal (dst_base / 64) % NUM_PORTS
words_per_logical_ch[i] = num_words / NUM_PORTS     // +1 for i < (num_words % NUM_PORTS)

For each physical channel ch (0..7):
  Block k at SW addr src_base + k*64 goes to port (src_base/64 + k) % 8.
  ch gets blocks where port == ch.
  Equivalently, logical stripe i is assigned to physical channel:
    ch = (start_ch + i) % NUM_PORTS

  HBM side (INTERLEAVE — use original SW interleaved addr):
    ch_src_base = src_base + i * 64          // first block for logical stripe i
    ch_src_stride = 512                      // next block for same port = 8 blocks away
    ch_src_seg_size = 64                     // one 64B block per segment

  TMEM side (bank-local):
    ch_dst_base = ((dst_base >> 9) << 6) | (dst_base & 6'h3f)
    ch_dst_stride = 64                       // contiguous in bank-local space
    ch_dst_seg_size = 64

  ch_bound = words_per_logical_ch[i]         // number of blocks this channel handles
  ch_dir = 0 (G2L)

  If words_per_logical_ch[i] == 0: channel inactive (don't program)
```

For `DMA_STORE`, the same rule applies with HBM/TMEM roles swapped:
- HBM side remains original SW interleaved byte address
- TMEM side uses bank-local byte address with low 6 bits preserved
- starting physical channel is determined by `(src_base / 64) % NUM_PORTS`

#### Worked example: DMA_LOAD 4096 bytes (64 blocks)

```
SW CMD: src_base=0x10000(HBM), dst_base=0x4000(TMEM), seg_size=4096, stride=0, bound=1
num_words = 64, words_per_ch = 64/8 = 8 (all channels active)

Channel 0 (port 0): blocks where (0x10000/64 + k) % 8 == 0, i.e. k=0,8,16,...,56
  HBM reads:  0x10000, 0x10200, 0x10400, ..., 0x10E00 (stride=512)
              addr[8:6] = 0 for all → axi_demux routes to port 0 ✓
  TMEM writes: bank 0, local addrs 0x800, 0x840, ..., 0x9C0 (stride=64)

Channel 1 (port 1): blocks k=1,9,17,...,57
  HBM reads:  0x10040, 0x10240, 0x10440, ..., 0x10E40 (stride=512)
              addr[8:6] = 1 for all → axi_demux routes to port 1 ✓
  TMEM writes: bank 1, local addrs 0x800, 0x840, ...

...same pattern for ch 2-7...
```

#### Worked example: DMA_LOAD 256 bytes (4 blocks, scale data)

```
SW CMD: src_base=0x10000(HBM), dst_base=0x8000(TMEM), seg_size=256, stride=0, bound=1
num_words = 4, words_per_ch: ch 0-3 get 1 block, ch 4-7 inactive

Channel 0: HBM read at 0x10000 (port 0) → TMEM bank 0 local addr 0x1000
Channel 1: HBM read at 0x10040 (port 1) → TMEM bank 1 local addr 0x1000
Channel 2: HBM read at 0x10080 (port 2) → TMEM bank 2 local addr 0x1000
Channel 3: HBM read at 0x100C0 (port 3) → TMEM bank 3 local addr 0x1000
Channel 4-7: inactive (no blocks assigned)
```

**Each DMA channel writes to its TMEM bank using bank-local addresses. No switch involved.**
**Each DMA channel reads from HBM using original SW interleaved addresses. axi_demux routes by addr[8:6].**

### 4.5 Local DMA -> TMEM (Via Switch)

Local DMA uses interleaved addresses -> `VX_tmem_switch` selects bank via `addr[2:0]` and converts upper bits to bank-local address.

Since SW computes all addresses in interleaved space from the start, addresses passed to local DMA are already interleaved.

### 4.6 TMEM <-> MXU Address Alignment

The following constraints apply to MXU-facing local DMA traffic and TMEM layouts
used by GEMM compute. They are **not** a restriction on external DMA commands.
External DMA must support byte-misaligned HBM/TMEM base and stride values as
long as the 1:1 mapping constraint in section 4.3 is satisfied.

```
input:      base_addr(input[x, 32y+:32]) % 64 == 0
weight:     base_addr(weight[4x+:4, 32y+:32]) % 64 == 0
output:     base_addr(output[x, 32y+:32]) % 64 == 0
scale/zp:   base_addr(scale[x, 32y+:32]) % 64 == 0  (qdir==0)
            base_addr(scale[32x+:32, y]) % 64 == 0  (qdir==1)
```

### 4.7 AXI Address Format (INTERLEAVE Mode)

DMA는 INTERLEAVE 모드만 사용한다 (INTERLEAVE=0 contiguous 모드는 DMA에 해당 없음).

VX_axi_adapter (LSU path, INTERLEAVE=1)의 주소 변환:
```
input:  word_addr (interleaved, 64B word 단위)
split:  bank_sel = word_addr[2:0], bank_addr = word_addr >> 3
output: m_axi_addr[bank_sel] = (bank_addr << 9) | (bank_sel << 6)
                              = word_addr * 64
                              = original SW byte addr  (identity)
```

kernel에서는 HBM의 PC가 interleaving address를 사용한다고 생각하고 작성한다. 그렇기 때문에 address가 sequential한 부분을 접근하면 그 request가 여러 PC에
병렬적으로 간다고 생각하고 작성할 것이다. INTERLEAVE 모드에서는 AXI output이 원본 SW interleaved 주소 그대로이며, `axi_demux`가 `addr[8:6]`로 port를 선택한다.

#### HMSS Hard Constraint (Real FPGA)

Xilinx HMSS는 각 PC가 contiguous address map을 가진다고 가정하고 switch routing이 구현되어 있다. 따라서 **실제 FPGA에서는 HW가 interleaved→contiguous 변환을 해야 한다.**

예를 들어 kernel이 주소 64~128를 접근하고 싶어서 DMA CMD를 생성할 때 base address를 64로 넣고 segment size를 64로 했다면, kernel 입장에서는 PC1에 접근하고 싶었던 것이기 때문에 DMA engine에서는 이걸 port 1에 할당하고 주소를 contiguous address map 버전으로 바꿔야 한다: `0x2000_0000 ~ 0x2000_0000+64`.

```
Contiguous conversion formula:
  Given SW interleaved byte address A:
    block_idx    = A / 64
    pc_id        = block_idx % PLATFORM_MEMORY_NUM_BANKS   // e.g., % 32
    block_in_pc  = block_idx / PLATFORM_MEMORY_NUM_BANKS
    port_id      = pc_id / (PLATFORM_MEMORY_NUM_BANKS / NUM_HBM_MAS_PORTS)  // e.g., pc_id / 4
    AXI addr     = pc_id * PC_SIZE + block_in_pc * 64      // PC_SIZE = 512MB

  SW addr 0   → pc_id=0,  port=0, AXI = 0x0000_0000
  SW addr 64  → pc_id=1,  port=0, AXI = 0x2000_0000
  SW addr 2048→ pc_id=0,  port=0, AXI = 0x0000_0040 (PC0, 2nd block)
```

VX_axi_adapter는 `INTERLEAVE=1` 모드에서 identity로 동작한다. DMA engine의 HBM side도 동일하게 identity로 동작해야 한다.

**AXI address constraint on port j (INTERLEAVE=1)**:
```
axi_addr = 512 * n + 64 * j     for integer n >= 0
```
Port j only sees addresses where `(addr / 64) % NUM_HBM_MAS_PORTS == j`.

```
Worked example — SW addresses 0x10000 ~ 0x10200:

  SW addr  | port j=(A/64)%8 | AXI addr on port j
  ---------+-----------------+--------------------
  0x10000  | 0               | 0x10000
  0x10040  | 1               | 0x10040
  0x10080  | 2               | 0x10080
  ...
  0x101C0  | 7               | 0x101C0
  0x10200  | 0               | 0x10200 (다시 port 0)
```

**Both LSU and DMA must produce AXI addresses in this interleaved format.**
LSU path: VX_axi_adapter (INTERLEAVE=1) handles this automatically.
DMA path: gemm_dma_ctrl assigns each channel's HBM addresses as original SW interleaved addresses.

### 4.8 Simulation Memory Model (xrt_sim_vcs)

**Architecture**: RTL AXI ports → TB DPI-C bridge → Host C++ (`xrt_sim_vcs.cpp`) → `ram_` (data) + `dram_sim_` (timing)

- `ram_`: flat byte array, stores actual data (functional model)
- `dram_sim_` (ramulator): HBM2 timing model only, no data storage

**xrt_sim_vcs passes AXI addresses through to RAM without translation.**

```
RTL AXI port j sends addr A
  → TB captures (port_idx=j, addr=A)
  → DPI-C sends to host
  → host: ram_->read(data, A, 64)  or  ram_->write(data, A, 64)
     (A is used as-is — no to_software_addr conversion needed)
  → dram_sim_.send_request(A, ...)  (timing only)
```

The `to_software_addr` function in xrt_sim_vcs.cpp should be removed. The simulator's role is to pass AXI addresses directly to RAM/ramulator.

**Address constraint check on port j**:
```
assert( (addr / 64) % NUM_HBM_MAS_PORTS == j )  // addr = 512*n + 64*j
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

### 6.4 Instruction Opcodes (GEMM Command)

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

### 6.5 Tiling and Double Buffering

```
MT = 128, NT = 128, KT = 128      (DMA tile)
MXU_KT = 32, MXU_NT = 32          (MXU tile)
```

Two levels of double buffering:
1. **DMA-tile level:** buf0/buf1 alternation for input, weight, scale/zp
2. **MXU-tile level:** weight/scale_zp register alternation within one DMA tile

### 6.6 Constraints

- M, N: multiples of 32 (MXU_NT)
- K: multiple of 32 (MXU_KT)
- QBLK: power of 2, divides K (QDIR_COL)
- QDIR_ROW: QBLK == N
- KT % QBLK == 0 (QDIR_COL)
- N must be even (int4 packing)

### 6.7 PyTorch Integration

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
| `VX_gemm_tmem_dma_ctrl` | `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv` | 8-channel decomposition. TMEM side: bank-local addr. HBM side: original interleaved addr (per-channel offset, stride=512). Bus-word granularity (handles seg_size < 512B). |
| `VX_gemm_node` | `hw/rtl/core/gemm/VX_gemm_node.sv` | Remove LMEM path. Instantiate VX_tmem_subsystem. Expose DMA AXI ports. |
| `VX_tmem_subsystem` | `hw/rtl/mem/VX_tmem_subsystem.sv` | Change DMA ch N -> bank N direct (currently ch0-only via switch -> 8ch 1:1 direct). |
| `VX_core` | `hw/rtl/core/VX_core.sv` | Add `AXI_BUS.Master dma_axi[8]` port. |
| `VX_lmem_switch` | `hw/rtl/mem/VX_lmem_switch.sv` | Remove GEMM path. LSU-only. |

### 7.3 Third-party (from third_party/axi)

`AXI_BUS`, `axi_from_mem`, `axi_mux`, `axi_demux`, `axi_pkg`, `axi/typedef.svh`, `axi/assign.svh`

---

## 8. Constraints & Assumptions

1. **DMA ch N -> TMEM bank N: 1:1 direct** — TMEM side uses bank-local addresses, bypasses switches.
2. **DMA ch N -> HBM via AXI mux: interleaved addresses (INTERLEAVE mode only)** — HBM side uses original SW interleaved addresses. `axi_demux` routes by `addr[8:6]` to correct HBM port.
3. **AXI address constraint (INTERLEAVE mode)**: port j only sees `addr = 512*n + 64*j`. Both LSU (via VX_axi_adapter INTERLEAVE=1) and DMA (via gemm_dma_ctrl) must produce addresses satisfying this.
4. **Local DMA accesses TMEM via switch using interleaved addresses** — switch handles bank selection and address conversion.
5. **SW always thinks in interleaved address space** — gemm_dma_ctrl performs per-channel decomposition in HW.
6. **TMEM is GEMM-only**, LMEM is LSU-only.
7. **512-bit data width** unified across DMA, TMEM, and switches.
8. **GEMM unit ports are 64B `VX_mem_bus_if`**.
9. **DMA AXI ports bypass cache** — connect directly to AXI mux per port.
10. **TMEM bank is 1-port**: VX_sp_ram + 5:1 arbiter.
11. **DMA is SW-controlled**: stride, bound come from CMD. HW does not compute tiling (only channel decomposition).
12. **Naming**: `NUM_HBM_MAS_PORTS` (=8) = number of AXI master ports to HMSS. Not `NUM_BANKS` (confusing with `PLATFORM_MEMORY_NUM_BANKS`=32 PCs).
13. **xrt_sim_vcs**: no address translation on AXI path. Passes AXI addr directly to flat RAM. Checks port constraint `(addr/64) % 8 == port_idx`.

---

## 9. Key Files

| File | Role |
|------|------|
| `hw/rtl/core/gemm/VX_gemm_node.sv` | GEMM node top (MXU + TMEM subsystem) |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv` | DMA command decode + 8-channel decomposition |
| `hw/rtl/core/gemm/VX_gemm_ctrl.sv` | MXU command execution FSM |
| `hw/rtl/core/gemm/VX_cmd_constructor.sv` | MMIO -> unified command |
| `hw/rtl/core/gemm/VX_gemm_sync.sv` | Wait/notify synchronization |
| `hw/rtl/mem/VX_dma_engine.sv` | 8-channel DMA engine |
| `hw/rtl/mem/VX_tmem_subsystem.sv` | TMEM banks + switches + DMA wiring |
| `hw/rtl/mem/VX_tmem_switch.sv` | Interleaved address -> bank routing |
| `hw/rtl/mem/VX_tensor_mem_bank.sv` | Single TMEM bank |
| `hw/rtl/core/VX_dma_unit_misal.sv` | 3D strided DMA FSM |
| `tests/regression/fpint_gemm_ffn_hw_improve/` | HW FSM test (host + kernel) |
| `tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp` | ISA-level instruction stream reference |
| `pytorch/csrc/aten/VortexExtra.cpp` | PyTorch custom op |
