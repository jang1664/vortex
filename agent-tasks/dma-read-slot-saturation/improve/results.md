# Improve external DMA read-slot measurements

TH16/MXU16, N-fast, K=N512, Q32, QCOL, WTRANS0, one repetition. Each depth uses a fresh simulator build for M4 and the same executable for M256. Exact base configuration is sourced from `agent-tasks/fpint-gemm-latency-compare/improve.sh`; only `TMEM_DMA_RD_OUTSTANDING_SLOT` is overridden.

| Slots per DMA engine | M | GEMM cycles | Core cycles | Acceptance |
|---:|---:|---:|---:|---|
| 16 | 4 | 6,431 | 12,205 | PASS |
| 16 | 256 | 272,856 | 278,622 | PASS |
| 32 | 4 | 6,431 | 12,205 | PASS |
| 32 | 256 | 272,856 | 278,622 | PASS |

All four runs have zero wrapper/runner return codes, deterministic PASS, no strict failures, one observer interval, nonempty FSDB, and no source changes during execution. Immutable manifests and result records are under `runs/depth<slots>-m<M>/`. The 16-to-32 increase changes neither GEMM/core cycles nor printed PERF counters on either shape. Root FSDB analysis confirms equal phase lengths and DMA timing at 16 and 32 on both shapes. On M256, the read/write busy unions are 15,861/1,308 cycles and aggregate channel-active cycles are 136,113 at both depths. Four summed channel cycles of capacity-full blocking at depth 16 disappear at 32 without changing request timing, phases, or total latency. The measured saturation configuration is therefore 16 slots per engine; depth 64 is not needed.
