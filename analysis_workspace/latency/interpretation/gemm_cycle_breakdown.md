# GEMM Cycle Breakdown and Child FIFO Interpretation

## Purpose

The previous `wait_reg` aggregation is not a cycle-exclusive latency breakdown.
`WAIT` cycles can overlap with MXU compute, LDMA, or DMA activity, so summing
wait buckets does not equal `gemm_total`.

The useful breakdown is a cycle partition:

```text
denominator = !queues_idle || gemm_unit_computing
```

This matches `VX_gemm_ctrl.perf_total_cycles_r`. Each denominator cycle is
classified by the tuple of active datapath operations. If no datapath operation
is active, the cycle is classified as `OTHER` and then split into sync/control
categories.

## Reproduction

```python
import cycle_util

fsdb = "build/logs/fpint_improve_m1_k256_n256/xrtsim_vcs/vcs_cosim.fsdb"
breakdown = cycle_util.analyze_gemm_cycle_breakdown(fsdb)

breakdown["metadata"]
breakdown["operation_tuples"]
breakdown["other_control_breakdown"]
breakdown["child_fifo_summary"]
breakdown["child_empty_breakdown"]
```

CSV export:

```python
cycle_util.export_gemm_cycle_breakdown(
    breakdown,
    "analysis_workspace/latency/gemm_cycle_breakdown",
    prefix="fpint_improve_m1_k256_n256",
)
```

## Measured Result

FSDB:

```text
build/logs/fpint_improve_m1_k256_n256/xrtsim_vcs/vcs_cosim.fsdb
```

Total-cycle validation:

| Metric | Cycles |
|---|---:|
| Derived denominator cycles | 4821 |
| `perf_total_cycles_r` | 4821 |
| Operation tuple sum | 4821 |
| Operation-active cycles | 4155 |
| Operation `OTHER` cycles | 666 |
| All child FIFOs empty | 349 |

Top operation tuples:

| Tuple | Cycles | Percent |
|---|---:|---:|
| `MXU_COMPUTE` | 2134 | 44.3% |
| `OTHER` | 666 | 13.8% |
| `MXU_COMPUTE+LDMA_INPUT+LDMA_WEIGHT+LDMA_SZ` | 456 | 9.5% |
| `MXU_COMPUTE+LDMA_SZ` | 399 | 8.3% |
| `HBM_DMA` | 231 | 4.8% |
| `LDMA_WEIGHT+LDMA_SZ` | 194 | 4.0% |
| `LDMA_WEIGHT` | 123 | 2.6% |
| `LDMA_OUTPUT` | 80 | 1.7% |
| `MXU_STALL` | 61 | 1.3% |

`OTHER` is not unknown work. It is sync/control work that still counts in
`gemm_total` because the parent queue/stage is active:

| `OTHER` category | Cycles | Percent of `OTHER` | Percent of total |
|---|---:|---:|---:|
| `SYNC_WAIT_BLOCKED` | 217 | 32.6% | 4.5% |
| `SYNC_WAIT_ACCEPT` | 198 | 29.7% | 4.1% |
| `SYNC_NOTIFY_ACCEPT` | 78 | 11.7% | 1.6% |
| `SYNC_NORMAL_ACCEPT` | 148 | 22.2% | 3.1% |
| `PARENT_STAGE_ONLY` | 25 | 3.8% | 0.5% |

## Child FIFO Finding

The parent queue is not empty for the whole GEMM window, but child FIFOs are
not continuously holding useful work.

| FIFO | Not-empty cycles | Not-empty percent | Head normal | Head notify |
|---|---:|---:|---:|---:|
| input | 3640 | 75.5% | 64 | 3576 |
| weight | 1345 | 27.9% | 64 | 1281 |
| sz | 1664 | 34.5% | 832 | 832 |
| output | 112 | 2.3% | 8 | 104 |
| hbm_dma | 585 | 12.1% | 356 | 229 |
| any child not empty | 4472 | 92.8% | - | - |
| all children empty | 349 | 7.2% | - | - |

All-child-empty cycles are short but real. They are fully in the operation
`OTHER` bucket:

| All-child-empty category | Cycles | Percent of all-child-empty |
|---|---:|---:|
| `SYNC_WAIT_BLOCKED` | 77 | 22.1% |
| `SYNC_WAIT_ACCEPT` | 194 | 55.6% |
| `SYNC_NORMAL_ACCEPT` | 77 | 22.1% |
| `PARENT_STAGE_ONLY` | 1 | 0.3% |

The longest all-child-empty run is 5 cycles. This indicates that child FIFO
empty time is not one huge idle region; it is repeated small bubbles caused by
ordered sync/control handling.

## Interpretation

The original expectation was that child FIFOs would almost always contain
pending commands and hide LDMA/DMA/MXU latency. The measurement shows a more
specific behavior:

1. The parent queue has pending commands throughout the GEMM total window.
2. Pending parent commands do not imply child FIFOs contain useful normal work.
3. Many child FIFO not-empty cycles are headed by `NOTIFY`, not by a normal
   LDMA/DMA/MXU command.
4. 349 cycles have all child FIFOs empty while the parent/sync path is still
   processing `WAIT` or normal command acceptance.
5. 666 cycles have no active datapath operation and are sync/control overhead.

Therefore, latency is not fully hidden by the current child FIFO structure.
The main issue is not simply FIFO depth. The current ordered parent stream and
centralized `VX_gemm_sync` handling can create head-of-line blocking before
future useful commands are dispatched into child FIFOs.

## Implication for Optimization

Potential optimization should focus on reducing ordered sync/control bubbles
and allowing independent future work to reach child routes earlier:

| Direction | Rationale |
|---|---|
| Decouple independent sync domains | A wait on one resource should not block dispatch of unrelated child-route commands. |
| Move toward per-route wait/notify handling | Reduces centralized head-of-line blocking in `VX_gemm_sync`. |
| Allow safe lookahead dispatch past unrelated waits | Keeps child FIFOs populated with useful normal work instead of waiting behind sync commands. |
| Add command IDs for debug | Current child debug can expose start/done pulses, but exact per-command pairing is limited for some routes. |

