# M256 residual gap: Input request bubbles and shared local-memory traffic

> Historical pre-change analysis. The [isolated Input issue experiment](fpint_gemm_input_issue_experiment.md) removed most allocation-only cycles but made M256 5.14% slower. Its measured result supersedes the interpretation that the allocation bubble represented the dominant recoverable latency. The counts and cycle annotations below describe the earlier R1 implementation at `59be9da2`.

A structural limit identified in **naive's local Input DMA** was that it alternated a response-slot allocation cycle with a request cycle. Even if every offered LMEM request was accepted immediately, it could not request more than one 32-byte Input vector every two cycles. Improve allocates the slot on the request handshake and can request one vector per cycle. The follow-up experiment shows that removing this restriction alone does not make naive compute-bound.

There is also a separate architectural bandwidth limit: naive sends both Input and FP32 PSUM traffic through the same single-port LMEM banks. Improve's PSUM uses dedicated internal accumulator RAM. Removing the request bubble will not eliminate that difference.

## Evidence and cycle convention

This analysis reuses the latest passing naive R=1 and improve reference FSDBs. It makes no RTL/configuration changes and runs no new simulation.

| Backend | FSDB | Configuration cycle | Completion cycle | GEMM cycles |
|---|---|---:|---:|---:|
| Naive R=1 | `agent-tasks/naive-psum-read-priority/runs/v2/r1-m256/wave.fsdb` | 24,758 | 601,521 | 576,763 |
| Improve | `agent-tasks/dma-read-slot-saturation/improve/runs/depth16-m256/wave.fsdb` | 26,769 | 299,625 | 272,856 |

Both use M256/K512/N512, TH16/MXU16x16, QCOL, N-fast, Weight8. External DMA read slots are the measured plateau settings: naive32 and improve16 per channel; naive PSUM read/response slots are 16. The workload arguments are `-m 256 -k 512 -n 512 -q 32 -t 0 -d 0 -r 1`. Improve has `GEMM_TIMING_CUTS=1`; naive retains its fixed registered paths. `GEMM_SLR_PIPELINE` is disabled in both. This is a simulation cycle comparison, not an Fmax comparison.

All intervals are absolute observer cycles, half-open `[start,end)`. Cycle C's positive edge is at `10*C+5 ns`. Signals are sampled strictly before that edge, using `searchsorted(..., side='left')-1`. Different runs' absolute cycles do not identify corresponding work.

Source references below identify RTL at `59be9da2`. The analyzed Input DMA, queue, LMEM, and accumulator files match their run manifests by SHA256; the hashes are recorded in [summary.json](../../../agent-tasks/naive-m256-residual-gap/summary.json). Earlier reports describing naive's old broad PSUM bank-set fence are historical: that fence is not the cause of this R=1 result.

`CORE` abbreviates `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core`.

| Alias | FSDB hierarchy |
|---|---|
| N_INPUT | `CORE/gemm_node_naive/input_executor` |
| N_DMA | `N_INPUT/source_dma` |
| N_CONTEXT | `N_INPUT/contexts` |
| N_COMPUTE | `CORE/gemm_node_naive/u_VX_gemm_compute_core` |
| I_DMA | `CORE/gemm_node/u_tmem_subsystem/u_ldma_input` |
| I_COMPUTE | `CORE/gemm_node/u_VX_gemm_unit_v2/u_compute_core` |
| N_BANK4 | `CORE/mem_unit/local_mem/g_naive_psum_priority/req_xbar/g_bank[4]` |

## 1. The gap is almost entirely inside the Input stream

| Phase | Naive interval | Naive cycles | Improve interval | Improve cycles | Naive minus improve |
|---|---|---:|---|---:|---:|
| Configuration to first Input | [24,758,26,340) | 1,582 | [26,769,26,921) | 152 | +1,430 |
| First to last Input | [26,340,600,790) | 574,450 | [26,921,297,262) | 270,341 | +304,109 |
| Last Input to last accumulator write | [600,790,600,826) | 36 | [297,262,297,278) | 16 | +20 |
| Last accumulator write to store | [600,826,601,518) | 692 | [297,278,299,622) | 2,344 | -1,652 |
| Store to completion | [601,518,601,521) | 3 | [299,622,299,625) | 3 | 0 |
| Total | | **576,763** | | **272,856** | **303,907** |

The identical compute shape processes 262,144 Input vectors in each run. Each vector supplies16 FP16 values to16 output columns: `256*512*512/(16*16) = 262,144` vector issues. One vector per cycle is the arithmetic Input throughput target; this is not a promise that startup/output overhead can disappear.

The stream interval excludes its last Input edge, so the following exact partition contains262,143 fires:

| Compute Input condition | Naive | Improve |
|---|---:|---:|
| `req_valid && req_ready` | 262,143 | 262,143 |
| `req_valid && !req_ready` | 10,316 | 0 |
| `!req_valid` | 301,991 | 8,198 |
| Sum | 574,450 | 270,341 |
| Input transfer utilization | **45.63%** | **96.97%** |
| Delivered Input bytes/cycle,32 bytes per vector | **14.60** | **31.03** |

Thus the Input interval difference is exactly `(301,991-8,198)+10,316 = 304,109`. The Input handshake is defined at [VX_gemm_compute_core.sv:605](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L605); readiness is formed at [line632](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L632).

`!valid` alone does not prove a memory cause. The executor signals resolve it further: `N_CONTEXT/admission_valid=1` throughout the stream. Of the301,991 no-valid cycles,5,103 are blocked by the explicit Output dependency;296,888 have that dependency satisfied but `N_INPUT/data_valid=0`. The packet-valid expression is at [VX_naive_input_contexts.sv:96](../../../hw/rtl/core/gemm/VX_naive_input_contexts.sv#L96). There is no empty-context interval here.

## 2. Naive inserts an unavoidable cycle between successive row requests

The Input executor instantiates `VX_naive_qparam_dma` with16 response slots at [VX_naive_input_executor.sv:67](../../../hw/rtl/core/gemm/VX_naive_input_executor.sv#L67). This local DMA is distinct from the external DMA whose O3 depth was swept previously.

In [VX_naive_qparam_dma.sv:81](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L81), `allocate` requires `!fetch_active_r`. In [line149](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L149), the lane request requires `fetch_active_r`. Consequently, allocation and request cannot happen in the same cycle.

The sequential logic at [line295](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L295) sets `fetch_active_r` on allocation. Its `else if` request-completion branch at [line304](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L304) clears it at line307. It cannot finish the old request and initialize the next request together.

The resulting sequence is:

1. Reserve the next response slot; do not offer a lane request.
2. Offer the row's four64-bit lane requests. If all unfinished lanes accept, finish the request and clear `fetch_active_r`.
3. Return to step1 for the next row.

The restriction exists even with infinitely fast memory and infinite response capacity. A deep queue hides response latency; it does not remove this issue-cycle restriction.

Naive cycles30,321–30,336 directly show the pattern. The external DMA is idle and compute Input ready is1 throughout this window. `request_fire=0xf` means all four lane requests accept together. Allocation cycles have lane request-valid0 by the RTL equation, irrespective of the downstream ready value.

| Cycle | `allocate` | `fetch_active_r` | `request_fire` | `request_done` | Input slot occupancy | Compute Input fire |
|---:|---:|---:|---|---:|---:|---:|
| 30,321 | 0 | 1 | 0xf | 1 | 9 | 0 |
| 30,322 | 1 | 0 | 0x0 | 0 | 9 | 1 |
| 30,323 | 0 | 1 | 0xf | 1 | 9 | 1 |
| 30,324 | 1 | 0 | 0x0 | 0 | 8 | 0 |
| 30,325 | 0 | 1 | 0xf | 1 | 9 | 0 |
| 30,326 | 1 | 0 | 0x0 | 0 | 9 | 1 |
| 30,327 | 0 | 1 | 0xf | 1 | 9 | 1 |
| 30,328 | 1 | 0 | 0x0 | 0 | 8 | 0 |

The response pipeline sometimes delivers two adjacent vectors together, followed by empty cycles. Adjacent compute Input fires therefore do not refute the two-cycle request limit. The response RAM/staging path is at [lines173](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L173), [219](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L219), and [323](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L323). Full annotated rows, including request addresses, are in [naive_issue_window.csv](../../../agent-tasks/naive-m256-residual-gap/naive_issue_window.csv).

This is not an isolated window: there are239,412 request-completion intervals of exactly2 cycles during the stream, and **none of1 cycle**. Larger intervals add memory/dependency delays to that structural minimum.

Improve has the opposite implementation: [VX_gemm_stream_dma_queue.sv:329](../../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L329) offers the request when a command and free slot exist. [Line609](../../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L609) both allocates the response slot and advances the request index on `source_request_fire`. No separate allocation-only cycle is required. Its local adapter forwards that handshake at [VX_lmem_dma_misal.sv:780](../../../hw/rtl/core/gemm/VX_lmem_dma_misal.sv#L780).

Improve's stream contains262,131 one-cycle request intervals and only seven longer intervals, each1,172 cycles; local request backpressure is0. At improve cycles30,000–30,015, local request valid/ready/fire and compute Input valid/ready/fire are all1, as exported in [improve_issue_window.csv](../../../agent-tasks/naive-m256-residual-gap/improve_issue_window.csv). This is a separate steady-state example, not work matched to the naive absolute cycle.

## 3. Quantify the issue bubble and the remaining delays without double counting

The following is a second, independent partition of naive's same574,450-cycle stream, measured at `N_DMA`. Its rows are mutually exclusive and exhaustive; do not add them to the compute Input partition above.

| Source-DMA state | Predicate | Cycles |
|---|---|---:|
| Allocate only | `allocate` | **262,136** |
| Complete a row request | `request_done` | 262,137 |
| Await unfinished lane acceptance | `fetch_active_r && !request_done` | **43,636** |
| Inactive and no free slot | `!fetch_active_r && !allocate && !free_found` | 6,514 |
| Other inactive cycles with a free slot | `!fetch_active_r && !allocate && free_found` | 27 |
| Total | | **574,450** |

The262,136 allocation-only cycles are86.20% of the304,109-cycle Input interval gap in magnitude. This is an observed structural cost, **not a measured262,136-cycle speedup from a hypothetical change**. Faster issue will change subsequent bank contention and PSUM/result-credit pressure.

The lane-acceptance delay is real local backpressure in addition to the intrinsic issue bubble. Of its43,636 cycles,30,653 occur while the external DMA is idle. At naive cycle30,393, the row address is `0x1ffc07120`, all four Input lane ready signals are0, `fetch_active_r=1`, `request_done=0`, and only8 of16 Input slots are occupied. At30,394 the same row is accepted on all four lanes. This is neither a full response array nor an external DMA transfer.

The physical-bank trace illustrates concurrent local traffic. At bank4's buffered arbitration root, cycle30,392 grants a PSUM read from port12;30,393 grants a PSUM write from port4;30,394 grants ordinary traffic from port0. `grant_fire=1` on all three. Input lane0 maps into ordinary port0. Lane arbitration is at [VX_gemm_node_naive.sv:399](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L399), PSUM classification at [VX_local_mem.sv:335](../../../hw/rtl/mem/VX_local_mem.sv#L335), and buffered root arbitration at [lines824](../../../hw/rtl/mem/VX_local_mem.sv#L824) and [870](../../../hw/rtl/mem/VX_local_mem.sv#L870). See [naive_bank4_window.csv](../../../agent-tasks/naive-m256-residual-gap/naive_bank4_window.csv).

These root grants concern buffered, earlier requests;30,394's root grant must not be confused with the new row accepted by the Input executor on that same edge. The window demonstrates shared-bank service and upstream backpressure, not an exact attribution of all43,636 wait cycles to one competing client.

Of the6,514 inactive/full-slot cycles,5,075 overlap the Output dependency. Increasing Input slots alone therefore mostly adds read-ahead across a dependency that still prevents delivery. The output gate at [VX_naive_input_contexts.sv:74](../../../hw/rtl/core/gemm/VX_naive_input_contexts.sv#L74) compares the completed Output counter against the command target generated at [VX_gemm_fsm_naive_meta.sv:263](../../../hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv#L263). It blocks exactly seven729-cycle intervals:

`[97716,98445), [169628,170357), [241466,242195), [313383,314112), [385391,386120), [457271,458000), [529191,529920)`.

The previously identified PSUM waits have not disappeared, but their raw occupancy cannot be added as another kernel penalty: they overlap the sparse Input stream. Current exact RAW/WAW/WAR/table-full blocker counts are all0. The10,316 compute Input backpressure cycles are the directly visible Input stall measure; downstream PSUM wait occupancy alone is not an additive explanation of the303,907-cycle kernel difference.

## 4. M256 does not eliminate the shared-LMEM bandwidth limit

Even after removing the issue bubble, naive and improve do not have identical local-memory obligations. The FSDB counts at naive's wide PSUM interfaces over `[24758,601521)` are:

| Traffic | Accepted vectors | Bytes/vector | Total bytes | First / last accepted cycle |
|---|---:|---:|---:|---|
| Local Input read | 262,144 | 32 | 8,388,608 | 26,326 / 600,762, complete four-lane request |
| PSUM read | 253,952 | 64 | 16,252,928 | 28,790 / 600,791 |
| PSUM write | 253,952 | 64 | 16,252,928 | 26,372 / 598,569 |
| Selected local traffic subtotal | | | **40,894,464 = 39 MiB** | |

Naive PSUM read requests are formed at [VX_gemm_acc_lmem.sv:264](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv#L264); nonfinal FP32 writes at [line342](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv#L342). Their splitters connect to LMEM at [VX_gemm_node_naive.sv:797](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L797). FP16 final writes are separate and excluded from this subtotal, as are Weight/S/Z, external-DMA LMEM accesses, and Output reads.

The configured LMEM has 16 banks of 8-byte single-port storage. [VX_local_mem.sv:467](../../../hw/rtl/mem/VX_local_mem.sv#L467) instantiates `VX_sp_ram`; the read and write enables at lines477–478 use the same bank request port. Thus aggregate bank service cannot exceed 128 bytes/cycle, even with perfect bank distribution and no arbitration bubbles.

Keeping the observed traffic and this memory architecture gives an optimistic bandwidth lower bound of:

`40,894,464 / 128 = 319,488 cycles`.

That already exceeds improve's272,856 measured GEMM cycles. Other traffic and bank concentration can only worsen this bound. It is a bound for the current traffic volume, not a prediction for a redesign that changes PSUM reuse, banking, or ports.

Improve instantiates a separate accumulator backend at [VX_gemm_unit_v2.sv:101](../../../hw/rtl/core/gemm/VX_gemm_unit_v2.sv#L101), with its own four RAM banks at [VX_gemm_acc_internal.sv:251](../../../hw/rtl/core/gemm/VX_gemm_acc_internal.sv#L251). Its PSUM accesses therefore do not spend Input TMEM bank bandwidth.

Increasing M amortizes external operand loading through reuse. It does not automatically reduce local Input and PSUM bytes per vector issue: both those bytes and arithmetic work grow with M. Consequently, being compute-bound relative to external memory does not imply being compute-bound relative to shared LMEM.

## 5. External DMA is faster in improve, but is not the dominant current M256 explanation

Both runs transfer1,376,256 useful read bytes and262,144 write bytes according to their DMA counters.

| External DMA activity, whole GEMM interval | Naive | Improve |
|---|---:|---:|
| Read-busy union cycles | 51,686 | 15,861 |
| Write-busy union cycles | 5,288 | 1,308 |
| Useful read bytes / read-busy union cycle | 26.63 | 86.77 |

Improve's read service metric is about3.26x higher. This uses the union of channel-active intervals, not improve's sum of channel-active cycles. It is an observed useful-payload service rate, not raw HBM peak bandwidth.

The35,825-cycle difference in read-active durations is **not an additive GEMM penalty**: much of the DMA work overlaps compute, and transfer duration itself includes destination backpressure. During naive's Input stream,266,110 of301,991 no-valid cycles occur with external DMA idle, as do243,486 allocation-only cycles. The deterministic two-cycle local issue restriction remains regardless of external DMA bandwidth.

The exact exposed startup difference is1,430 cycles. The remaining external-DMA impact cannot be isolated as a single kernel-cycle number without a controlled change; subtracting DMA active-cycle counters would overstate causal certainty.

## Review outcome and next experiment

The proposed experiment was to accept the next Input row request without an allocation-only cycle, while retaining stable stalled requests, per-lane completion tracking, and response-slot ownership. This local scheduling change has now been tested without changing the memory layout.

The [follow-up result](fpint_gemm_input_issue_experiment.md) confirms the issue restriction is avoidable, but does not support the hypothesis that it dominates recoverable kernel latency: M256 becomes 29,624 cycles slower as local request and response-capacity waits increase. The pre-change residency counts above remain valid observations, not a prediction of net speedup.

## Reproduction

The scripts use `fsdb_cli.report` and compressed transition caches; no FSDB-to-VCD conversion is needed:

```sh
python3 agent-tasks/naive-m256-residual-gap/analyze.py
python3 agent-tasks/naive-m256-residual-gap/improve.py
python3 agent-tasks/naive-m256-residual-gap/bank_window.py
python3 agent-tasks/naive-m256-residual-gap/summarize.py
```

The first three scripts extract the additional local-DMA signals. The final script checks exclusive partition sums, verifies source hashes, and writes the small review tables plus [summary.json](../../../agent-tasks/naive-m256-residual-gap/summary.json). Existing whole-kernel phase/DMA counts come from the original run captures. The cycle-only comparison document remains unchanged.
