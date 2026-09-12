# External DMA read-slot saturation and phase comparison

> Historical cycle measurements: this DMA-depth sweep predates naive address-safe PSUM read priority. The selected external DMA capacities remain improve16 / naive32; current cycle comparisons are in [the cycle table](fpint_gemm_latency.md), with scheduler results in [the new sweep](fpint_gemm_read_priority_sweep.md).

Selected external DMA read slots: **improve 16 per channel** and **naive 32**. These are response-RAM/OOO slots in the external DMA, independent of the eight local Weight response slots and sixteen naive PSUM slots. TH16/MXU16, M4/M256, K=N512, QBLK32, QCOL, WTRANS0, one repetition, current N-fast microtile traversal.

Improve uses eight aligned DMA units; naive uses one misaligned DMA unit. The source and destination paths, engine count, and data-realignment behavior remain different. This is a comparison after sizing each DMA, not an isolated test of HBM bandwidth.

The selected response-data RAM capacity is improve 8 × 16 × 64 B = 8,192 B and naive 32 × 128 B = 4,096 B, excluding metadata and downstream queues. The dual-port RAM instances are [aligned DMA](../../../hw/rtl/core/VX_dma_unit_align.sv:1466) and [misaligned DMA](../../../hw/rtl/core/VX_dma_unit_misal.sv:716).

## Capacity sweep

DMA read-active cycles are the union of cycles in which at least one external DMA unit is active in the DRAM-to-operand-memory direction. They include setup, response latency, and destination backpressure; they overlap GEMM computation and must not be added to total GEMM cycles.

### improve

| Slots | M4 GEMM | M256 GEMM | M4 DMA read-active | M256 DMA read-active | M4 max occupied | M256 max occupied |
|---:|---:|---:|---:|---:|---:|---:|
| 8 | 6,433 | 272,869 | 1,393 | 16,238 | 8 | 8 |
| 16 | 6,431 | 272,856 | 1,323 | 15,861 | 14 | 16 |
| 32 | 6,431 | 272,856 | 1,323 | 15,861 | 14 | 16 |

### naive

| Slots | M4 GEMM | M256 GEMM | M4 DMA read-active | M256 DMA read-active | M4 max occupied | M256 max occupied |
|---:|---:|---:|---:|---:|---:|---:|
| 16 | 15,867 | 671,929 | 10,769 | 61,837 | 16 | 16 |
| 32 | 15,970 | 671,993 | 10,667 | 60,501 | 26 | 32 |
| 64 | 15,970 | 671,993 | 10,667 | 60,501 | 26 | 64 |

A full response RAM alone does not establish a throughput bottleneck: a destination-limited DMA can keep the RAM full even after its total transfer time saturates. Likewise, removing slot-full waiting can move waiting to the source request interface. The sweep therefore compares measured transfer activity and whole-GEMM cycles, with a larger capacity as confirmation.

## Selection and whole-GEMM tradeoff

**improve: select 16, confirmed with 32.** Both matrix sizes have identical GEMM/core cycles, all five phase lengths, and DMA read/write-active times at these two capacities. This is the measured plateau for these workloads; it is not a guarantee for other shapes.

**naive: select 32, confirmed with 64.** Both matrix sizes have identical GEMM/core cycles, all five phase lengths, and DMA read/write-active times at these two capacities. This is the measured plateau for these workloads; it is not a guarantee for other shapes.

Naive M256 still fills the RAM at depth64. Full-with-pending-read cycles fall from 20,670 at depth32 to 16,572 at depth64, while source request-stall cycles rise from 13,598 to 15,226. However, destination-write stalls remain 26,100 cycles and DMA read-active time remains 60,501 cycles. Extra buffering shifts where requests wait without improving delivery time. Therefore the throughput plateau is depth32 even though depth64 can also become full.

The naive setting targets DMA transfer saturation. The smallest whole-GEMM result in this sweep remains depth16:

| M | Depth16 GEMM | Selected GEMM | GEMM increase | DMA read-active reduction |
|---:|---:|---:|---:|---:|
| 4 | 15,867 | 15,970 | 103 (0.6491%) | 102 |
| 256 | 671,929 | 671,993 | 64 (0.0095%) | 1,336 |

The phase evidence locates the regression in the Input interval, while the external DMA itself finishes its read-active work sooner. Changed contention and overlap with LMEM operand/PSUM traffic are a timing interpretation, not a separately isolated causal experiment.

## Additive wall-clock phases

Boundaries are configuration acceptance, first accepted Input, last accepted Input, last accumulator write, final output-store completion, and GEMM completion-valid. Phase lengths are distances between these edges and sum exactly to GEMM latency. The Output tail is only the work remaining after the last accumulator write; it is not the total time spent on all output transfers.

### M4

| Phase | Improve | Naive | Naive minus improve |
|---|---:|---:|---:|
| Preparation to first Input | 90 | 762 | 672 |
| First to last Input | 6,058 | 15,103 | 9,045 |
| Last Input to last accumulator write | 16 | 30 | 14 |
| Remaining Output stores | 264 | 72 | -192 |
| Completion notification | 3 | 3 | 0 |
| **GEMM total** | **6,431** | **15,970** | **9,539** |

### M256

| Phase | Improve | Naive | Naive minus improve |
|---|---:|---:|---:|
| Preparation to first Input | 152 | 1,582 | 1,430 |
| First to last Input | 270,341 | 669,680 | 399,339 |
| Last Input to last accumulator write | 16 | 36 | 20 |
| Remaining Output stores | 2,344 | 692 | -1,652 |
| Completion notification | 3 | 3 | 0 |
| **GEMM total** | **272,856** | **671,993** | **399,137** |

## Overlapping activity and stalls

| Observation | Improve M4 | Naive M4 | Improve M256 | Naive M256 |
|---|---:|---:|---:|---:|
| DMA read-active | 1,323 | 10,667 | 15,861 | 60,501 |
| DMA write-active | 263 | 164 | 1,308 | 5,288 |
| Input valid but not ready | 26 | 9,574 | 0 | 60,012 |
| Input backpressure while external DMA idle | 18 | 2,924 | 0 | 35,080 |
| Compute operand waiting for Weight | 386 | 9,962 | 1 | 11 |
| PSUM is the remaining postprocessing blocker | 0 | 8,932 | 0 | 356,262 |

These counters overlap across pipeline stages; their sums are not latency attribution.

| M | Read payload, both backends | Improve effective read B/cycle | Naive effective read B/cycle |
|---:|---:|---:|---:|
| 4 | 180,224 B | 136.22 | 16.90 |
| 256 | 1,376,256 B | 86.77 | 22.75 |

This delivery rate divides useful read payload by read-active wall-clock cycles. It includes the DMA and destination-memory path, so it cannot identify physical HBM bandwidth alone. The equal payload and shorter improve DMA activity support a memory-delivery advantage; PSUM ordering and compute overlap explain why GEMM speedup is much smaller than the delivery-rate ratio.

Preparation benefits from improve's parallel direct DMA launch and delivery path. Naive programs and polls descriptors through its [DMA executor](../../../hw/rtl/core/gemm/VX_naive_external_dma_executor.sv:543), while improve launches [multiple DMA channels](../../../hw/rtl/mem/VX_dma_engine.sv:136).

The Input interval contains both operand delivery and backpressure from downstream computation. At M4, Weight delivery is exposed because each weight microtile serves only four rows. At M256, each weight microtile serves 128 rows and naive's LMEM PSUM path dominates the measured postprocessing waits. Naive retains conservative [bank-set write/read ordering](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:578); increasing external DMA slots does not remove this restriction.

| Naive PSUM ordering observation | M4 | M256 |
|---|---:|---:|
| Read request blocked by bank-set ordering | 9,070 | 357,280 |
| Prior queued writes to the same bank set | 8,859 | 348,375 |
| Current write request to the same bank set | 2,022 | 111,349 |

Pending and current conflicts can occur together. The pending counter remains nonzero until all reserved write lanes reach their actual LMEM banks; it is broader than an exact same-address hazard check. These observations identify an internal-memory dependency limit that increasing external DMA response storage cannot directly remove.

Improve must [copy accumulator slices to TMEM before external Output DMA](../../../hw/rtl/core/gemm/VX_gemm_fsm.sv:2322). Naive [stores an output macro tile from LMEM](../../../hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv:198). The differing paths and amount of output work already overlapped with computation explain why the residual Output tail need not favor improve.

## Evidence and scope

All measured candidates passed `xrt-vcs-sim` using the configured-build wrapper, unchanged source manifests, and deterministic `tools/verify_rtl.py` checks. The FSM, arithmetic pipeline, Weight/PSUM capacities and layouts were fixed across the sweep. `VX_gpu_pkg.sv` now grows the relevant tag width with each backend's external slot override; default effective widths are preserved. No synthesis or reset microtests were used. The selected production profiles expand to exactly the tested macros; RTL and application hashes still match the selected runs after the two config edits. Improve depth8 reuses the prior N-fast captures; depths16/32 and all naive candidates were run freshly.

Reproduction, accepted run manifests, FSDBs and strict-preedge analysis are under `agent-tasks/dma-read-slot-saturation/`. The active RAM bindings and tag constraints are documented in `audit.md`. Current GEMM/core comparisons are in [the cycle-only report](fpint_gemm_latency.md).

### Accepted waveform runs

| Backend | Depth | M | Run directory |
|---|---:|---:|---|
| improve | 8 | 4 | `agent-tasks/improve-nfast/runs/improve-m4` |
| improve | 8 | 256 | `agent-tasks/improve-nfast/runs/improve-m256` |
| improve | 16 | 4 | `agent-tasks/dma-read-slot-saturation/improve/runs/depth16-m4` |
| improve | 16 | 256 | `agent-tasks/dma-read-slot-saturation/improve/runs/depth16-m256` |
| improve | 32 | 4 | `agent-tasks/dma-read-slot-saturation/improve/runs/depth32-m4` |
| improve | 32 | 256 | `agent-tasks/dma-read-slot-saturation/improve/runs/depth32-m256` |
| naive | 16 | 4 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots16-m4` |
| naive | 16 | 256 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots16-m256` |
| naive | 32 | 4 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots32-m4` |
| naive | 32 | 256 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots32-m256` |
| naive | 64 | 4 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots64-m4` |
| naive | 64 | 256 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots64-m256` |

Use `python3 agent-tasks/dma-read-slot-saturation/analyze.py RUN --depth N --out CAPTURE` for each completed run, then `python3 agent-tasks/dma-read-slot-saturation/write_report.py --improve-depth 16 --naive-depth 32`. Raw FSDBs and transition caches are local ignored artifacts. Reproducers source frozen baseline profiles and add exactly one backend-specific depth override.

For cycle-specific signal annotations and RTL explanations, see [the detailed review guide](fpint_gemm_annotated_explanation.md).
