# TMEM + DMA Data Feeding Architecture — Spec

**Status**: CONFIRMED (2026-04-07)
**Branch**: fpint_improve

## 1. Goal

GEMM unit의 data feeding bandwidth를 증가시키기 위해:
- **Tensor Memory (TMEM)**: 8-bank dedicated SRAM (VX_sp_ram 기반, default 4KB/bank)
- **DMA**: 8-port AXI master로 HBM↔TMEM bulk data transfer (SW가 stride/bound 제어)
- **Local DMA**: TMEM ↔ GEMM unit data movement (기존 `VX_lmem_dma_misal.sv` repurpose)
- **LMEM path 제거**: MXU는 더이상 LMEM에 접근하지 않음. LSU만 LMEM 접근.

## 2. Architecture Overview

### 2.1 Core 내부 (port_num_scaling sheet)

```
HBM (AXI x8, using third_party/axi AXI_BUS interface)
    │
    ▼
┌──────────┐  membus x8   ┌───────────────────────────────┐
│   DMA    │──────────────►│  5:1 arbiter → TMEM bank x8   │
│(axi↔     │               │  (VX_sp_ram, 1-port each,     │
│ membus)  │               │   4KB default, param SIZE)     │
└──────────┘               └───────────────┬───────────────┘
                     ┌─────────────────────┼─────────────────────┐
                     ▼                     ▼                      ▼
               ┌───────────┐       ┌───────────┐          ┌───────────┐
               │8:1 switch │       │8:1 switch │          │8:1 switch │
               │(input)    │       │(weight)   │          │(scale_zp) │
               └─────┬─────┘       └─────┬─────┘          └─────┬─────┘
                     ▼                    ▼                       ▼
               ┌───────────┐       ┌───────────┐          ┌───────────┐
               │input      │       │weight     │          │scale_zp   │
               │local DMA  │       │local DMA  │          │local DMA  │
               └─────┬─────┘       └─────┬─────┘          └─────┬─────┘
                     ▼                    ▼                       ▼
               ┌─────────────────────────────────────────────────────┐
               │              GEMM Unit (MXU)                        │
               │  input:     64B VX_mem_bus_if                       │
               │  weight:    64B VX_mem_bus_if (4 rows per read)     │
               │  scale_zp:  64B VX_mem_bus_if                       │
               │  output:    64B VX_mem_bus_if                       │
               └───────────────────────┬─────────────────────────────┘
                                       ▼
                                ┌───────────┐
                                │output     │
                                │local DMA  │
                                └─────┬─────┘
                                      ▼
                                ┌───────────┐
                                │1:8 switch │
                                └─────┬─────┘
                                      ▼
                              5:1 arbiter → TMEM bank x8
```

### 2.2 TMEM Bank Access Arbitration

각 TMEM bank는 single-port `VX_sp_ram` 기반이므로, 여러 requestor를 arbiter로 serialization:

```
Requestors per bank (5:1 arbiter):
  [0] DMA membus port (1:1 with bank)
  [1] input switch read
  [2] weight switch read
  [3] scale_zp switch read
  [4] output switch write
     → VX_mem_arb (5:1) → VX_sp_ram (1-port)
```

### 2.3 Switch (bidirectional mux/demux)

8:1 switch와 1:8 switch는 단순한 mux/demux가 아닌 **bidirectional switch**:
- `VX_mem_bus_if`의 req/rsp 양방향을 모두 처리
- 8:1 switch: 8개 bank 중 하나를 select하여 local DMA와 연결 (read path)
- 1:8 switch: local DMA의 output을 8개 bank 중 하나로 routing (write path)
- Address 기반 routing (interleaving)

### 2.4 Upper hierarchy

```
┌────────────┐  cache_master   ┌──────────────┐  mem_master   ┌─────────────┐
│VX_core x N │────────────────►│ cache system  │─────────────►│ axi adapter │
│            │                 └──────────────┘               └──────┬──────┘
│            │  dma_master[8] (AXI_BUS)                              │
│            │──────────────────────────────────┐                    ▼
└────────────┘                                  │            ┌────────────┐
                                                ├───────────►│1:8 switch  │
                                                │            └─────┬──────┘
                                                ▼                  ▼
                                          ┌─────────────────────────────┐
                                          │      AXI Arbiter            │
                                          │  (axi_mux from third_party) │
                                          │  slave[8 + 8*NUM_CORES]     │
                                          │  master[8] → HBM            │
                                          └─────────────────────────────┘
```

AXI arbiter slave port mapping:
- `slave[(1+NUM_CORES)*j + 0]` = LSU (axi adapter → 1:8 switch → port j)
- `slave[(1+NUM_CORES)*j + i+1]` = core[i].dma_master[j]

## 3. New/Modified Modules

### 3.1 New Modules

| Module | File | Description |
|--------|------|-------------|
| `VX_tensor_mem_bank` | `hw/rtl/mem/VX_tensor_mem_bank.sv` | Single TMEM bank. VX_sp_ram 1-port. 앞단에 VX_mem_arb(5:1). Default 4KB, parameterized SIZE. |
| `VX_tmem_subsystem` | `hw/rtl/mem/VX_tmem_subsystem.sv` | TMEM bank x8 + switch x4 + arbiter wiring. DMA membus ports와 local DMA ports를 연결. |
| `VX_dma_engine` | `hw/rtl/mem/VX_dma_engine.sv` | HBM↔TMEM DMA. 8 channel (1:1). `VX_dma_unit_misal.sv` x8 reuse (dcache→AXI via `axi_from_mem`, lmem→tmem rename). SW-controlled stride/bound. |

### 3.2 Modified Modules

| Module | File | Change |
|--------|------|--------|
| `VX_gemm_node` | `hw/rtl/core/gemm/VX_gemm_node.sv` | LMEM bus path 제거. VX_tmem_subsystem instantiate. DMA AXI ports를 core top으로 expose. |
| `VX_lmem_dma_misal` | `hw/rtl/core/gemm/VX_lmem_dma_misal.sv` | Repurpose: `lmem_bus_if` → `tmem_bus_if` (port rename). Logic 동일, TMEM 512-bit bus와 통신. |
| `VX_core` (top) | `hw/rtl/core/VX_core.sv` | `AXI_BUS.Master dma_axi[8]` port 추가. GEMM node의 DMA port를 core top으로 routing. |
| `VX_lmem_switch` | `hw/rtl/mem/VX_lmem_switch.sv` | GEMM path 제거 (GEMM은 더이상 LMEM 접근 안함). LSU만 LMEM 접근. |

### 3.3 Reused from third_party/axi

| Module | Usage |
|--------|-------|
| `AXI_BUS` (axi_intf.sv) | AXI interface definition. DMA↔upper hierarchy 연결에 사용. |
| `axi_from_mem` | DMA 내부: membus-like req/rsp → AXI master 변환. |
| `axi_mux` | Upper hierarchy: AXI arbiter (N masters → 1 master). |
| `axi_demux` | Upper hierarchy: 1:8 switch (AXI address-based routing). |
| `axi_pkg` | AXI type definitions, constants. |
| `axi/typedef.svh` | AXI struct 생성 macros (`AXI_TYPEDEF_ALL`). |
| `axi/assign.svh` | AXI channel assignment macros. |

### 3.4 Reused from existing codebase

| Module | Usage |
|--------|-------|
| `VX_sp_ram` | TMEM bank 내부 SRAM |
| `VX_mem_arb` | TMEM bank front-end arbitration (5:1 → 1) |
| `VX_stream_arb` | 8:1 switch 내부 arbitration |

## 4. Interface Specifications

### 4.1 TMEM Bank

```systemverilog
module VX_tensor_mem_bank #(
    parameter `STRING INSTANCE_ID = "",
    parameter SIZE       = 4*1024,   // 4KB default, parameterized
    parameter DATA_SIZE  = 64,       // 512-bit (64 bytes)
    parameter NUM_PORTS  = 5,        // DMA + 3 read switch + 1 write switch
    parameter TAG_WIDTH  = 8
) (
    input wire clk, reset,
    VX_mem_bus_if.slave mem_bus_if [NUM_PORTS]  // all go through arbiter → single VX_sp_ram
);
```

### 4.2 DMA Engine

Uses `axi_from_mem` from third_party/axi for AXI conversion:

```systemverilog
module VX_dma_engine #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_PORTS      = 8,
    parameter DATA_WIDTH     = 512,
    parameter AXI_ADDR_WIDTH = `PLATFORM_MEMORY_ADDR_WIDTH,
    parameter AXI_ID_WIDTH   = `PLATFORM_MEMORY_ID_WIDTH,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter TAG_WIDTH      = 8
) (
    input wire clk, reset,

    // Control interface (from gemm_dma_ctrl / SW commands)
    VX_dma_ctrl_if.slave ctrl_if,

    // HBM side — AXI_BUS master x NUM_PORTS (third_party/axi interface)
    AXI_BUS.Master axi_m [NUM_PORTS],

    // TMEM side — VX_mem_bus_if master x NUM_PORTS
    VX_mem_bus_if.master membus_m [NUM_PORTS]
);
    // Internal per-channel:
    //   stride/bound FSM → mem req/rsp → axi_from_mem → AXI_BUS
    //                    → VX_mem_bus_if → TMEM
```

### 4.3 VX_core port 변경

```systemverilog
module VX_core (
    ...
    VX_mem_bus_if.master dcache_bus_if,  // LSU → cache (유지)
    AXI_BUS.Master       dma_axi [8]    // DMA → HBM (신규, third_party/axi interface)
    ...
);
```

### 4.4 GEMM Unit Ports (unchanged)

GEMM unit의 4개 port는 기존과 동일한 64B `VX_mem_bus_if`:
- input: 64B read
- weight: 64B read (한번에 4 rows 읽음)
- scale_zp: 64B read
- output: 64B write

## 5. Address Constraints (from notion.md)

### 5.1 HBM ↔ TMEM
DMA의 1:1 port mapping (8 AXI ↔ 8 TMEM bank) + interleaving:
```
hbm_addr % 512 == tmem_addr % 512
```

### 5.2 TMEM ↔ MXU (TMEM address alignment)
```
input:      base_addr(input[x, 32y+:32]) % 64 == 0
weight:     base_addr(weight[4x+:4, 32y+:32]) % 64 == 0
output:     base_addr(output[x, 32y+:32]) % 64 == 0
scale/zp:   base_addr(scale[x, 32y+:32]) % 64 == 0  (qdir==0)
            base_addr(scale[32x+:32, y]) % 64 == 0  (qdir==1)
```

## 6. Constraints & Assumptions

1. **Interconnection은 simple 1:1/interleaving만 사용** — crossbar 없음. Kernel/compiler 최적화로 해결.
2. **TMEM은 GEMM 전용** — LSU 접근 불가.
3. **LMEM은 LSU 전용으로 유지** — GEMM path 제거.
4. **512-bit data width** 통일 (DMA, TMEM, switch).
5. **GEMM unit ports는 64B `VX_mem_bus_if`** — 기존 유지.
6. **AXI는 third_party/axi 라이브러리 사용**: `AXI_BUS` interface, `axi_from_mem`, `axi_mux`, `axi_demux` 등.
7. **DMA의 AXI 8 ports는 cache system bypass** — 직접 AXI arbiter로 연결.
8. **DMA는 SW-controlled**: stride, bound는 command에서 전달. HW는 tiling 결정 안 함.
9. **TMEM bank는 1-port**: VX_sp_ram 사용. Front-end 5:1 arbiter로 multi-requestor 처리.
10. **Switch는 bidirectional**: 8:1/1:8 switch는 VX_mem_bus_if req/rsp 양방향 처리.

## 7. Implementation Order (Divide-and-Conquer)

전체 구조를 한번에 수정하되, 테스트는 piece별 unittest로 진행:

| Phase | Module | Test |
|-------|--------|------|
| 1 | `VX_tensor_mem_bank` | unittest: multi-port arbitrated read/write correctness |
| 2 | `VX_dma_engine` (AXI ↔ membus via axi_from_mem) | unittest: AXI transaction ↔ membus conversion |
| 3 | `VX_tmem_subsystem` (integration) | unittest: DMA → TMEM → switch → local DMA → GEMM bus |
| 4 | `VX_gemm_node` modification | unittest: GEMM node with TMEM (기존 gemm_node test 수정) |
| 5 | `VX_core` + upper hierarchy (axi_mux/axi_demux) | blackbox: full system test |
