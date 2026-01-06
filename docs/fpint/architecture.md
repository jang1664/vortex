# FPINT Extension Architecture

FPINT extension은 Vortex core에 GEMM (General Matrix Multiply) 가속기와 DMA 엔진을 추가하여 FP16/INT quantized 연산을 지원합니다.

## Module Hierarchy

```
VX_core
├── VX_mem_unit
│   ├── VX_lmem_switch (modified)
│   │   ├── lsu_in_if      ← LSU에서 오는 메모리 요청
│   │   ├── global_out_if  → dcache로 가는 글로벌 메모리 요청
│   │   ├── local_out_if   → local memory로 가는 로컬 메모리 요청
│   │   ├── gemm_ctrl_if   → GEMM control register 접근
│   │   └── dma_ctrl_if    → DMA control register 접근
│   │
│   ├── VX_local_mem
│   │   └── lmem_membus_arb (arbitrates LSU, DMA, GEMM accesses)
│   │
│   └── dcache_dma_arbiter (arbitrates LSU and DMA for dcache)
│
├── VX_gemm_node (new)
│   ├── VX_gemm_ctrl
│   ├── VX_gemm_unit
│   ├── VX_lmem_dma (x4: input, weight, quant_param, output)
│   ├── VX_gemm_dma_ctrl
│   └── Data Adapters (VX_mem_data_adapter x4)
│
└── VX_dma_node (new, placeholder)
```

## Data Flow Diagram

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                         VX_core                             │
                    │                                                             │
┌─────────┐         │  ┌──────────────┐                                           │
│   LSU   │─────────┼─►│ VX_lmem_switch│                                          │
└─────────┘         │  └──────┬───────┘                                           │
                    │         │                                                   │
         ┌──────────┼─────────┼──────────────────┬──────────────────┐             │
         │          │         │                  │                  │             │
         ▼          │         ▼                  ▼                  ▼             │
  ┌─────────────┐   │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐        │
  │ global_out  │   │  │ local_out   │   │ gemm_ctrl   │   │ dma_ctrl    │        │
  └──────┬──────┘   │  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘        │
         │          │         │                  │                  │             │
         ▼          │         ▼                  ▼                  ▼             │
  ┌─────────────┐   │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐        │
  │   dcache    │   │  │    LMEM     │   │ VX_gemm_node│   │ VX_dma_node │        │
  └──────┬──────┘   │  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘        │
         │          │         │                  │                  │             │
         └──────────┼─────────┼──────────────────┼──────────────────┘             │
                    │         │                  │                                │
                    │         ▼                  ▼                                │
                    │  ┌─────────────────────────────────────┐                    │
                    │  │     Memory Arbiters                 │                    │
                    │  │  (lmem_membus_arb, dcache_dma_arb)  │                    │
                    │  └─────────────────────────────────────┘                    │
                    │                                                             │
                    └─────────────────────────────────────────────────────────────┘
```

## VX_gemm_node Internal Structure

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              VX_gemm_node                                       │
│                                                                                 │
│  ┌────────────────┐     ┌─────────────────────────────────────────────────────┐ │
│  │  VX_gemm_ctrl  │────►│              Control Interfaces                     │ │
│  │                │     │  ┌───────────────┐  ┌────────────────────┐          │ │
│  │  - cfg_reg_if  │     │  │ gemm_ctrl_if  │  │ lmem_dma_ctrl_if   │          │ │
│  │  - FSM         │     │  │               │  │ (x4: I/W/SZ/O)     │          │ │
│  └────────────────┘     │  └───────────────┘  └────────────────────┘          │ │
│                         └─────────────────────────────────────────────────────┘ │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────┐│
│  │                         LMEM DMA Engines                                    ││
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐           ││
│  │  │ input_dma   │ │ weight_dma  │ │ qparam_dma  │ │ output_dma  │           ││
│  │  │ (LMEM→GEMM) │ │ (LMEM→GEMM) │ │ (LMEM→GEMM) │ │ (GEMM→LMEM) │           ││
│  │  │ VX_lmem_dma │ │ VX_lmem_dma │ │ VX_lmem_dma │ │ VX_lmem_dma │           ││
│  │  │   DIR=0     │ │   DIR=0     │ │   DIR=0     │ │   DIR=1     │           ││
│  │  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘ └──────┬──────┘           ││
│  │         │               │               │               │                  ││
│  │         └───────────────┴───────────────┴───────────────┘                  ││
│  │                                  │                                          ││
│  │                                  ▼                                          ││
│  │                    ┌─────────────────────────────┐                          ││
│  │                    │     lmem_membus_arbiter     │                          ││
│  │                    │       (4-to-1 arbiter)      │                          ││
│  │                    └──────────────┬──────────────┘                          ││
│  │                                   │                                          ││
│  │                                   ▼                                          ││
│  │                           lmem_bus_if (to LMEM)                             ││
│  └─────────────────────────────────────────────────────────────────────────────┘│
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────┐│
│  │                       Data Width Adapters                                   ││
│  │  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐ ┌─────────────┐││
│  │  │ input_adapter   │ │ weight_adapter  │ │ qparam_adapter  │ │output_adapter│││
│  │  │ (GEMM_DW→LSU_DW)│ │ (GEMM_DW→LSU_DW)│ │ (GEMM_DW→LSU_DW)│ │(GEMM_DW→LSU_DW)│ │
│  │  │VX_mem_data_adapter│VX_mem_data_adapter│VX_mem_data_adapter│VX_mem_data_adapter│ │
│  │  └────────┬────────┘ └────────┬────────┘ └────────┬────────┘ └──────┬──────┘││
│  │           │                   │                   │                 │       ││
│  │           └───────────────────┴───────────────────┴─────────────────┘       ││
│  │                                    │                                         ││
│  │                                    ▼                                         ││
│  │                          ┌─────────────────┐                                ││
│  │                          │   VX_gemm_unit  │                                ││
│  │                          │   (GEMM Core)   │                                ││
│  │                          └─────────────────┘                                ││
│  └─────────────────────────────────────────────────────────────────────────────┘│
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────┐│
│  │                     External DMA Control                                    ││
│  │  ┌──────────────────┐                                                       ││
│  │  │ VX_gemm_dma_ctrl │──────────► dma_if (to mem_unit for dcache<->LMEM)     ││
│  │  └──────────────────┘                                                       ││
│  └─────────────────────────────────────────────────────────────────────────────┘│
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Memory Access Paths

### 1. LSU → LMEM (기존 경로)
```
LSU → VX_lmem_switch → local_out_if → VX_lsu_mem_arb → VX_lsu_adapter → LMEM
```

### 2. LSU → DCache (기존 경로)
```
LSU → VX_lmem_switch → global_out_if → VX_mem_coalescer → VX_lsu_adapter → DCache
```

### 3. GEMM → LMEM (새 경로)
```
VX_gemm_unit ← VX_mem_data_adapter ← VX_lmem_dma ← lmem_membus_arbiter ← LMEM
```

### 4. DMA: DCache ↔ LMEM (새 경로)
```
DCache ← dcache_dma_arbiter ← VX_dma_node → lmem_membus_arbiter → LMEM
```

### 5. External DMA from GEMM control (새 경로)
```
VX_gemm_dma_ctrl → dma_if → mem_unit → dcache/lmem
```

## New Files

### Core Modules
| File | Description |
|------|-------------|
| [VX_gemm_node.sv](../../hw/rtl/core/gemm/VX_gemm_node.sv) | GEMM accelerator top module |
| [VX_gemm_ctrl.sv](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv) | GEMM control FSM and register interface |
| [VX_gemm_unit.sv](../../hw/rtl/core/gemm/VX_gemm_unit.sv) | GEMM computation unit |
| [VX_gemm_dma_ctrl.sv](../../hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv) | External DMA controller (dcache ↔ LMEM) |
| [VX_lmem_dma.sv](../../hw/rtl/core/gemm/VX_lmem_dma.sv) | LMEM ↔ GEMM DMA engine |
| [VX_dma_node.sv](../../hw/rtl/core/VX_dma_node.sv) | Standalone DMA engine (dcache ↔ LMEM) |

### Interfaces
| File | Description |
|------|-------------|
| [VX_gemm_ctrl_if.sv](../../hw/rtl/core/gemm/VX_gemm_ctrl_if.sv) | GEMM control interface (DMA controls/flags) |
| [VX_gemm_unit_if.sv](../../hw/rtl/core/gemm/VX_gemm_unit_if.sv) | GEMM unit control interface (start/idle/done) |
| [VX_lmem_dma_ctrl_if.sv](../../hw/rtl/core/gemm/VX_lmem_dma_ctrl_if.sv) | LMEM DMA control interface (N-dimensional transfer) |
| [VX_dma_if.sv](../../hw/rtl/core/VX_dma_if.sv) | DMA interface for multi-dimensional transfer |

### GEMM Datapath Modules
| File | Description |
|------|-------------|
| [VX_pe.sv](../../hw/rtl/core/gemm/VX_pe.sv) | Processing Element |
| [VX_gemm_tree.sv](../../hw/rtl/core/gemm/VX_gemm_tree.sv) | GEMM adder tree |
| [VX_gemm_acc_mem.sv](../../hw/rtl/core/gemm/VX_gemm_acc_mem.sv) | Accumulator memory |
| [VX_prealigner.sv](../../hw/rtl/core/gemm/VX_prealigner.sv) | Input pre-alignment |
| [VX_act_sum.sv](../../hw/rtl/core/gemm/VX_act_sum.sv) | Activation sum |
| [VX_data_setup.sv](../../hw/rtl/core/gemm/VX_data_setup.sv) | Data setup logic |
| [VX_hidden.sv](../../hw/rtl/core/gemm/VX_hidden.sv) | Hidden layer processing |

### GEMM Post-processing Modules
| File | Description |
|------|-------------|
| [VX_reformatter.sv](../../hw/rtl/core/gemm/VX_reformatter.sv) | Output reformatting |
| [VX_pint2fp.sv](../../hw/rtl/core/gemm/VX_pint2fp.sv) | Packed INT to FP conversion |
| [VX_pint2fp_arr.sv](../../hw/rtl/core/gemm/VX_pint2fp_arr.sv) | Array version of pint2fp |
| [VX_scaler.sv](../../hw/rtl/core/gemm/VX_scaler.sv) | Output scaling |
| [VX_f32_to_f16.sv](../../hw/rtl/core/gemm/VX_f32_to_f16.sv) | FP32 to FP16 conversion |
| [VX_shifter.sv](../../hw/rtl/core/gemm/VX_shifter.sv) | Bit shifter |
| [VX_compare.sv](../../hw/rtl/core/gemm/VX_compare.sv) | Comparator |

### Modified Files
| File | Description |
|------|-------------|
| [VX_mem_unit.sv](../../hw/rtl/core/VX_mem_unit.sv) | Added DMA and GEMM memory paths |
| [VX_lmem_switch.sv](../../hw/rtl/mem/VX_lmem_switch.sv) | Added gemm_ctrl_if and dma_ctrl_if outputs |

## Interface Specifications

### VX_lmem_dma_ctrl_if
N-dimensional DMA transfer control:
- `start`: Transfer start signal
- `src_base_addr[31:0]`: Source base address
- `dst_base_addr[31:0]`: Destination base address
- `src_strides[NDIM][31:0]`: Source stride per dimension
- `dst_strides[NDIM][31:0]`: Destination stride per dimension
- `bounds[NDIM][31:0]`: Iteration bounds per dimension
- `seg_size[31:0]`: Segment size for 1D transfer
- `idle`: DMA idle status
- `done`: Transfer completion status

### VX_gemm_ctrl_if
GEMM control signals:
- `input_read_ctrl/flag`: Input data read DMA control
- `weight_read_ctrl/flag`: Weight data read DMA control
- `quant_param_read_ctrl/flag`: Quantization parameter read DMA control
- `output_write_ctrl/flag`: Output data write DMA control
- `dma_ctrl/flag`: External DMA control (dcache ↔ LMEM)

### VX_gemm_unit_if
GEMM unit control:
- `start`: Start computation
- `idle`: Unit is idle
- `done`: Computation complete
