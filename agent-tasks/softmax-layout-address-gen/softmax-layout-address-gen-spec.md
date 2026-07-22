# Softmax Layout Address Generator Specification

Status: confirmed

## Goal

Minimize the kernel-cycle gap between the DMA-free `softmax/rev2` baseline and
`softmax_layout_fused` by offloading only the fused kernel's tiled load/store
address sequences. The row-major baseline is a fixed control and must never
issue address-generator instructions.

## Comparison Contract

- `softmax/rev2` remains source- and ISA-compatible with configurations where
  the address generator is disabled.
- The optimized fused variant uses the same score initialization, one-warp
  launch, LMEM cache/reductions, exponential implementation, masking, number of
  logical loads/stores, and ordinary LSU load/store instructions as rev2.
- Only GEMM-C input and GEMM-A output address formation may differ.
- Primary metric: `cycles(fused_addrgen) - cycles(softmax_rev2)`.
- Secondary metrics: fused instruction count, pop stalls, queue occupancy, and
  correctness. A fused improvement that also moves the baseline is invalid.

## V1 Address Sequence

Softmax TH32 lanes visit columns in steps of 32. For either tiled layout the
address sequence for one thread is:

```text
k0      = range_start + logical_thread_id
addr(k) = row_base + (k >> 5) * group_stride_bytes + (k & 31) * 2
k(n+1)  = k(n) + 32
```

After the first address, every address advances by `group_stride_bytes`.
V1 implements this exact sequence rather than a general multidimensional
generator. It supports separate load and store streams, including a second
store configuration for masked or padded zero stores.

## ISA

Instructions use raw R-type `CUSTOM0` encodings and are guarded by
`EXT_ADDR_GEN_ENABLE`.

| `funct7` | Stream |
| ---: | --- |
| `0x04` | fused load address stream |
| `0x05` | fused store address stream |

| `funct3` | Operation | Operands |
| ---: | --- | --- |
| 0 | `CFG_BASE` | `rs1 = 64-bit tiled row base byte address` |
| 1 | `START_RANGE` | `rs1 = group stride in bytes`, `rs2[31:0] = range start`, `rs2[63:32] = exclusive range end` |
| 2 | `POP` | blocking address result in integer `rd` |
| 3 | `RESET` | flush selected stream; no operands |

`START_RANGE` resets the selected live sequence and queue, computes the first
address for every active architectural thread, and starts background queue
generation. Software starts a new range only after consuming the previous
range. A thread whose initial `k0 >= end` produces no address and must not issue
a pop for that range.

## Hardware

- Add an optional dedicated `EX_AGEN` execution unit so an empty pop does not
  occupy ALU, LSU, or SFU dispatch and does not create cross-unit HOL blocking.
- Each architectural thread owns independent load/store live state and a
  depth-two 64-bit address queue per stream.
- Each live thread can advance its load and store stream in parallel, avoiding
  lane-serialized queue fill before a warp-wide pop.
- `POP` is blocking for every active lane in the issued SIMD slice. It commits
  through normal integer writeback and scoreboard handling.
- Configuration and reset instructions commit without register writeback.
- The feature is compiled out when `EXT_ADDR_GEN_ENABLE` is absent; default
  configurations and the baseline kernel remain unaffected.

## Software Integration

- Add raw `.insn` intrinsics for load/store base configuration, range start,
  reset, and pop.
- Add a distinct `softmax_layout_fused/rev2_addrgen` variant for controlled A/B
  testing. Do not replace or modify the row-major `softmax/rev2` path.
- The optimized fused kernel configures the load stream for `[0, k_end)`, the
  store stream for `[0, k_end)`, and, when needed, the store stream again for
  `[k_end, output_k_extent)`.
- Returned addresses feed ordinary fp16 loads/stores; the generator never
  performs memory operations.

## Verification Strategy

1. Use simx for decoder, state-machine, queue, instruction, correctness, and
   rapid cycle/instruction comparisons.
2. Use focused RTL unit tests for configuration, initial tiled mapping,
   stepping, queue full/empty behavior, blocking pop, reset, masks, and stream
   independence.
3. Use `xrt-vcs-sim` only after focused tests pass, starting with small
   B1/H1/Q2/K32 and B1/H1/Q3/K33/stride64 cases.
4. Keep Q4/K32 and Q4/K64 unmasked as the main performance cases because C4
   hardware measured 16.77% and 15.56% fused cycle overhead respectively.

## Acceptance

- All existing `softmax/rev2` counters remain unchanged in the same simx build.
- Optimized fused results pass the existing element, row-sum, padding, masking,
  and LMEM concurrency checks.
- Fused address arithmetic and total instructions decrease.
- The cycle gap to the unchanged baseline decreases on the main unmasked cases.
- Small `xrt-vcs-sim` cases pass before synthesis or FPGA integration.
