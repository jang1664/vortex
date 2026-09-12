# Why improve is faster: FSDB and RTL review annotations

> Historical pre-scheduler scope: this report describes the DMA-slot-saturation baseline before naive address-safe PSUM read priority. Current cycles are in [the cycle comparison](fpint_gemm_latency.md), and the new policy/measurements are in [the scheduler sweep](fpint_gemm_read_priority_sweep.md). RTL line annotations below refer to the pre-change snapshot in `agent-tasks/naive-psum-read-priority/snapshot/rtl`.

The main differences are **operand delivery** and **PSUM storage/ordering**, not arithmetic throughput alone. Improve uses TMEM for operands and a separate internal accumulator RAM for PSUM. Naive uses shared LMEM for both operands and PSUM. The common compute core is instantiated by both backends, but its memory-facing stalls differ substantially.

Scope: current N-fast FSMs, TH16/MXU16, K=N512, M4/M256, QCOL, WTRANS0, Weight8, naive PSUM16, external DMA improve16 per channel / naive32. These are the selected saturation runs, not the earlier Weight4 or PSUM32 experiments. This analysis reuses the completed FSDBs; no RTL or simulation configuration changed for this follow-up.

## How to navigate the annotations

All cycle ranges below are **absolute observer cycles**, half-open `[start, end)`. A range ending at C100 excludes C100. Relative cycle = absolute cycle minus that run's `e_cfg`. The positive clock edge for cycle C is at **10*C + 5 ns**. Values are sampled strictly before that edge, so `valid && ready` denotes the transfer accepted on that edge. Different runs have different boot lengths: do not align them by absolute cycle. Even equal relative cycles do not identify the same microtile.

The four files are:

| Alias | FSDB | Configuration-accept cycle |
|---|---|---:|
| I4 | `agent-tasks/dma-read-slot-saturation/improve/runs/depth16-m4/wave.fsdb` | 8,337 |
| N4 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots32-m4/wave.fsdb` | 8,479 |
| I256 | `agent-tasks/dma-read-slot-saturation/improve/runs/depth16-m256/wave.fsdb` | 26,769 |
| N256 | `agent-tasks/dma-read-slot-saturation/runs/naive/slots32-m256/wave.fsdb` | 24,339 |

`CORE` below abbreviates `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core`.

- Improve compute: `CORE/gemm_node/u_VX_gemm_unit_v2/u_compute_core`.
- Naive compute: `CORE/gemm_node_naive/u_VX_gemm_compute_core`.
- Naive ordering gate: `CORE/gemm_node_naive`.
- Improve DMA: `CORE/gemm_node/u_tmem_subsystem/u_dma_engine/g_channel[ch]/u_dma_unit/g_aligned/u_impl`, ch0–7.
- Naive DMA: `CORE/u_VX_dma_node/u_dma_unit/g_misaligned/u_impl`.

The [annotation directory](../../../agent-tasks/dma-read-slot-saturation/annotations) contains per-cycle CSVs and JSON signal maps with complete FSDB paths. These four short windows were re-extracted directly with `fsdb_cli.report`; the whole-run counts and long intervals use its saved transition caches. [Extraction script](../../../agent-tasks/dma-read-slot-saturation/annotate_windows.py), [whole-run summary script](../../../agent-tasks/dma-read-slot-saturation/annotation_summary.py), [summary data](../../../agent-tasks/dma-read-slot-saturation/annotations/summary.json).

## 1. Locate the total advantage before interpreting stalls

Each phase is an edge distance. The five phase lengths sum exactly to GEMM cycles. Only the uncompleted Output work after the last accumulator write belongs to the Output tail.

### M4

| Phase | Improve absolute cycles | Naive absolute cycles | Improve length | Naive length | Saved by improve |
|---|---|---|---:|---:|---:|
| Configuration → first Input | [8,337, 8,427) | [8,479, 9,241) | 90 | 762 | 672 |
| First → last Input | [8,427, 14,485) | [9,241, 24,344) | 6,058 | 15,103 | 9,045 |
| Last Input → last accumulator write | [14,485, 14,501) | [24,344, 24,374) | 16 | 30 | 14 |
| Last accumulator write → final store | [14,501, 14,765) | [24,374, 24,446) | 264 | 72 | -192 |
| Final store → completion | [14,765, 14,768) | [24,446, 24,449) | 3 | 3 | 0 |

### M256

| Phase | Improve absolute cycles | Naive absolute cycles | Improve length | Naive length | Saved by improve |
|---|---|---|---:|---:|---:|
| Configuration → first Input | [26,769, 26,921) | [24,339, 25,921) | 152 | 1,582 | 1,430 |
| First → last Input | [26,921, 297,262) | [25,921, 695,601) | 270,341 | 669,680 | 399,339 |
| Last Input → last accumulator write | [297,262, 297,278) | [695,601, 695,637) | 16 | 36 | 20 |
| Last accumulator write → final store | [297,278, 299,622) | [695,637, 696,329) | 2,344 | 692 | -1,652 |
| Final store → completion | [299,622, 299,625) | [696,329, 696,332) | 3 | 3 | 0 |

The totals are M4 **6,431 vs 15,970** and M256 **272,856 vs 671,993**. Almost all net advantage lies between the first and last accepted Input. This interval includes both feeding data and downstream backpressure; calling it simply “DMA time” would be incorrect.

The Input interface gives an exact, mutually exclusive decomposition of this interval:

| M | Backend | Accepted Input | Input valid, not ready | No Input request | Total interval |
|---:|---|---:|---:|---:|---:|
| 4 | Improve | 4,095 | 26 | 1,937 | 6,058 |
| 4 | Naive | 4,095 | 9,574 | 1,434 | 15,103 |
| 256 | Improve | 262,143 | 0 | 8,198 | 270,341 |
| 256 | Naive | 262,143 | 60,012 | 347,525 | 669,680 |

The last Input edge starts the next phase and is excluded here; total accepted Inputs are 4,096 and 262,144 in both backends. M4's 9,045-cycle Input-interval difference equals 9,548 additional backpressure cycles minus 503 fewer no-request cycles. M256's 399,339-cycle difference equals 60,012 additional backpressure cycles plus 339,327 additional no-request cycles. A no-request cycle can reflect scheduling, dependencies, or operand availability; it cannot automatically be assigned to external DMA starvation.

RTL: [`input_fire = valid && ready`](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:605), [Input admission and elastic-pipeline ready](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:632).

## 2. M256: shared-LMEM PSUM ordering creates real stalls while DMA is idle

PSUM is the partial sum from an earlier K contribution, needed before the next contribution can be accumulated. In naive, prefetch reserves storage early, but it still has to issue a physical LMEM request and receive its data. A reserved response slot is not a completed read.

Naive blocks a PSUM read while **any queued PSUM write targets the same physical bank set**. This is broader than an exact same-address comparison. Pending writes remain counted until the reserved lanes commit at the actual LMEM banks, including downstream queues. This conservative rule preserves ordering, but can delay a read whose exact address differs from those writes.

RTL annotations:

- [Naive connects the common compute core to `VX_gemm_acc_lmem`](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:727).
- [Input admission reserves transaction and prefetch capacity](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv:187).
- [The adapter holds/issues the physical PSUM read](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv:246).
- [Pending/current bank-set conflicts](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:578) feed [request-valid suppression and request-ready suppression](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:589).
- [Physical lane-commit detection](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:171) feeds [pending-count retirement](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:603).

### Annotation N256_PSUM: C635,468–635,479

Review [CSV](../../../agent-tasks/dma-read-slot-saturation/annotations/N256_PSUM.csv) and [signal map](../../../agent-tasks/dma-read-slot-saturation/annotations/N256_PSUM.json). This is relative `[611129,611140)`, approximately 6,354,685–6,354,795 ns.

| Cycle(s) | Observed state | Interpretation |
|---|---|---|
| [635468,635475) | DMA busy=0; Weight ready=1; scaled result ready=1; PSUM ready=0; result credit available or committing; `post_txn_launch=0` | PSUM is the remaining postprocessing launch blocker. |
| [635468,635475) | `psum_rd_pending_conflict=1`; raw read valid=1/ready=0; downstream read valid=0 | The bank-set gate actually prevents the pending LMEM request from being issued. |
| [635473,635475) | Input valid=1/ready=0; `acc_txn_accept_ready=0`; post transaction count=4 | The blocked memory path also reaches Input admission. |
| 635475 | Order block=0; raw valid=1/ready=1; downstream valid=1 | A physical read is accepted once the ordering gate opens. |
| 635477 | Raw PSUM response valid=1 | An LMEM response arrives. |
| 635478 | Head PSUM ready=1; `post_txn_launch=1` | The head transaction can launch again. |

The response/head-ready sequence is a measured temporal sequence; this annotation does not claim a tag-matched latency for that one request. Also, C635454–635467 must not be labeled PSUM-only: result credit is unavailable there as well. The narrower interval above checks the actual launch predicate.

### Annotation N256_RECOVERY: C108,011–108,038

Review [CSV](../../../agent-tasks/dma-read-slot-saturation/annotations/N256_RECOVERY.csv) and [signal map](../../../agent-tasks/dma-read-slot-saturation/annotations/N256_RECOVERY.json). Relative `[83672,83699)`, approximately 1,080,115–1,080,385 ns.

- `[108011,108035)`: Input valid=1/ready=0, DMA busy=0, Weight ready=1, scaled ready=1, PSUM ready=0, result capacity available, `post_txn_launch=0`.
- C108035: PSUM ready and `post_txn_launch` become1.
- C108037: Input handshake resumes.

Here the node ordering gate is already open. This shows why “read request no longer blocked” does **not** mean “the head's PSUM data is available”: request acceptance and response completion are separate stages. The node's bank-set block count and the compute core's PSUM wait count are consequently different metrics.

RTL: [Head PSUM selection from forwarding/stored response/current response](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:2246); [launch requires both scaled data and PSUM plus result capacity](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:2261); [post-transaction occupancy changes on launch](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:2331); [compute credits](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:1806). Finite queues and admission capacity propagate sustained downstream waiting upstream. Different windows can stop Input through different ready conditions; N256_RECOVERY retains adapter admission-ready while N256_PSUM temporarily deasserts it.

Whole-run N256 evidence: **356,262 PSUM-only launch-blocked cycles**, of which **325,524 occur while external DMA is idle**. Node bank-set ordering blocks a read for **357,280 cycles**. These counts overlap and must not be added or treated as independently removable latency. They nevertheless rule out an explanation based solely on simultaneous external DMA activity.

## 3. Improve avoids that shared-LMEM PSUM round trip

Improve instantiates the same arithmetic core but connects its accumulator interface to a **dedicated internal accumulator backend**, not to shared LMEM or to operand TMEM. Its read side has a fixed-latency, always-accept contract. The internal bank scheduler handles read/write collisions locally. Thus it does not have naive's aggregate LMEM bank-set write-drain gate on every PSUM read.

RTL: [Internal accumulator binding](../../../hw/rtl/core/gemm/VX_gemm_unit_v2.sv:101), [always-ready accumulator read and local write collision handling](../../../hw/rtl/core/gemm/VX_gemm_acc_internal.sv:92), [three-register response-valid pipeline](../../../hw/rtl/core/gemm/VX_gemm_acc_internal.sv:141), [response output](../../../hw/rtl/core/gemm/VX_gemm_acc_internal.sv:167). This does not imply that every internal operation is stall-free; it describes the read contract relevant to this comparison.

### Annotation I256_STREAM: C264,495–297,263

Over this entire **32,768-cycle** interval, Input valid and ready are both1: improve accepts an Input every cycle. Relative interval `[237726,270494)`, approximately 2,644,955–2,972,635 ns. The entire interval is verified from the Input transition caches. Its first60 cycles were independently re-extracted in [CSV](../../../agent-tasks/dma-read-slot-saturation/annotations/I256_STREAM.csv) / [signal map](../../../agent-tasks/dma-read-slot-saturation/annotations/I256_STREAM.json).

At C264520: Input fire=1, Weight ready=1, head scaled ready=1, head PSUM ready=1, post launch=1, accumulator read-ready=1, and external DMA busy=0. During initial pipeline fill both head-ready bits may be0 without a PSUM-only launch stall; inspect transaction validity and the full launch predicate.

For the complete I256 run, PSUM-only blocking is0 and the Input-stream interval spends **96.97%** of its cycles accepting Input, versus **39.14%** in N256. The remaining disparity is a memory/scheduling limitation around the common compute core, not evidence that naive performs more arithmetic operations.

## 4. M4: Weight delivery is exposed, and it overlaps PSUM waiting

With only four rows, a loaded weight microtile has little row reuse before the next weight is needed. The compute core checks the selected weight register's completed-load generation against the command's target. Input data can have arrived while the required Weight generation has not. A false `weight_ready` directly makes `compute_ready` false.

RTL: [Weight generation comparison and compute-ready gate](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:1764); [prealigner output is consumed only when compute is ready](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:1378).

### Annotation N4_WEIGHT: C18,758–18,795

Review [CSV](../../../agent-tasks/dma-read-slot-saturation/annotations/N4_WEIGHT.csv) / [signal map](../../../agent-tasks/dma-read-slot-saturation/annotations/N4_WEIGHT.json). Relative `[10279,10316)`, approximately 187,585–187,955 ns.

- `[18758,18795)`: prealigned Input and metadata are valid, Weight ready=0, compute ready=0, and external DMA is active.
- `[18759,18795)`: Input valid=1/ready=0. The producer has data, but the compute path cannot accept it.
- C18795: Weight ready and Input handshake both become1.
- PSUM ordering/response waits overlap part of this same window. DMA active does not prove that every waiting cycle belongs to this exact weight's external transfer; the selected Weight also traverses the local gather/register-load path.

Whole-run M4 Weight waits: **386 improve vs 9,962 naive**. Of naive's waits, **6,948 occur while external DMA is active and 3,014 while it is idle**. Naive also has **8,932 PSUM-only launch waits**, with **6,580 cycles overlapping the Weight wait predicate**. Therefore adding “Weight waits + PSUM waits” would double-count much of the same wall-clock time. M256 Weight waits shrink to1 improve /11 naive, consistent with much greater row reuse in the M256 workload.

## 5. How much does DMA bandwidth matter?

Here “effective DMA delivery rate” means useful DRAM-to-operand-memory bytes divided by the union of read-active cycles across engines. It includes setup, source stalls, reordering, destination-memory stalls, and response latency. It is **not isolated physical HBM bandwidth**. Both backends transfer the same useful payload, but source transaction splitting and destination routing differ.

| M | Useful read payload | Improve read-active | Naive read-active | Improve effective B/cycle | Naive effective B/cycle | Delivery-rate ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 4 | 180,224 B | 1,323 | 10,667 | 136.22 | 16.90 | 8.06x |
| 256 | 1,376,256 B | 15,861 | 60,501 | 86.77 | 22.75 | 3.81x |

### DMA annotations

- **I4 `[11051,11081)`**, relative `[2714,2744)`: all eight units simultaneously have `dma_is_active=1` and `active_dir=0`. This happens for1,120 cycles in total.
- **I256 `[34619,35192)`**, relative `[7850,8423)`: all eight units are read-active for573 consecutive cycles; total all-eight activity is15,705 cycles. These predicates indicate active transfers, not a claim that all eight accept one payload beat on every cycle.
- Naive has one external DMA unit, explicitly instantiated through the misaligned path. **N4 `[18848,19311)`** is a463-cycle continuous DMA-active interval. Its single-unit activity and the much longer aggregate read-active time can be reviewed alongside the Input and PSUM windows above.
- Read/write-active cycle totals are measured over the configuration-to-completion ranges in section1 using the per-unit activity/direction signals. The [summary data](../../../agent-tasks/dma-read-slot-saturation/annotations/summary.json) identifies the long all-channel intervals.

RTL: [Improve's per-channel DMA instances](../../../hw/rtl/mem/VX_dma_engine.sv:136), [TMEM subsystem's DMA-channel binding](../../../hw/rtl/mem/VX_tmem_subsystem.sv:237), [naive explicitly enables misalignment](../../../hw/rtl/core/VX_core.sv:324), [aligned response RAM](../../../hw/rtl/core/VX_dma_unit_align.sv:1466), [misaligned response RAM](../../../hw/rtl/core/VX_dma_unit_misal.sv:716). Tile-major TMEM delivery, eight channels, and the aligned path coexist in improve; this experiment does not isolate their individual contributions from each other.

The read-active-time difference is **9,344 cycles at M4** and **44,640 at M256**, while the whole-GEMM difference is **9,539** and **399,137**. These pairs are useful scale comparisons, not causal percentages or savings that can be added to compute stalls. DMA overlaps computation and can affect the timing of later dependencies. In particular, it would be incorrect to conclude that DMA explains98% of M4 simply because9,344 is close to9,539.

The controlled slot sweep gives a narrower causal result: increasing improve8→16 reduces DMA read-active time by70/377 cycles but total GEMM by only2/13; increasing naive16→32 reduces DMA read-active time by102/1,336 while total GEMM gets103/64 cycles slower. Increasing capacity again changes neither transfer time nor GEMM time. Thus **more external response buffering has essentially exhausted its useful latency benefit for these shapes**. This does not prove that equalizing actual memory delivery bandwidth would have zero effect.

The supported interpretation is: M4 exposes a strong delivery/Weight effect, mixed with PSUM waiting; M256 hides most Weight delivery and exposes the shared-LMEM PSUM path. Exact attribution to physical DMA bandwidth, tile-major layout, channel count, and PSUM architecture separately would require controlled experiments changing those factors individually. The current FSDBs support the observed mechanisms and their cycle ranges, not a unique “bandwidth accounts for X%” value.

## 6. Startup and final Output are smaller, separate effects

The phase table annotates startup as I4 `[8337,8427)` vs N4 `[8479,9241)`, and I256 `[26769,26921)` vs N256 `[24339,25921)`. Naive's external-DMA path allocates a descriptor, programs it, kicks it, and polls completion; improve dispatches through its DMA engine channels. These mechanisms help explain the startup difference, but the entire startup interval also includes operand readiness and command dependencies. It is not all MMIO overhead.

RTL: [Naive descriptor allocation](../../../hw/rtl/core/gemm/VX_naive_external_dma_executor.sv:565), [one-lane descriptor programming](../../../hw/rtl/core/gemm/VX_naive_external_dma_executor.sv:630), [start write](../../../hw/rtl/core/gemm/VX_naive_external_dma_executor.sv:683), [completion polling](../../../hw/rtl/core/gemm/VX_naive_external_dma_executor.sv:713), [improve channel instances](../../../hw/rtl/mem/VX_dma_engine.sv:136).

Improve loses **192 M4 cycles /1,652 M256 cycles** in the residual Output tail: I4 `[14501,14765)` vs N4 `[24374,24446)`, I256 `[297278,299622)` vs N256 `[695637,696329)`. Improve must copy internal accumulator slices to operand memory before external Output DMA; naive's final data is already stored through its LMEM path. Earlier output work overlaps computation differently, so residual tail is not total output-transfer throughput.

RTL: [Improve accumulator-to-memory copy command](../../../hw/rtl/core/gemm/VX_gemm_fsm.sv:2322), [external output-store phase](../../../hw/rtl/core/gemm/VX_gemm_fsm.sv:2369), [naive output macro-tile store](../../../hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv:198).

Current totals remain in the [cycle-only report](fpint_gemm_latency.md); the [capacity sweep report](fpint_gemm_dma_slot_saturation.md) retains all depth comparisons. This annotation document adds review evidence without changing those measurements.

## Follow-up: exact-address audit of the bank-set waits

The [read-priority analysis](fpint_gemm_read_priority_analysis.md) reconstructs all physically pending PSUM writes and confirms that every observed node bank-set read stall in these two workloads involves other rows, not the requested row. This strengthens the case for relaxing bank-set eligibility and prioritizing safe reads; it does not remove the separate logical/physical same-address ordering requirements.
