# Address Generator Go/No-Go Characterization

Date: 2026-07-21
Configuration: `configs/improve_th32_tcol32_hwexp_dcache.sh`
Target: current default `eladd_layout_fused` `tile_chunk32`

## Result

**Decision: no-go for the proposed RTL implementation.**

The current optimized kernel does not meet the plan's requirement that
address/control work account for at least 20% of dynamic kernel instructions.
The measured share is 12.362% on the representative full-warp case. Even an
impossible zero-cost generator that removes every classified instruction would
reduce total retired instructions by only 12.049%, below the 15% final gate.

The implementation plan therefore stops before ISA, simulator, kernel, or RTL
changes. This is the intended behavior of the pre-RTL gate, not an
implementation failure.

## Method

The kernel was rebuilt from the committed `fpint` source in an isolated
worktree using XLEN=64 and the selected TH32 configuration. Simx was rebuilt
with instruction debug tracing. The trace analyzer counts active lanes rather
than only warp-level issue events, matching the simulator's retired-instruction
accounting.

The classified region includes:

- Grid-strided task and `(m, chunk)` decoding.
- GEMM-C tiled base calculation.
- Row-major base calculation.
- Inner-loop integer address formation and loop control.

Loads, stores, FP16 conversion, and floating-point addition are excluded from
the address/control class. The PC ranges are recorded in
`agent-tasks/layout-fused-address-generator/analyze_trace.py` and correspond to
the generated `kernel.dump` for this source revision. The analyzer refuses a
different dump and records the verified SHA-256 in its output.

## Reproduction

From the isolated worktree, after configuring `build_addrgen` for XLEN=64 and
building the target kernel and DEBUG-enabled simx runtime:

```bash
source configs/improve_th32_tcol32_hwexp_dcache.sh
make -C build_addrgen/tests/regression/eladd_layout_fused run-simx \
  OPTS='-m 1 -k 32' \
  | python3 agent-tasks/layout-fused-address-generator/analyze_trace.py \
      build_addrgen/tests/regression/eladd_layout_fused/kernel.dump

make -C build_addrgen/tests/regression/eladd_layout_fused run-simx \
  OPTS='-m 128 -k 160' \
  | python3 agent-tasks/layout-fused-address-generator/analyze_trace.py \
      build_addrgen/tests/regression/eladd_layout_fused/kernel.dump
```

Both runs verify dump SHA-256
`d0d9b35053be347f0990b091a1a052f364e948fd99ab4d182e5a981c3b9ab8b6`.
The analyzer exits nonzero for malformed or incomplete traces, failed kernels,
missing PERF/result records, implausible trace-to-PERF count differences, or a
dump fingerprint mismatch.

## Measurements

| Shape | Kernel lane instructions | Address/control lane instructions | Share | Simx cycles | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| `M=1, K=32` | 9,849 | 417 | 4.234% | 85,754 | pass |
| `M=128, K=160` | 2,158,880 | 266,880 | 12.362% | 473,113 | pass |

For the representative case, total execution including launch/support code is
2,214,972 retired lane instructions. The classified work is therefore 12.049%
of total instructions.

The optimized `head_concat_layout_fused` control also passed on
`batch=1, seq=8, heads=8, headdim=32`, with 111,388 instructions and 113,925
simx cycles. Its existing `chunk16_packed` implementation has already removed
most fine-grained layout decoding and remains a negative control rather than a
candidate for this hardware.

## Optimistic Hardware Projection

The representative eladd launch has 640 logical 32-element tasks across 512
threads. Two projections were evaluated:

1. **Chunk-base pop:** one LD0, LD1, and ST pop per 32-element task, plus one
   reset/base/three-dimension/start sequence per stream and thread. This costs
   at least 11,136 lane instructions. Even if it replaces every classified
   instruction, the total instruction reduction is at most 11.546%.
2. **Per-element pop:** three pops per output element plus the same setup. This
   costs at least 70,656 lane instructions. The impossible best-case total
   instruction reduction falls to 8.858%.

At warp issue granularity, the trace contains 8,340 classified instructions.
Replacing them with the chunk-base setup and pops saves at most 7,992 issue
slots. Removing those slots directly from the measured cycle count gives an
optimistic 1.017x speedup. Crediting every dynamic divide with an additional
32-cycle latency still gives only about 1.019x. Both are far below the required
1.20x, and real queue stalls, execution-unit arbitration, and memory latency
would reduce the gain further.

## Why the Result Differs from the Original Expectation

The historical 35% eladd improvement came from replacing one tiled-layout
decode per element with one decode per 32-element microtile. The current
default kernel already contains that optimization. Most remaining dynamic
instructions are FP16 conversion, floating-point computation, control needed
by conversion paths, and memory operations. A hardware generator would target
the small residual left after software chunking, not the original baseline's
address overhead.

## Recommendation

- Do not add `EX_AGEN`, custom pop instructions, per-thread queues, or the
  estimated 12 KiB/core queue payload for the current eladd target.
- Keep the architecture plan as a reference if a future kernel exhibits at
  least 20% residual address/control instructions after software optimization.
- For current kernels, first try pointer recurrence, packed FP16 operations, or
  hardware FP16 conversion support; those target larger portions of the
  measured instruction stream.
