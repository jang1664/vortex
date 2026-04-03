# Bandwidth Analysis: Cache System & TCU Register Access

This document analyzes the memory bandwidth characteristics of the Vortex GPU under the following configuration:

```
CONFIGS = "-DDCACHE_DISABLE -DL2_ENABLE -DNUM_THREADS=8 -DLMEM_LOG_SIZE=22 -DSTACK_BASE_ADDR=64'h1FFC00000"
```

## Configuration Summary

| Parameter | Value | Description |
|-----------|-------|-------------|
| `DCACHE_DISABLE` | defined | Data cache bypassed |
| `L2_ENABLE` | defined | L2 cache enabled |
| `NUM_THREADS` | 8 | Threads per warp |
| `LMEM_LOG_SIZE` | 22 | Local memory = 4 MB |
| `STACK_BASE_ADDR` | 64'h1FFC00000 | Stack/LMEM base address |

### Derived Base Parameters

| Parameter | Value | Source |
|-----------|-------|--------|
| `XLEN` | 64 | RV64 |
| `NUM_CORES` | 1 | Default |
| `NUM_CLUSTERS` | 1 | Default |
| `SOCKET_SIZE` | 1 | `MIN(4, NUM_CORES)` |
| `NUM_SOCKETS` | 1 | `NUM_CORES / SOCKET_SIZE` |
| `SIMD_WIDTH` | 8 | `= NUM_THREADS` |
| `NUM_LSU_LANES` | 8 | `= SIMD_WIDTH` |
| `NUM_LSU_BLOCKS` | 1 | Default |
| `ISSUE_WIDTH` | 1 | `UP(NUM_WARPS / 16)` |

---

## 1. Cache System Bandwidth

### 1.1 DCACHE (Disabled — Bypass Mode)

With `DCACHE_DISABLE`, the data cache is bypassed. Requests pass through directly without caching.

| Parameter | Value | Derivation |
|-----------|-------|------------|
| `LSU_WORD_SIZE` | 8 bytes | `XLEN / 8` |
| `LSU_LINE_SIZE` | 64 bytes | `MIN(NUM_LSU_LANES × LSU_WORD_SIZE, L1_LINE_SIZE)` = MIN(64, 64) |
| `DCACHE_WORD_SIZE` | 64 bytes | `= LSU_LINE_SIZE` |
| `DCACHE_CHANNELS` | 1 | `UP((8 × 8) / 64)` |
| `DCACHE_NUM_REQS` | 1 | `NUM_LSU_BLOCKS × DCACHE_CHANNELS` |
| `DCACHE_NUM_BANKS` | 1 | Forced by `DCACHE_DISABLE` |
| `NUM_DCACHES` | 0 | Forced by `DCACHE_DISABLE` |

Reference: `VX_config.vh:591-594`, `VX_gpu_pkg.sv:944-952`

### 1.2 L1 Memory Ports

`L1_DISABLE` is **not** defined (only `DCACHE_DISABLE` is set), so:

```
L1_MEM_PORTS = MIN(DCACHE_NUM_BANKS, PLATFORM_MEMORY_NUM_BANKS) = MIN(1, 2) = 1
```

Reference: `VX_config.vh:652-658`

### 1.3 L2 Cache (Enabled)

| Parameter | Value | Derivation |
|-----------|-------|------------|
| `L2_NUM_REQS` | 1 | `NUM_SOCKETS(1) × L1_MEM_PORTS(1)` |
| `L2_NUM_BANKS` | 1 | `MIN(L2_NUM_REQS, 16)` |
| `L2_MEM_PORTS` | 1 | `MIN(L2_NUM_BANKS, PLATFORM_MEMORY_NUM_BANKS)` = MIN(1, 2) |
| `L2_CACHE_SIZE` | 1 MB | Default |
| `L2_LINE_SIZE` | 64 bytes | `= MEM_BLOCK_SIZE` |
| `L2_NUM_WAYS` | 8 | Default |
| `L2_MSHR_SIZE` | 16 | Max concurrent miss handling |

Reference: `VX_config.vh:678-734`, `VX_gpu_pkg.sv:986-1002`

### 1.4 LMEM (Local Memory)

| Parameter | Value | Derivation |
|-----------|-------|------------|
| `LMEM_NUM_BANKS` | 8 | `= NUM_LSU_LANES` |
| LMEM Size | 4 MB | `2^22` bytes |

Reference: `VX_config.vh:670-673`

### 1.5 External Memory Interface

| Parameter | Value |
|-----------|-------|
| `PLATFORM_MEMORY_NUM_BANKS` | 2 |
| `PLATFORM_MEMORY_DATA_SIZE` | 64 bytes (512 bits) |

Reference: `VX_config.vh:170-184`

### 1.6 Bank & Port Summary

| Level | Banks | Memory Ports | Notes |
|-------|-------|--------------|-------|
| **DCACHE** | 0 (disabled) | — | Bypass mode |
| **L2** | **1** | **1** | Bottleneck: single requester from L1 |
| **LMEM** | **8** | 8 (LSU lanes) | Full parallel access for 8 threads |
| **External Memory** | 2 | 1 (from L2) | L2_MEM_PORTS = 1 |

### 1.7 Cache Bandwidth per Cycle

| Path | Bandwidth / Cycle | Bottleneck |
|------|-------------------|------------|
| LSU → LMEM | 8 banks × 8 bytes = **512 bits** | No (full parallel) |
| L1 bypass → L2 | 1 port × 64 bytes = **512 bits** | **Yes** (single port) |
| L2 → External Memory | 1 port × 64 bytes = **512 bits** | **Yes** (single port) |

The primary bandwidth bottleneck is `L1_MEM_PORTS = 1`, caused by `DCACHE_NUM_BANKS` being forced to 1 when `DCACHE_DISABLE` is set. This serializes all L1-to-L2 traffic through a single port.

---

## 2. TCU Register File Bandwidth

### 2.1 TCU Tile Dimensions (NUM_THREADS=8)

The TCU computes WMMA (Warp Matrix Multiply-Accumulate) operations by decomposing a tile into micro-ops.

**Tile dimensions** (full WMMA operation):

| Parameter | Computation | Value |
|-----------|-------------|-------|
| `TCU_NT` | `NUM_THREADS` | 8 |
| `TCU_NR` | constant | 8 |
| `TCU_TILE_CAP` | 8 × 8 | 64 elements |
| `TCU_TILE_M` | `1 << 3` | **8** |
| `TCU_TILE_N` | `1 << 3` | **8** |
| `TCU_TILE_K` | `64 / max(8, 8)` | **8** |

One WMMA instruction computes: **C[8×8] = A[8×8] · B[8×8] + C[8×8]**

Reference: `VX_tcu_pkg.sv:39-46`

**Block dimensions** (hardware micro-op granularity):

| Parameter | Computation | Value |
|-----------|-------------|-------|
| `TCU_BLOCK_CAP` | `TCU_NT` | 8 |
| `TCU_TC_M` | `1 << 2` | **4** |
| `TCU_TC_N` | `1 << 1` | **2** |
| `TCU_TC_K` | `8 / max(4, 2)` | **2** |

Reference: `VX_tcu_pkg.sv:49-56`

**Micro-op decomposition:**

| Parameter | Computation | Value |
|-----------|-------------|-------|
| `TCU_M_STEPS` | `8 / 4` | 2 |
| `TCU_N_STEPS` | `8 / 2` | 4 |
| `TCU_K_STEPS` | `8 / 2` | 4 |
| **`TCU_UOPS`** | `2 × 4 × 4` | **32 micro-ops / WMMA** |

Reference: `VX_tcu_pkg.sv:59-81`

### 2.2 Register File Architecture (NUM_THREADS=8)

| Parameter | Value | Source |
|-----------|-------|--------|
| `XLEN` | 64 bits | RV64 |
| `SIMD_WIDTH` | 8 | `= NUM_THREADS` |
| `NUM_TCU_LANES` | 8 | `= NUM_THREADS` |
| `NUM_GPR_BANKS` | 4 | Default |
| Read ports (`NUM_SRC_OPDS`) | 3 (rs1, rs2, rs3) | `VX_opc_unit.sv:59` |
| Write ports | 1 | `VX_opc_unit.sv:35` |
| Read latency | 2 cycles | Pipeline stages in `VX_opc_unit.sv` |

**Per-port data width:**

```
BANK_DATA_WIDTH = XLEN × SIMD_WIDTH = 64 × 8 = 512 bits (64 bytes)
```

Reference: `VX_opc_unit.sv:44`, `VX_config.vh:353-354`

### 2.3 Register Bandwidth per Cycle

| Direction | Ports | Width / Port | **Bandwidth / Cycle** |
|-----------|-------|--------------|----------------------|
| **Read** | 3 | 512 bits | **1,536 bits (192 bytes)** |
| **Write** | 1 | 512 bits | **512 bits (64 bytes)** |
| **Total** | 4 | — | **2,048 bits (256 bytes)** |

> **Bank conflict note:** The 4-bank register file serves 3 read requests per cycle via a crossbar arbiter. When multiple requests target the same bank, stalls occur. Best case: all 3 requests hit different banks → 1 cycle. Worst case: all hit the same bank → 3 cycles.

### 2.4 TCU per Micro-op Register Access

Each micro-op reads 3 operands and writes 1 result through the operand collector:

| Operand | Role | Size |
|---------|------|------|
| `rs1_data` | A matrix row | 8 lanes × 64 bits = **512 bits** |
| `rs2_data` | B matrix column | 8 lanes × 64 bits = **512 bits** |
| `rs3_data` | C accumulator | 8 lanes × 64 bits = **512 bits** |
| `rd` (write) | D result | 8 lanes × 64 bits = **512 bits** |

**Per micro-op: 1,536 bits read + 512 bits write = 2,048 bits**

Reference: `VX_tcu_fp.sv:127-129`

### 2.5 WMMA Total Register Traffic

| | Computation | Value |
|---|-------------|-------|
| Read total | 32 uops × 1,536 bits | **49,152 bits (6,144 bytes)** |
| Write total | 32 uops × 512 bits | **16,384 bits (2,048 bytes)** |
| **WMMA total** | | **65,536 bits (8,192 bytes = 8 KB)** |
| **Minimum latency** | 32 uops (no bank conflicts) | **32 cycles** |

---

## 3. End-to-End Data Path Summary

```
                        1536 b/cyc read
  Register File (4 banks) ─────────────▶  TCU (8 lanes, 4×2 TC block)
                          ◀─────────────
                         512 b/cyc write

                         512 b/cyc
  Register File ◀────────────────────▶  LSU (8 lanes)
                                          │
                         512 b/cyc        ▼
  LMEM (8 banks, 4 MB)  ◀────────────▶  LSU
                                          │
                         512 b/cyc        ▼
  L2 Cache (1 bank, 1 MB) ◀──────────▶  L1 bypass (1 port)
                                          │
                         512 b/cyc        ▼
  External Memory (2 banks) ◀─────────▶  L2 (1 port)
```

### Bandwidth Comparison

| Path | Bandwidth / Cycle | Relative |
|------|-------------------|----------|
| Register → TCU (read) | 1,536 bits | 3× |
| TCU → Register (write) | 512 bits | 1× |
| Register ↔ LMEM (via LSU) | 512 bits | 1× |
| LMEM ↔ L2 | 512 bits | 1× |
| L2 ↔ External Memory | 512 bits | 1× |

### Key Observations

1. **Register read bandwidth (1,536 bits/cycle)** is the widest path in the system, enabled by the 3-port operand collector design.
2. **L1 → L2 single port** is the primary memory-side bottleneck. `DCACHE_DISABLE` forces `DCACHE_NUM_BANKS=1`, limiting `L1_MEM_PORTS` to 1.
3. **LMEM (8 banks)** provides bank-conflict-free parallel access for all 8 threads, making it the preferred high-bandwidth data store for TCU operands.
4. **TCU computation** requires 32 cycles per WMMA (8×8×8 tile), moving 8 KB through the register file. The register bandwidth is sufficient to sustain one micro-op per cycle when bank conflicts are avoided.
5. **Data staging strategy:** To maximize TCU throughput, operand data should be staged in LMEM (8-bank parallel access) and loaded into registers before TCU execution, avoiding the L2 single-port bottleneck during computation.

---

## 4. SIMD Execution Unit Throughput Analysis

This section analyzes ALU, FPU, and TCU throughput using parametric variables first, then substitutes the concrete configuration values.

### 4.1 Parametric Model

#### Execution Unit Sizing

Each unit has **lanes** (parallel ALUs/FPUs per block) and **blocks** (independent issue slots).

| Unit | Lanes | Blocks | Source |
|------|-------|--------|--------|
| ALU (INT) | `NUM_ALU_LANES` = `SIMD_WIDTH` | `NUM_ALU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:362-365` |
| FPU (FP) | `NUM_FPU_LANES` = `SIMD_WIDTH` | `NUM_FPU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:370-373` |
| TCU | `NUM_TCU_LANES` = `NUM_THREADS` | `NUM_TCU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:399-401` |
| LSU | `NUM_LSU_LANES` = `SIMD_WIDTH` | `NUM_LSU_BLOCKS` = 1 | `VX_config.vh:378-381` |

Derived:
```
SIMD_WIDTH  = NUM_THREADS
ISSUE_WIDTH = UP(NUM_WARPS / 16)
```

#### ALU Throughput per Operation Type

The ALU has two sub-units: `VX_alu_int` (basic arithmetic) and `VX_alu_muldiv` (multiply/divide).

| Operation | Implementation | Pipeline? | Latency | Throughput (instr/cycle/block) |
|-----------|---------------|-----------|---------|-------------------------------|
| ADD/SUB, AND/OR/XOR, SLL/SRL/SRA | Combinatorial (`VX_alu_int.sv`) | Single-cycle | 1 cycle | **1** |
| Branch (BEQ, BLT, ...) | Combinatorial + buffer | 1 cycle | **1** |
| MUL/MULH | Pipelined shift register (`VX_alu_muldiv.sv:81`) | Yes | `LATENCY_IMUL` cycles | **1** |
| DIV/REM | Serial divider (`VX_serial_div`) | No (blocking) | ~`XLEN` cycles | **1/XLEN** |

- **MUL is fully pipelined**: `VX_shift_register` with `DEPTH=LATENCY_IMUL`. Accepts new instruction every cycle despite multi-cycle latency.
- **DIV is serial**: blocks the unit for ~`XLEN` cycles per instruction.

**ALU operations per cycle per block (all lanes fire in parallel):**
```
Throughput_ALU_arith = NUM_ALU_LANES × 1 op/cycle                      (ADD, SUB, logic, shift)
Throughput_ALU_mul   = NUM_ALU_LANES × 1 op/cycle  (pipelined)         (MUL, MULH)
Throughput_ALU_div   = NUM_ALU_LANES × (1/XLEN) op/cycle  (serial)    (DIV, REM)
```

Reference: `VX_platform.vh:186-198`, `VX_alu_muldiv.sv:81-93`

#### FPU Throughput per Operation Type

The FPU uses `VX_pe_serializer` to share physical PEs across SIMD lanes. `PE_RATIO` controls how many lanes share one PE.

```
NUM_PEs = UP(NUM_FPU_LANES / PE_RATIO)
BATCH_SIZE = NUM_FPU_LANES / NUM_PEs
```

- When `PE_RATIO = 1`: `NUM_PEs = NUM_FPU_LANES` → passthrough (no serialization)
- When `PE_RATIO > 1`: `NUM_PEs < NUM_FPU_LANES` → serialized in `BATCH_SIZE` batches

| Operation | Latency | PE_RATIO | NUM_PEs | BATCH_SIZE | Instr Throughput |
|-----------|---------|----------|---------|------------|------------------|
| FMA (FADD/FMUL/FMADD) | `LATENCY_FMA` | `FMA_PE_RATIO` = 1 | `NUM_FPU_LANES` | 1 | **1 instr/cycle** |
| FDIV | `LATENCY_FDIV` | `FDIV_PE_RATIO` = 8 | `UP(NUM_FPU_LANES/8)` | `NUM_FPU_LANES / NUM_PEs` | **1 / BATCH_SIZE instr/cycle** |
| FSQRT | `LATENCY_FSQRT` | `FSQRT_PE_RATIO` = 8 | `UP(NUM_FPU_LANES/8)` | same | **1 / BATCH_SIZE instr/cycle** |
| FCVT | `LATENCY_FCVT` | `FCVT_PE_RATIO` = 8 | `UP(NUM_FPU_LANES/8)` | same | **1 / BATCH_SIZE instr/cycle** |
| FNCP (misc) | `LATENCY_FNCP` | `FNCP_PE_RATIO` = 2 | `UP(NUM_FPU_LANES/2)` | 2 | **1/2 instr/cycle** |

**FMA is the critical path for GEMM.** With `PE_RATIO=1`, every lane has its own FMA PE → fully pipelined, 1 instruction/cycle.

**FP operations per cycle per block:**
```
Throughput_FMA   = NUM_FPU_LANES × 2 FLOPs/lane × 1 instr/cycle   (FMA = 1 MUL + 1 ADD)
Throughput_FDIV  = NUM_PEs_div × 1 FLOP/lane × (1/LATENCY_FDIV) instr/cycle
```

Reference: `VX_config.vh:504-527`, `VX_fpu_fma.sv:20`, `VX_pe_serializer.sv:82-139`

#### TCU Throughput

Each micro-op computes a `TCU_TC_M × TCU_TC_N` output block with `TCU_TC_K`-deep dot products.

```
MACs_per_uop = TCU_TC_M × TCU_TC_N × TCU_TC_K
MACs_per_WMMA = TCU_TILE_M × TCU_TILE_N × TCU_TILE_K
                = TCU_UOPS × MACs_per_uop
Cycles_per_WMMA = TCU_UOPS  (1 uop/cycle)
```

#### Issue Dispatch Model

ALU, FPU, LSU, TCU have **independent dispatch slots** (`VX_issue_top.sv`). They can issue simultaneously in the same cycle.

```
Max concurrent issues = NUM_EX_UNITS × ISSUE_WIDTH
                      = 5 × ISSUE_WIDTH  (ALU, LSU, SFU, FPU, TCU)
```

However, all share the **same operand collector** (`VX_opc_unit.sv`), which has:
- 3 read ports, 1 write port
- `NUM_GPR_BANKS` = 4 register file banks
- Only 1 operand set fetched per cycle per OPC

So the **operand collector is the true issue bottleneck**: 1 instruction dispatched per cycle per OPC, even though execution units could accept more.

### 4.2 Concrete Values (NUM_THREADS=8, XLEN=64)

Substituting the configuration:

```
SIMD_WIDTH     = NUM_THREADS    = 8
ISSUE_WIDTH    = UP(4 / 16)     = 1
NUM_ALU_LANES  = 8
NUM_FPU_LANES  = 8
NUM_TCU_LANES  = 8
NUM_GPR_BANKS  = 4
LATENCY_IMUL   = 3  (Quartus/Vivado)
LATENCY_FMA    = 4  (DPI/FPNEW)  or 16 (Vivado DSP)
LATENCY_FDIV   = 15 (DPI) / 16 (FPNEW) / 28 (Vivado)
LATENCY_FSQRT  = 10 (DPI) / 16 (FPNEW) / 28 (Vivado)
LATENCY_FCVT   = 5
LATENCY_FNCP   = 2
```

#### ALU Throughput (concrete)

| Operation | Lanes | Latency | Pipeline | Ops/cycle (all lanes) |
|-----------|-------|---------|----------|-----------------------|
| ADD/SUB/logic/shift | 8 | 1 cycle | Yes | **8 ops** |
| MUL/MULH | 8 | 3 cycles | Yes (pipelined) | **8 ops** |
| DIV/REM | 8 | ~64 cycles | No (serial) | **8 / 64 ≈ 0.125 ops** |

#### FPU Throughput (concrete)

| Operation | NUM_PEs | BATCH_SIZE | Latency | Throughput (ops/cycle, all lanes) |
|-----------|---------|------------|---------|-----------------------------------|
| **FMA/FADD/FMUL** | 8 | 1 (passthru) | 4 cycles | **8 ops (= 16 FLOPs)** |
| FDIV | UP(8/8) = 1 | 8 | 15 cycles | **8 / 8 = 1 op** per 1 instr |
| FSQRT | UP(8/8) = 1 | 8 | 10 cycles | **1 op** per instruction |
| FCVT | UP(8/8) = 1 | 8 | 5 cycles | **1 op** per instruction |
| FNCP | UP(8/2) = 4 | 2 | 2 cycles | **4 ops** per instruction |

> **Note:** For FDIV/FSQRT/FCVT, a single instruction covers all 8 lanes but is serialized internally over `BATCH_SIZE=8` cycles through 1 PE. Throughput shown is per-PE per cycle.

#### TCU Throughput (concrete, NUM_THREADS=8)

| Parameter | Value |
|-----------|-------|
| TCU_TC_M × TCU_TC_N × TCU_TC_K | 4 × 2 × 2 |
| MACs per micro-op | 4 × 2 × 2 = **16 MACs** |
| TCU_UOPS per WMMA | 32 |
| MACs per WMMA | 8 × 8 × 8 = **512 MACs** |
| Cycles per WMMA | 32 cycles |
| **MACs / cycle** | 512 / 32 = **16 MACs/cycle** |

#### Summary: Peak Throughput per Cycle

| Unit | Operation | Ops/cycle | FLOPs/cycle | Bits read | Bits written |
|------|-----------|-----------|-------------|-----------|--------------|
| **ALU** | ADD/logic | 8 | 8 | 2 × 512 = 1024 | 512 |
| **ALU** | MUL (pipelined) | 8 | 8 | 2 × 512 = 1024 | 512 |
| **FPU** | FMA | 8 | **16** | 3 × 512 = 1536 | 512 |
| **TCU** | WMMA uop | 1 | **32** (16 MAC) | 3 × 512 = 1536 | 512 |

### 4.3 100% Utilization을 위한 Input/Output Bandwidth 요구량

ALU/FPU/TCU를 100% 활용하려면, operand collector가 매 cycle 새 instruction을 공급해야 합니다.

#### Operand Collector 공급 능력

```
Register read ports      = 3 (rs1, rs2, rs3)
Bits per port per cycle  = SIMD_WIDTH × XLEN = 8 × 64 = 512 bits
Read bandwidth           = 3 × 512 = 1,536 bits/cycle (192 bytes/cycle)

Register write ports     = 1
Write bandwidth          = 1 × 512 = 512 bits/cycle (64 bytes/cycle)

Total register bandwidth = 2,048 bits/cycle (256 bytes/cycle)
```

#### 연산별 요구량 vs 공급량

| Unit | Source Operands | Read 요구 (bits/cycle) | Write 요구 (bits/cycle) | Reg File 공급 충분? |
|------|----------------|----------------------|------------------------|-------------------|
| **ALU (ADD)** | rs1, rs2 | 2 × 512 = 1,024 | 512 | Yes (1,536 available) |
| **ALU (MUL)** | rs1, rs2 | 2 × 512 = 1,024 | 512 | Yes |
| **FPU (FMA)** | rs1, rs2, rs3 | 3 × 512 = 1,536 | 512 | Yes (exact match) |
| **TCU (uop)** | rs1, rs2, rs3 | 3 × 512 = 1,536 | 512 | Yes (exact match) |

**Register file은 모든 연산에 대해 100% utilization을 지원합니다.** FMA와 TCU는 3-operand이므로 read bandwidth를 100% 소비합니다.

#### 병목: Operand Collector Issue Rate

실제 병목은 register bandwidth가 아니라 **operand collector의 issue rate**입니다.

```
NUM_OPCS = UP(NUM_WARPS / (4 × ISSUE_WIDTH)) = UP(4 / 4) = 1
Issue rate = 1 instruction / cycle / OPC
```

한 OPC가 cycle당 1개의 instruction만 fetch → dispatch하므로, 동시에 여러 execution unit에 보낼 수 없습니다.

**단, 다른 warp의 instruction은 interleave됩니다.** Warp-level parallelism으로 pipeline latency를 숨길 수 있습니다:

```
FMA pipeline latency = 4 cycles
Available warps = NUM_WARPS = 4
→ 4 warps가 4-cycle FMA pipeline을 완벽히 채움 (1 warp/cycle 교대 issue)
→ 100% FPU utilization 달성 가능

MUL pipeline latency = 3 cycles
→ 3 warps로 충분, 4 warps면 여유 있음
```

#### Data 공급 경로: Register ← Memory

ALU/FPU 100% 활용 시, operand이 이미 register에 있어야 합니다. Register에 data를 채우는 경로의 bandwidth:

```
LSU → Register: 1 load instruction/cycle × 8 lanes × 8 bytes = 512 bits/cycle

ALU/FPU 소비:  최대 1,536 bits/cycle (read) + 512 bits/cycle (write)
```

**Compute-to-load ratio가 중요합니다:**

| Workload | Compute instr/load instr | Register data 충분 조건 |
|----------|--------------------------|------------------------|
| GEMM (tiled) | O(N) compute per O(1) load | 높은 reuse → 쉽게 충족 |
| Element-wise (e.g., VADD) | 1:1 | Load 1 cycle + Compute 1 cycle → **50% utilization** |
| Reduction | N:1 | 높은 reuse → 쉽게 충족 |

Element-wise 연산의 경우 LSU와 ALU/FPU가 동일 OPC를 공유하므로 교대 issue됩니다. 이 경우:

```
Element-wise ALU utilization = 1 / (1 + 1) = 50%  (load + compute 교대)
```

하지만 LMEM에서의 load는 1-cycle latency이고, warp interleaving으로 숨길 수 있습니다:

```
Warp 0: LOAD → ALU → LOAD → ALU ...
Warp 1:         LOAD → ALU → LOAD → ALU ...
Warp 2:                 LOAD → ALU → LOAD → ALU ...
Warp 3:                         LOAD → ALU → LOAD → ALU ...
→ 4 warps 교대 시, 매 cycle ALU 또는 LOAD 가 issue됨
→ ALU: ~50%, LSU: ~50% (이론적 상한)
```

### 4.4 Throughput Summary Diagram

```
                    Operand Collector (1 instr/cycle)
                    ┌─────────────────────────────────┐
   Reg File ────────┤  3 read × 512b + 1 write × 512b │
   (4 banks)        └────────┬────────────────────────┘
                             │ dispatch (1 instr/cycle to one of:)
              ┌──────────────┼──────────────┬──────────────┐
              ▼              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ ALU ×8   │  │ FPU ×8   │  │ TCU ×8   │  │ LSU ×8   │
        │ 8 ops/c  │  │ 16FLOP/c │  │ 16MAC/c  │  │ 512b/c   │
        │ (1 cyc)  │  │ (4 cyc)  │  │ (32 cyc) │  │ (1 cyc)  │
        └──────────┘  └──────────┘  └──────────┘  └──────────┘
         INT arith     FMA peak      WMMA peak     Memory

   Warp interleaving: 4 warps hide pipeline latency
   → FMA 4-cycle latency / 4 warps = 100% utilization possible
```

---

## 5. Interconnect Fabric Analysis

Memory port의 raw bandwidth가 충분하더라도 그것을 delivery하는 interconnect가 bottleneck이 될 수 있습니다. 이 section에서는 register file부터 external memory까지 모든 hop의 interconnect를 분석합니다.

### 5.1 Data Path Interconnect Map

아래는 data가 거치는 모든 interconnect hop을 나열한 것입니다.

```
 [Register File]
       │
       ├─(1) OPC Bank Crossbar ── 3:4 xbar (operand read)
       │
       ├─(2) Dispatch Mux ─────── 1:5 demux (to EX units)
       │
       ├─(3) Commit Arbiter ───── 5:1 arbiter (writeback)
       │
 [Execution Units]
       │
       ├─(4) LSU → Cache Request Crossbar ── NUM_REQS:NUM_BANKS xbar
       │
       ├─(5) Cache Bank → Core Response Crossbar ── NUM_BANKS:NUM_REQS xbar
       │
       ├─(6) Cache Bank → Memory Request Arbiter ── NUM_BANKS:MEM_PORTS arb
       │
       ├─(7) Memory Response → Cache Bank Omega Net ── MEM_PORTS:NUM_BANKS
       │
 [L2 Cache]
       │
       ├─(8) L1→L2 Memory Arbiter ── NUM_SOCKETS×L1_MEM_PORTS : L2_NUM_REQS
       │
       ├─(9) L2 internal (same structure as above: xbar + arb)
       │
       ├─(10) L2→External Memory Arbiter ── L2_NUM_BANKS:L2_MEM_PORTS
       │
 [External Memory]
```

### 5.2 Interconnect Detail per Hop

#### Hop 1: OPC Bank Crossbar (Register Read)

Register file의 3개 source operand 요청을 4개 bank으로 routing합니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | `VX_stream_xbar` | `VX_opc_unit.sv:329-352` |
| Topology | **3-to-4 crossbar** | NUM_SRC_OPDS=3, NUM_GPR_BANKS=4 |
| Data width | `REG_REM_BITS` (address) | 요청만 routing, 데이터는 bank에서 직접 읽음 |
| Arbiter | **Priority** ("P") | 고정 우선순위 |
| Pipeline | 2 stages | read stage 1 → stage 2 |
| Collision | 3개 요청이 같은 bank 겹치면 stall | combinatorial collision detect |

**Throughput impact:** Bank conflict 없으면 **3 reads/cycle**. 최악의 경우(3개 모두 같은 bank) **1 read/cycle**로 저하.

**Bandwidth:**
```
Best case:  3 ports × 512 bits = 1,536 bits/cycle
Worst case: 1 port  × 512 bits =   512 bits/cycle (bank conflict)
```

#### Hop 2: Dispatch Demux (Operand → Execution Unit)

Operand collector 출력을 execution unit type에 따라 routing합니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | `VX_dispatch.sv` + `VX_elastic_buffer` | Per-EX_UNIT buffer |
| Topology | **1-to-5 demux** | 1 OPC → {ALU, LSU, SFU, FPU, TCU} |
| Switching | `ex_type` field로 선택 | Combinatorial mux |
| Buffering | OUT_BUF=2 per unit | Elastic buffer |
| Pipeline | 1 cycle (registered output) | |

**Throughput impact:** 1 instr/cycle 고정. Demux이므로 contention 없음. 단, **동시에 2개 unit에 보낼 수 없음** — issue width = 1.

#### Hop 3: Commit Arbiter (Writeback)

여러 execution unit의 결과를 단일 writeback port로 arbitrate합니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | `VX_stream_arb` | `VX_commit.sv` |
| Topology | **5-to-1 arbiter** | {ALU, LSU, SFU, FPU, TCU} → 1 writeback |
| Arbiter | **Priority** ("P") | |
| OUT_BUF | 1 | |
| Data width | `SIMD_WIDTH × XLEN` = 512 bits | |

**Throughput impact:** 여러 unit이 동시 writeback 시도하면 **contention 발생**. 하지만 issue width=1이므로, 정상적으로는 1 result/cycle. Pipeline이 deep한 unit(FMA 4-cycle)은 4 warps가 각기 다른 cycle에 writeback하므로 충돌 드묾.

**잠재적 병목:** ALU(1-cycle) + LSU(1-cycle load)가 같은 cycle에 writeback 시도 → 1개는 1 cycle stall.

#### Hop 4: Cache Request Crossbar (LSU → Cache Banks)

LSU의 coalesced 요청을 cache bank으로 routing합니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | `VX_stream_xbar` | `VX_cache.sv:329-352` |
| Topology | **NUM_REQS-to-NUM_BANKS crossbar** | |
| Arbiter | **Round-Robin** ("R") | |
| OUT_BUF | `REQ_XBAR_BUF` = 2 (if NUM_REQS > 2) else 0 | `VX_cache.sv:104` |
| Collision perf counter | Yes | PERF_ENABLE 시 |

**이 config에서 (DCACHE_DISABLE, L2_ENABLE):**

DCACHE가 bypass 모드이므로 이 crossbar는 **L2 내부**에서만 동작합니다.

**L2 cache의 경우:**
```
L2_NUM_REQS  = 1  (NUM_SOCKETS × L1_MEM_PORTS = 1 × 1)
L2_NUM_BANKS = 1
→ 1:1 passthrough (crossbar 불필요, collision 없음)
```

#### Hop 5: Cache Response Crossbar (Cache Banks → Core)

Cache bank의 응답을 원래 요청자에게 돌려보냅니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | `VX_stream_xbar` | `VX_cache.sv:455-472` |
| Topology | **NUM_BANKS-to-NUM_REQS** | |
| Arbiter | Round-Robin | |
| OUT_BUF | `CORE_OUT_BUF` = 3 (2-stage buffer) | |

**L2에서**: 1:1 passthrough.

#### Hop 6: Memory Request Arbiter (Cache Banks → Memory Ports)

여러 cache bank의 miss/writeback 요청을 memory port로 serialize합니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | `VX_stream_arb` | `VX_cache.sv:517-532` |
| Topology | **NUM_BANKS-to-MEM_PORTS** | |
| Arbiter | Round-Robin | |
| Data width | `MEM_REQ_DATAW` (addr + line_data + tag) | |

**L2에서**: `L2_NUM_BANKS(1) : L2_MEM_PORTS(1)` → 1:1 passthrough.

#### Hop 7: Memory Response Omega Network (Memory → Cache Banks)

Memory 응답을 올바른 cache bank으로 routing합니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | **`VX_stream_omega`** | `VX_cache.sv:202-220` |
| Topology | **MEM_PORTS-to-NUM_BANKS** omega network | |
| Arbiter | Round-Robin | |
| OUT_BUF | 3 (registered) | |
| Stages | `LOG2(N) / LOG2(RADIX)` (multi-stage for large N) | |

**L2에서**: 1:1 passthrough.

> **Note:** Omega network은 bank 수가 많을 때(>RADIX) multi-stage switching으로 동작하며, crossbar보다 면적이 작지만 blocking 가능성이 있습니다. 이 config에서는 1:1이므로 해당 없음.

#### Hop 8: L1 → L2 Memory Arbiter

Socket 내 L1 cache(icache + dcache)의 요청을 L2로 arbitrate합니다.

| Property | Value | Source |
|----------|-------|--------|
| Module | `VX_mem_arb` | `VX_socket.sv` |
| Topology | **2-to-L1_MEM_PORTS** (icache + dcache → L2) | |
| Arbiter | Round-Robin | |
| Tag routing | `CLOG2(2)` = 1 bit added to tag | icache vs dcache 구분 |

**이 config에서:**
```
Inputs:  icache(1 port) + dcache_bypass(1 port) = 2
Outputs: L1_MEM_PORTS = 1
→ 2:1 arbiter → 최대 throughput = 1 request/cycle
→ icache와 dcache가 동시 요청 시 1개는 stall
```

**이것이 핵심 interconnect 병목입니다.** icache fetch와 data access가 L2 port 1개를 두고 경쟁합니다.

#### Hop 9-10: L2 → External Memory

| Property | Value | Source |
|----------|-------|--------|
| L2 internal | 1:1 (bank=1, req=1) | passthrough |
| L2 → External | `VX_mem_arb` 1:1 | `L2_MEM_PORTS = 1` |

### 5.3 Interconnect Latency Budget

각 hop의 pipeline stage를 합산합니다.

| Hop | Description | Pipeline Stages | Notes |
|-----|-------------|-----------------|-------|
| 1 | OPC bank crossbar | **2** | Read stage 1 + stage 2 |
| 2 | Dispatch buffer | **1** | Elastic buffer (OUT_BUF=2 → 1 reg stage) |
| — | Execution unit | **1–16** | Unit dependent |
| 3 | Commit arbiter | **1** | OUT_BUF=1 |
| 1' | OPC bank write | **1** | Writeback to register file |
| | **Subtotal (compute loop)** | **6–20 cycles** | |
| | | | |
| 4 | Cache req xbar | **0–2** | OUT_BUF=2 if NUM_REQS>2, else 0 |
| — | Cache bank pipeline | **3–4** | Schedule → Tag → Data → Response |
| 5 | Cache rsp xbar | **1–2** | CORE_OUT_BUF=3 |
| 6 | Mem req arb | **0–1** | |
| 7 | Mem rsp omega | **1–2** | OUT_BUF=3 |
| 8 | L1→L2 arb | **1** | 2:1 arbiter |
| 9-10 | L2 bank + mem arb | **3–6** | L2 cache pipeline |
| | **Subtotal (memory loop)** | **~10–18 cycles** | Miss latency (excluding DRAM) |

### 5.4 Concrete Interconnect Throughput (NUM_THREADS=8)

이 config에서 각 interconnect의 sustained throughput:

| Hop | Interconnect | Config | Max Throughput | Bottleneck? |
|-----|-------------|--------|---------------|-------------|
| 1 | OPC 3:4 xbar | 3 src → 4 banks | 1,536 b/cyc (no conflict) | Potential (bank conflict) |
| 2 | Dispatch 1:5 | 1 → {ALU,FPU,TCU,LSU,SFU} | 512 b/cyc (1 instr) | **Yes** (issue width=1) |
| 3 | Commit 5:1 | {ALU,FPU,TCU,LSU,SFU} → 1 | 512 b/cyc (1 result) | Potential (multi-unit contention) |
| 4 | L2 req xbar | 1:1 (passthru) | 512 b/cyc | No |
| 5 | L2 rsp xbar | 1:1 (passthru) | 512 b/cyc | No |
| 6 | L2 mem req arb | 1:1 (passthru) | 512 b/cyc | No |
| 7 | L2 mem rsp omega | 1:1 (passthru) | 512 b/cyc | No |
| 8 | **L1→L2 arb** | **2:1** (icache+dcache → L2) | **512 b/cyc shared** | **Yes** |
| 9-10 | L2→Ext mem | 1:1 | 512 b/cyc | No |

### 5.5 Updated Data Path Diagram (with Interconnect)

```
 ┌────────────────────────────────────────────────────────────────┐
 │  Register File (4 banks, 64 regs × 8 lanes × 64b)            │
 │    Read:  3 ports × 512b = 1,536 b/cyc                       │
 │    Write: 1 port  × 512b =   512 b/cyc                       │
 └────────┬───────────────────────────────────────┬──────────────┘
          │ (Hop 1) OPC 3:4 xbar                  │
          │  Priority arb, 2-stage pipeline        │
          │  Bank conflict → stall                 │ (Hop 3) Commit 5:1 arb
          ▼                                        │  Priority, 1-stage
 ┌──────────────────────┐                          │
 │ Dispatch 1:5 demux   │◄─────────────────────────┘
 │ (Hop 2) 1 instr/cyc  │
 └──┬──┬──┬──┬──┬───────┘
    │  │  │  │  │
    ▼  ▼  ▼  ▼  ▼
  ALU FPU TCU SFU LSU ─────────────────────┐
  8   8   8       8 lanes                   │
                                            ▼
                              ┌──────────────────────┐
                              │ (Hop 4) Cache Req     │
                              │  L2: 1:1 passthru     │
                              └──────────┬───────────┘
                                         ▼
          ┌──────────────────────────────────────────────────────┐
          │                  (Hop 8) L1→L2 Arbiter               │
          │     icache ──┐                                       │
          │              ├── 2:1 RR arb ──► L2 (1 bank, 1 port) │
          │     dcache ──┘                                       │
          │     ** SHARED: 512 b/cyc total **                    │
          │     icache fetch와 data access가 경쟁                 │
          └──────────────────────────┬───────────────────────────┘
                                     │ (Hop 9-10)
                                     ▼
                              L2: 1 bank, 1 port
                              512 b/cyc → External Memory
```

```
 [LMEM Path — 별도 경로, L2 경유 안 함]

  LSU (8 lanes) ──► LMEM (8 banks, 4MB)
                     8 × 64b = 512 b/cyc
                     Bank conflict free (1 bank/lane)
                     No interconnect contention
```

### 5.6 Interconnect Bottleneck Summary

**이 config에서 interconnect 관점의 3대 병목:**

1. **Dispatch demux (Hop 2):** `ISSUE_WIDTH=1`이므로 cycle당 1개 execution unit에만 instruction 전달 가능. ALU와 FPU가 동시 실행 불가.

2. **L1→L2 arbiter (Hop 8):** icache(instruction fetch)와 dcache bypass(data access)가 **2:1 round-robin arbiter**를 통해 L2 port 1개를 공유. instruction fetch가 활발하면 data throughput 절반으로 감소.
   ```
   Data-only throughput = 512 b/cyc × (1/2) = 256 b/cyc  (icache 경쟁 시)
   ```

3. **Commit arbiter (Hop 3):** 5:1 priority arbiter. 다중 unit이 같은 cycle에 결과를 produce하면 stall 발생. 특히 ALU(1-cycle)와 LSU(load return)의 동시 writeback이 빈번.

**반면 contention이 없는 경로:**
- **LMEM**: LSU에서 직접 접근, 8 bank parallel, interconnect hop 없음
- **L2 내부**: 이 config에서 bank=1, req=1이므로 모든 내부 crossbar가 1:1 passthrough

**최적화 권장사항:**
- TCU/GEMM workload는 **LMEM을 data staging 영역**으로 사용하여 L1→L2 arbiter 경쟁 회피
- `ISSUE_WIDTH`를 높이면(NUM_WARPS ≥ 32) dispatch bottleneck 해소 가능
- `L1_MEM_PORTS` 증가(requires DCACHE 활성화 or `L1_DISABLE` 설정)로 L1→L2 bandwidth 확대 가능
