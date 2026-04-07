# FPINT GEMM Performance Analysis

## FPGA Equivalent Gate Area

- 논문에서 사용됐던 방법

### 접근법 A: ENS (Equivalent Number of Slices) — 논리적 등가 변환

COMET 논문 (arXiv 2510.03516)에서 정의한 ENS metric이 정확히 이 방식이야. DSP와 BRAM을 "이걸 LUT/Slice로 구현하면 몇 개 필요한가"를 실측해서 slice-equivalent로 변환:

```
ENS = LUTs/4 + DSP_used × 102.4 + BRAM18K_used × 116.2
```

구체적으로, DSP48E (25×18 multiplier)를 순수 slice로 구현하면 약 128 slice인데, 실제 사용에서 partial utilization을 반영해서 0.8을 곱해 102.4 slice/DSP. 18Kb BRAM은 dual-port RAM 기준으로 166 slice equivalent에 0.8을 곱해 116.2 slice/BRAM.

이 weight의 근거: **실제로 해당 기능을 DSP/BRAM 없이 합성해보고 필요한 slice 수를 측정한 것.** 즉 Vivado에서 `set_property USE_DSP 0`으로 놓고 같은 multiplier를 합성하면 나오는 slice 수가 기준.

### 접근법 B: Device 리소스 비율 기반 — Mix and Match (IEEE)

Mix and Match 논문에서는 FPGA 디바이스마다 LUT, FF, BRAM, DSP의 비율이 다르다는 점에 주목해서, 모든 리소스를 DSP 수 기준으로 normalize해서 비교. 예를 들어:

```
XC7Z020: LUT:DSP ≈ 240:1, BRAM:DSP ≈ 2:1
XC7Z045: LUT:DSP ≈ 250:1, BRAM:DSP ≈ 2.5:1
```

이건 "이 디바이스에서 DSP 1개를 쓰면 LUT 240개분의 die area를 쓰는 것과 같다"는 관점. Weight를 die area 비율로 잡는 방식의 근거는 **FPGA vendor가 die에 각 리소스를 배치할 때, 전체적으로 balanced utilization이 되도록 설계한다**는 가정이야.

### 두 접근법의 핵심 차이

|  | ENS (논리 등가) | Device 비율 (die area) |
| --- | --- | --- |
| **weight 근거** | "DSP를 LUT로 대체하면 몇 개?" | "die에서 DSP가 차지하는 면적 비율" |
| **측정 방법** | cross-synthesis 실측 | die photo / 리소스 수 비율 역산 |
| **의미** | 기능적 복잡도 | 물리적 silicon 비용 |
| **장점** | 직관적, 재현 가능 | ASIC area 비교에 더 적합 |
| **한계** | routing overhead 미반영 | device마다 비율이 달라서 portability 낮음 |

### 실무적 권장

**ENS 방식이 더 적합.** 이유:

1. 기능적 등가 변환이라 "이 accelerator의 complexity가 얼마인가"를 single number로 표현 가능
2. Reviewer에게 설명하기 쉬움: "DSP 1개 = LUT 128개 equivalent (실측 기반)"
3. ASIC gate count와 연결하려면 ENS에 Synopsys의 6 gates/LUT를 곱하면 rough gate equivalent가 나옴

```
ASIC_gate_equiv ≈ ENS × 4 (LUTs/slice) × 6 (gates/LUT) = ENS × 24
```

물론 Kuon & Rose의 35× gap을 감안하면 실제 ASIC die area는 이것의 1/35이 되겠지만, 비교의 방향성은 잡을 수 있어.

---

## Algorithmic Operation Intensity (AOI)

### 기준: llama2-spinquant-A16W4A4KV4

- 모델: Llama-2 7B
- 기호:
    - B = batch size
    - S = prefill sequence length
    - L = decode 시점의 context length
    - H = hidden size
    - I = intermediate size
- 정밀도:
    - activation = A16 = 2 bytes/elt
    - weight = W4 = 0.5 bytes/elt
    - KV cache = KV4 = 0.5 bytes/elt
- OI 정의:
    - OI = FLOPs / minimal tensor bytes
- attention은 **fused** 기준으로 둔다.
    - 즉, QK^T / softmax / AV 사이의 중간 score, prob를 HBM/DRAM에 별도 materialize하지 않는 이상적인 algorithmic OI다.
- Llama-2 7B config는 hidden_size 4096, intermediate_size 11008, attention heads 32, key-value heads 32다. SpinQuant는 mergeable rotation R1/R2와 online Hadamard R3/R4를 두며, 논문 설명상 R3는 low-bit KV-cache, R4는 low-bit activation 쪽에 해당한다. 따라서 **A16W4KV4에서는 런타임 추가 커널을 보수적으로 R3만 포함하는 해석이 자연스럽다.**

### Prefill Table

N_prefill = B*S

| Kernel | FLOPs | Minimal bytes | Algorithmic OI |
| --- | --- | --- | --- |
| Q/K/V/O proj | 2*(B*S)*H^2 | 4*(B*S)*H + 0.5*H^2 | (2*B*S*H^2) / (4*B*S*H + 0.5*H^2) |
| Gate proj | 2*(B*S)*H*I | 2*(B*S)*(H+I) + 0.5*H*I | (2*B*S*H*I) / (2*B*S*(H+I) + 0.5*H*I) |
| Up proj | 2*(B*S)*H*I | 2*(B*S)*(H+I) + 0.5*H*I | (2*B*S*H*I) / (2*B*S*(H+I) + 0.5*H*I) |
| Down proj | 2*(B*S)*I*H | 2*(B*S)*(H+I) + 0.5*H*I | (2*B*S*I*H) / (2*B*S*(H+I) + 0.5*H*I) |
| Fused self-attention | 4*B*S^2*H | 8*B*S*H | S/2 |
| RoPE | O(B*S*H) | O(B*S*H) | O(1) |
| RMSNorm | O(B*S*H) | O(B*S*H) | O(1) |
| SiLU + gate multiply | O(B*S*I) | O(B*S*I) | O(1) |
| KV4 cache write | small compute, store-dominated | store-dominated | very low |
| SpinQuant R3 online Hadamard | N_had*log2(g) | 4*N_had | log2(g)/4 |

메모:
- 여기서 g는 Hadamard block size다.
- A16W4KV4에서는 activation이 16-bit이므로, SpinQuant의 online 추가 커널은 보통 R3만 따로 보면 된다.

### Decode Table

N_decode = B (한 decode step에서 sequence마다 1 token씩 처리)

| Kernel | FLOPs | Minimal bytes | Algorithmic OI |
| --- | --- | --- | --- |
| Q/K/V/O proj | 2*B*H^2 | 4*B*H + 0.5*H^2 | (2*B*H^2) / (4*B*H + 0.5*H^2) |
| Gate proj | 2*B*H*I | 2*B*(H+I) + 0.5*H*I | (2*B*H*I) / (2*B*(H+I) + 0.5*H*I) |
| Up proj | 2*B*H*I | 2*B*(H+I) + 0.5*H*I | (2*B*H*I) / (2*B*(H+I) + 0.5*H*I) |
| Down proj | 2*B*I*H | 2*B*(H+I) + 0.5*H*I | (2*B*I*H) / (2*B*(H+I) + 0.5*H*I) |
| Fused decode attention | 4*B*H*L | B*H*(L+4) | 4*L / (L+4) |
| RoPE | O(B*H) | O(B*H) | O(1) |
| RMSNorm | O(B*H) | O(B*H) | O(1) |
| SiLU + gate multiply | O(B*I) | O(B*I) | O(1) |
| KV4 cache write | small compute, store-dominated | store-dominated | very low |
| SpinQuant R3 online Hadamard | N_had*log2(g) | 4*N_had | log2(g)/4 |

decode attention의 bytes:
- Q read: 2*B*H
- K-cache read: 0.5*B*H*L
- V-cache read: 0.5*B*H*L
- output write: 2*B*H
- 합: B*H*(L + 4)

### 핵심 해석

**Prefill**
- dense proj OI는 B*S에 비례해서 빠르게 증가한다.
- fused attention OI는 S/2라서 sequence가 길수록 커진다.
- 그래서 prefill은 batch와 prompt가 커질수록 **compute-friendly** 해진다.

**Decode**
- dense proj OI는 B에만 비례해서 증가한다.
- fused decode attention OI는 4*L/(L+4) 이므로, L이 커져도 결국 4 근처에서 포화된다.
- 그래서 decode는 특히 attention/KV path가 **구조적으로 memory-sensitive** 하다.

즉, 같은 모델이어도 대체로
- prefill: MXU, on-chip feed bandwidth 쪽을 보기 쉬움
- decode: HBM/KV-cache path, pseudo-channel 수, outstanding request 수를 보기 쉬움

### Llama-2 7B 상수 대입 (H=4096, I=11008)

#### Prefill

Q/K/V/O proj: `OI = 2048*B*S / (B*S + 512)`

Gate/Up/Down proj: `OI ≈ 2985.2*B*S / (B*S + 746.3)`

Fused self-attention: `OI = S/2`

#### Decode

Q/K/V/O proj: `OI = 2048*B / (B + 512)`

Gate/Up/Down proj: `OI ≈ 2985.2*B / (B + 746.3)`

Fused decode attention: `OI = 4*L / (L + 4)`

### 숫자 예시

#### Prefill B=1, S=128
- Q/K/V/O proj: OI = 2048*128 / (128 + 512) = 409.6
- MLP proj: OI ≈ 2985.2*128 / (128 + 746.3) ≈ 436.7
- Attention: OI = 128/2 = 64

#### Prefill B=8, S=512
- Q/K/V/O proj: OI = 2048*4096 / (4096 + 512) ≈ 1820.4
- MLP proj: OI ≈ 2985.2*4096 / (4096 + 746.3) ≈ 2525.1
- Attention: OI = 512/2 = 256

#### Decode B=1, L=2048
- Q/K/V/O proj: OI = 2048 / (1 + 512) ≈ 3.99
- MLP proj: OI ≈ 2985.2 / (1 + 746.3) ≈ 4.00
- Attention: OI = 4*2048 / (2048 + 4) ≈ 3.99

#### Decode B=8, L=2048
- Q/K/V/O proj: OI = 2048*8 / (8 + 512) ≈ 31.5
- MLP proj: OI ≈ 2985.2*8 / (8 + 746.3) ≈ 31.7
- Attention: OI ≈ 3.99

#### Decode B=64, L=2048
- Q/K/V/O proj: OI = 2048*64 / (64 + 512) ≈ 227.6
- MLP proj: OI ≈ 2985.2*64 / (64 + 746.3) ≈ 235.7
- Attention: OI ≈ 3.99

### 한 줄 결론

- prefill은 OI가 B*S 또는 S에 의해 빠르게 커진다.
- decode는 dense proj만 B에 따라 커지고, attention은 거의 항상 OI <= 4 근처다.

**decode target accelerator라면 HBM/KV path가 먼저 병목이 될 가능성이 높고, prefill target accelerator라면 MXU와 on-chip data delivery가 먼저 병목이 될 가능성이 높다.**

---

## Theoretical Bandwidth/Throughput

### Naive FPINT Hardware (916cc66824ae)

#### Memory Bandwidth

| Memory | Configuration | Bandwidth |
| --- | --- | --- |
| **HBM** | PC당 64B port, 100MHz. N_PC개 사용 | 6.25*N_PC [GB/s]. N_PC==32 → **200.0 GB/s** |
| **Cache system (L2 only)** | 64B cache line, 1 port (dcache disable, 1 socket) | **6.25 GB/s** |
| **LMEM** | 8 banks, XLEN(64bit) port width | **6.25 GB/s** (64B/cycle) |
| **TMEM** | 64B bank N개, 100MHz, single port | N==32 → **200 GB/s** |
| **REGS** | 4 bank, 3 read + 1 write port, bank당 64B | 256B/cycle → **25 GB/s** |

#### MXU

- Throughput: 2*MXU_ROW*MXU_COL*F → 32x32, 100M → **200 Gops/s**
- Input req bandwidth: 32 x 2B / cycle → **6.25 GB/s**
- Output req bandwidth: 32 x 2B / cycle → **6.25 GB/s** (dataflow에 따라 accumulation 때문에 요구 사항이 줄어들 수 있음)
- Weight req bandwidth: 512B / cycle → **50 GB/s** (1 cycle에 weight 전부 갈기 가능, reuse factor 높아지면 요구량 감소)

#### SIMD Execution Unit Throughput

##### Execution Unit Sizing

| Unit | Lanes | Blocks | Source |
| --- | --- | --- | --- |
| ALU (INT) | `NUM_ALU_LANES` = `SIMD_WIDTH` | `NUM_ALU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:362-365` |
| FPU (FP) | `NUM_FPU_LANES` = `SIMD_WIDTH` | `NUM_FPU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:370-373` |
| TCU | `NUM_TCU_LANES` = `NUM_THREADS` | `NUM_TCU_BLOCKS` = `ISSUE_WIDTH` | `VX_config.vh:399-401` |
| LSU | `NUM_LSU_LANES` = `SIMD_WIDTH` | `NUM_LSU_BLOCKS` = 1 | `VX_config.vh:378-381` |

Derived: `SIMD_WIDTH = NUM_THREADS`, `ISSUE_WIDTH = UP(NUM_WARPS / 16)`

##### ALU Throughput

| Operation | Implementation | Pipeline? | Latency | Throughput (instr/cycle/block) |
| --- | --- | --- | --- | --- |
| ADD/SUB, AND/OR/XOR, SLL/SRL/SRA | Combinatorial (`VX_alu_int.sv`) | Single-cycle | 1 cycle | **1** |
| Branch (BEQ, BLT, ...) | Combinatorial + buffer | 1 cycle | **1** |
| MUL/MULH | Pipelined shift register (`VX_alu_muldiv.sv:81`) | Yes | `LATENCY_IMUL` cycles | **1** |
| DIV/REM | Serial divider (`VX_serial_div`) | No (blocking) | ~`XLEN` cycles | **1/XLEN** |

- **MUL is fully pipelined**: accepts new instruction every cycle despite multi-cycle latency.
- **DIV is serial**: blocks the unit for ~XLEN cycles per instruction.

##### FPU Throughput

PE serialization: `NUM_PEs = UP(NUM_FPU_LANES / PE_RATIO)`, `BATCH_SIZE = NUM_FPU_LANES / NUM_PEs`

| Operation | Latency | PE_RATIO | NUM_PEs | BATCH_SIZE | Instr Throughput |
| --- | --- | --- | --- | --- | --- |
| FMA (FADD/FMUL/FMADD) | `LATENCY_FMA` | 1 | `NUM_FPU_LANES` | 1 | **1 instr/cycle** |
| FDIV | `LATENCY_FDIV` | 8 | `UP(NUM_FPU_LANES/8)` | `NUM_FPU_LANES / NUM_PEs` | **1 / BATCH_SIZE instr/cycle** |
| FSQRT | `LATENCY_FSQRT` | 8 | `UP(NUM_FPU_LANES/8)` | same | **1 / BATCH_SIZE instr/cycle** |
| FCVT | `LATENCY_FCVT` | 8 | `UP(NUM_FPU_LANES/8)` | same | **1 / BATCH_SIZE instr/cycle** |
| FNCP (misc) | `LATENCY_FNCP` | 2 | `UP(NUM_FPU_LANES/2)` | 2 | **1/2 instr/cycle** |

**FMA is the critical path for GEMM.** With PE_RATIO=1, every lane has its own FMA PE → fully pipelined.

##### TCU Throughput

```
MACs_per_uop = TCU_TC_M × TCU_TC_N × TCU_TC_K
MACs_per_WMMA = TCU_TILE_M × TCU_TILE_N × TCU_TILE_K = TCU_UOPS × MACs_per_uop
Cycles_per_WMMA = TCU_UOPS (1 uop/cycle)
```

##### Issue Dispatch Model

ALU, FPU, LSU, TCU have independent dispatch slots. Max concurrent issues = NUM_EX_UNITS × ISSUE_WIDTH = 5 × ISSUE_WIDTH.

However, all share the **same operand collector** (1 instruction dispatched per cycle per OPC) — this is the true issue bottleneck.

#### Concrete Values (NUM_THREADS=8, XLEN=64)

```
SIMD_WIDTH     = 8
ISSUE_WIDTH    = 1
NUM_ALU_LANES  = 8
NUM_FPU_LANES  = 8
NUM_TCU_LANES  = 8
LATENCY_IMUL   = 3
LATENCY_FMA    = 4 (DPI/FPNEW) or 16 (Vivado DSP)
LATENCY_FDIV   = 15/16/28
LATENCY_FSQRT  = 10/16/28
LATENCY_FCVT   = 5
LATENCY_FNCP   = 2
```

##### ALU Throughput (concrete)

| Operation | Lanes | Latency | Pipeline | Ops/cycle |
| --- | --- | --- | --- | --- |
| ADD/SUB/logic/shift | 8 | 1 cycle | Yes | **8 ops** |
| MUL/MULH | 8 | 3 cycles | Yes (pipelined) | **8 ops** |
| DIV/REM | 8 | ~64 cycles | No (serial) | **0.125 ops** |

##### FPU Throughput (concrete)

| Operation | NUM_PEs | BATCH_SIZE | Latency | Throughput (ops/cycle) |
| --- | --- | --- | --- | --- |
| **FMA/FADD/FMUL** | 8 | 1 (passthru) | 4 cycles | **8 ops (= 16 FLOPs)** |
| FDIV | 1 | 8 | 15 cycles | **1 op** per instr |
| FSQRT | 1 | 8 | 10 cycles | **1 op** per instr |
| FCVT | 1 | 8 | 5 cycles | **1 op** per instr |
| FNCP | 4 | 2 | 2 cycles | **4 ops** per instr |

##### TCU Throughput (concrete, NUM_THREADS=8)

| Parameter | Value |
| --- | --- |
| TCU_TC_M × TCU_TC_N × TCU_TC_K | 4 × 2 × 2 |
| MACs per micro-op | **16 MACs** |
| TCU_UOPS per WMMA | 32 |
| MACs per WMMA | 8 × 8 × 8 = **512 MACs** |
| Cycles per WMMA | 32 cycles |
| **MACs / cycle** | **16 MACs/cycle** |

##### Peak Throughput Summary

| Unit | Operation | Ops/cycle | FLOPs/cycle | Bits read | Bits written |
| --- | --- | --- | --- | --- | --- |
| **ALU** | ADD/logic | 8 | 8 | 1024 | 512 |
| **ALU** | MUL (pipelined) | 8 | 8 | 1024 | 512 |
| **FPU** | FMA | 8 | **16** | 1536 | 512 |
| **TCU** | WMMA uop | 1 | **32** (16 MAC) | 1536 | 512 |

#### 100% Utilization Bandwidth Requirements

##### Operand Collector

```
Read bandwidth  = 3 × 512 = 1,536 bits/cycle (192 bytes/cycle)
Write bandwidth = 1 × 512 = 512 bits/cycle (64 bytes/cycle)
Total           = 2,048 bits/cycle (256 bytes/cycle)
```

| Unit | Source Operands | Read 요구 (bits/cycle) | Write 요구 (bits/cycle) | Reg File 공급 충분? |
| --- | --- | --- | --- | --- |
| **ALU (ADD)** | rs1, rs2 | 1,024 | 512 | Yes |
| **ALU (MUL)** | rs1, rs2 | 1,024 | 512 | Yes |
| **FPU (FMA)** | rs1, rs2, rs3 | 1,536 | 512 | Yes (exact match) |
| **TCU (uop)** | rs1, rs2, rs3 | 1,536 | 512 | Yes (exact match) |

##### Bottleneck: Operand Collector Issue Rate

```
NUM_OPCS = UP(NUM_WARPS / (4 × ISSUE_WIDTH)) = 1
Issue rate = 1 instruction / cycle / OPC
```

Warp-level parallelism hides pipeline latency:
```
FMA pipeline latency = 4 cycles, Available warps = 4
→ 100% FPU utilization 달성 가능

MUL pipeline latency = 3 cycles
→ 3 warps로 충분, 4 warps면 여유 있음
```

##### Data Supply: Register ← Memory

```
LSU → Register: 512 bits/cycle
ALU/FPU 소비:  최대 1,536 bits/cycle (read) + 512 bits/cycle (write)
```

| Workload | Compute/load ratio | Register data 충분 조건 |
| --- | --- | --- |
| GEMM (tiled) | O(N) compute per O(1) load | 높은 reuse → 쉽게 충족 |
| Element-wise | 1:1 | **50% utilization** |
| Reduction | N:1 | 높은 reuse → 쉽게 충족 |

#### Throughput Diagram

```
                        Operand Collector (1 instr/cycle)
                        +-------------------------------------+
       Reg File --------| 3 read x 512b + 1 write x 512b     |
       (4 banks)        +--------+----------------------------+
                                 | dispatch (1 instr/cycle to one of:)
                  +--------------+--------------+--------------+
                  v              v              v              v
            +----------+  +----------+  +----------+  +----------+
            | ALU x8   |  | FPU x8   |  | TCU x8   |  | LSU x8   |
            | 8 ops/c  |  | 16FLOP/c |  | 16MAC/c  |  | 512b/c   |
            | (1 cyc)  |  | (4 cyc)  |  | (32 cyc) |  | (1 cyc)  |
            +----------+  +----------+  +----------+  +----------+
             INT arith     FMA peak      WMMA peak     Memory

       Warp interleaving: 4 warps hide pipeline latency
       -> FMA 4-cycle latency / 4 warps = 100% utilization possible
```

#### TCU Register File Bandwidth Detail

**Tile dimensions (NUM_THREADS=8):**

| Parameter | Value |
| --- | --- |
| TCU_TILE_M | 8 |
| TCU_TILE_N | 8 |
| TCU_TILE_K | 8 |
| One WMMA | C[8x8] = A[8x8] . B[8x8] + C[8x8] |

**Block dimensions (micro-op granularity):**

| Parameter | Value |
| --- | --- |
| TCU_TC_M | 4 |
| TCU_TC_N | 2 |
| TCU_TC_K | 2 |
| TCU_M_STEPS | 2 |
| TCU_N_STEPS | 4 |
| TCU_K_STEPS | 4 |
| TCU_UOPS | 32 micro-ops / WMMA |

**WMMA Total Register Traffic:**

| | Computation | Value |
| --- | --- | --- |
| Read total | 32 uops x 1,536 bits | 49,152 bits (6,144 bytes) |
| Write total | 32 uops x 512 bits | 16,384 bits (2,048 bytes) |
| WMMA total | | 65,536 bits (8,192 bytes = 8 KB) |
| Minimum latency | 32 uops (no bank conflicts) | 32 cycles |

#### End-to-End Data Path

```
                            1536 b/cyc read
  Register File (4 banks) ----------------->  TCU (8 lanes, 4x2 TC block)
                          <-----------------
                            512 b/cyc write

                            512 b/cyc
  Register File <------------------------->  LSU (8 lanes)
                                                |
                            512 b/cyc          v
  LMEM (8 banks, 4 MB)   <--------------->  LSU
                                                |
                            512 b/cyc          v
  L2 Cache (1 bank, 1 MB) <-------------->  L1 bypass (1 port)
                                                |
                            512 b/cyc          v
  External Memory (2 banks) <------------>  L2 (1 port)
```

| Path | Bandwidth / Cycle | Relative |
| --- | --- | --- |
| Register -> TCU (read) | 1,536 bits | 3x |
| TCU -> Register (write) | 512 bits | 1x |
| Register <-> LMEM (via LSU) | 512 bits | 1x |
| LMEM <-> L2 | 512 bits | 1x |
| L2 <-> External Memory | 512 bits | 1x |

**Key Observations:**
1. Register read bandwidth (1,536 bits/cycle) is the widest path.
2. L1 -> L2 single port is the primary memory-side bottleneck.
3. LMEM (8 banks) provides bank-conflict-free parallel access for all 8 threads — preferred high-bandwidth data store for TCU operands.
4. TCU requires 32 cycles per WMMA (8x8x8 tile), moving 8 KB through register file.
5. Data staging strategy: stage operands in LMEM, load into registers before TCU execution.

#### Interconnect Bandwidth

| Path | Configuration | Bandwidth |
| --- | --- | --- |
| HBM <-> cache system | merged interface | **6.25 GB/s** (max) |
| LMEM <-> MXU ports | 1 port, 8B/cycle | **0.78 GB/s** |
| DMA <-> cache | 1 port, 64B/cycle | **6.25 GB/s** |
