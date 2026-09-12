# Naive PSUM address-safe read-priority sweep

Completed: **R=1 selected and enabled** in `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh`. All 16 VCS cases pass. The selected production flags match the tested R1 profile; RTL remains unchanged after verification.

## Scope

`xrt-vcs-sim`, `fpint_gemm_ffn_hw_naive`, TH16/MXU16, micro-tile N-fast,
K=N=512. Weight response slots remain 8, PSUM read/response slots remain 16,
external DMA read slots remain 32 for naive and 16 per channel for improve.
The comparison baseline is naive 15,970 GEMM cycles for M4 and 671,993 for M256.

The candidate enables `GEMM_NAIVE_PSUM_READ_PRIORITY` and sweeps
`GEMM_NAIVE_PSUM_READ_QUOTA=1,2,4,8`. A candidate must pass the two benchmark
shapes and M4/M16 K64 N16 reuse workloads, and must not regress either benchmark.
Among eligible candidates, select the greatest geometric mean of the two GEMM
speedups; ties favor smaller quota. Otherwise keep the previous production mode.

## Completed sweep and selection

| R | M4 GEMM | M4 core | M256 GEMM | M256 core | Selection eligibility | Geometric mean speedup |
|---:|---:|---:|---:|---:|---|---:|
| 1 | 15,693 | 22,254 | 576,763 | 583,329 | eligible | 1.08889× |
| 2 | 15,981 | 22,554 | 583,150 | 589,704 | excluded: M4 +11 | 1.07311× |
| 4 | 15,942 | 22,479 | 583,658 | 590,229 | eligible | 1.07395× |
| 8 | 15,942 | 22,479 | 583,658 | 590,229 | eligible | 1.07395× |

All four quotas pass all four shapes. R1 has the greatest eligible geometric mean speedup and is individually fastest in both benchmark shapes. Against the previous naive policy, it saves 277 cycles (1.73%) at M4 and 95,230 cycles (14.17%) at M256. R4 and R8 tie; neither surpasses R1.

## M4 activity comparison

| Policy | GEMM cycles | Change vs baseline | Core cycles | PSUM-only wait | Write backpressure | Result credit unavailable |
|---|---:|---:|---:|---:|---:|---:|
| Previous | 15,970 | — | 22,554 | 8,932 | 797 | 492 |
| R1 | 15,693 | −277 | 22,254 | 1,097 | 436 | 347 |
| R2 | 15,981 | +11 | 22,554 | 999 | 611 | 463 |
| R4 | 15,942 | −28 | 22,479 | 1,083 | 641 | 458 |
| R8 | 15,942 | −28 | 22,479 | 1,083 | 641 | 458 |

R2 is ineligible because M4 regresses. R1 gives the best result for both benchmark sizes.
R1 removes all 9,070 bank-set fence cycles, but saves only 277 overall cycles.
PSUM-only wait falls from 8,932 to 1,097 while weight wait rises from 9,962 to
10,425. These overlapping wait counts do not form an additive latency budget.
Compared with R1, R2 has less PSUM-only wait but more write backpressure and
result-credit exhaustion. Final GEMM latency, rather than one stall counter,
is the selection metric.

R1's M4 improvement is entirely in Input streaming: 15,103 → 14,826 cycles.
Startup remains 762, compute drain 30, output tail 72, and finalization 3.
DMA read/write bytes and transfer counts are unchanged. DMA read-active time
is 10,667 → 10,707 cycles, so the speedup is not evidence of higher external
DMA bandwidth. This sweep changes both address eligibility and quota policy;
it does not separately measure their causal contributions.

## Why selected R1 improves M256

R1 passes at **576,763 GEMM / 583,329 core cycles**. R2 also passes at
583,150 / 589,704, but fails the M4 non-regression selection criterion.
R2 reduces PSUM-only wait further to 38,018, but raises write backpressure to
25,020 and result-credit-unavailable cycles to 26,357. Its GEMM interval is
6,387 cycles longer than R1 despite lower PSUM wait and DMA read-active time
(47,136 cycles). This directly illustrates why a read-stall minimum is not the
selection criterion.

| R1 M256 phase | Previous cycles | New cycles | Reduction |
|---|---:|---:|---:|
| Startup | 1,582 | 1,582 | 0 |
| Input stream | 669,680 | 574,450 | 95,230 |
| Compute drain | 36 | 36 | 0 |
| Output tail | 692 | 692 | 0 |
| Finalization | 3 | 3 | 0 |

| Overlapping activity | Previous | R1 |
|---|---:|---:|
| Node bank-set/exact-address read block | 357,280 | 0 |
| PSUM-only wait | 356,262 | 67,708 |
| Input backpressure | 60,012 | 10,316 |
| Weight wait | 11 | 11 |
| PSUM write backpressure | 824 | 19,089 |
| Result credit unavailable | 8,466 | 21,951 |
| Write backpressure with no result credit | 530 | 14,079 |
| DMA read-active cycles | 60,501 | 51,686 |

“Result credit unavailable” requires zero credit and no same-cycle result
commit, since a commit can make room immediately. Counters overlap: the
288,554-cycle reduction in PSUM-only wait is not an additive 288,554-cycle
GEMM saving. The additive phase reduction is 95,230 cycles (14.17%).

R1 M256 accepts 234,531 PSUM reads while other-row writes remain pending.
Examples: C28790, C28792, C28794, C28796, C28799, C28801, C28803, C28807.
Bank 0 read grants at C28794/C28845/C28868 are followed by quota write grants
at C28795/C28846/C28869 (`force_write` and grant logic, local-memory lines
870–906). Banks 0 and 8 pass the quota audit with maximum streak 1. The write
metadata table peaks at 7/16 entries, has no capacity stalls, and is empty at
C601521 completion. Raw phase boundaries are C24758/C26340/C600790/C600826/
C601518/C601521, in the same order as the phase table.

DMA still transfers 1,376,256 read bytes and 262,144 write bytes in 136 transfers.
DMA read-active time falls by 8,815 cycles, while source-request stalls rise
13,598 → 16,155 and destination-write stalls fall 26,100 → 14,640. This is a
shared-memory scheduling change with secondary DMA timing effects, not an
increase in interface width or external read-slot capacity. Those overlapping
DMA intervals do not establish what fraction of the total speedup was caused
by DMA timing.

## M256 quota activity comparison

| R | Input stream | PSUM-only wait | Write backpressure | Result credit unavailable | DMA read-active |
|---:|---:|---:|---:|---:|---:|
| 1 | 574,450 | 67,708 | 19,089 | 21,951 | 51,686 |
| 2 | 580,837 | 38,018 | 25,020 | 26,357 | 47,136 |
| 4 | 581,345 | 36,258 | 27,044 | 27,361 | 46,998 |
| 8 | 581,345 | 36,258 | 27,044 | 27,361 | 46,998 |

All benchmark captures have zero exact RAW/WAW/WAR, same-cycle address and write-table-full counters. Every M256 candidate peaks at 7/16 pending-write metadata entries and empties the table at completion. Banks 0 and 8 pass the per-bank quota audit at every R: observed maximum streaks are 1, 2, 3, 3 respectively. Quota-triggered writes are absent at R4/R8 in those inspected banks. This representative-bank observation is not claimed as an all-bank M256 audit. R4/R8 have identical total, phase and listed stall measurements; increasing the read quota beyond R1 gives no improvement in these workloads.

## RTL changes

- [VX_gemm_node_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv):
  lines 550–639 add 16 entries of pending-write address/lane metadata. There is
  no additional write-data FIFO. Reserve on the first permitted presentation
  to the splitter, hold the slot through partial acceptance, and retire only
  after all physical bank writes. Lines 680–690 carry the slot in existing tag
  value bits. Lines 728–749 replace bank-set blocking with physical-row checks.
- [VX_local_mem.sv](../../../hw/rtl/mem/VX_local_mem.sv): lines 153–161 return
  the slot identifier with the physical RAM commit. Lines 815–917 preserve
  the original two buffered slices and buffered root while applying quota
  arbitration at each bank's root. Two class bits travel with the buffered
  request; classification does not use a later request's live inputs.
- [VX_gemm_acc_lmem.sv](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv): lines
  237–253 retain the older logical transaction fence, using physical-row
  normalization for the enabled policy. The selected read transaction is
  exposed for same-cycle age comparison.
- [VX_gemm_psum_read_ooo_join.sv](../../../hw/rtl/core/gemm/VX_gemm_psum_read_ooo_join.sv):
  lines 77–87 protect allocated, incomplete reads from a younger write to the
  same row. Allocation precedes lane issue; protection therefore includes
  queued and partially issued reads. It ends after the last response is
  accepted, independently of later response FIFO consumption.

The existing common compute result queue remains two entries. New logic is
guarded for naive. The improve comparison preprocesses 286 XRT RTL files with
and without NDEBUG: all 572 comparisons match, except private instance names
derived from source line numbers are bijectively canonicalized before comparison.
This is an RTL comparison; no synthesis-based cost claim is made.

## Scheduling semantics

Different rows can proceed independently. Same-row uncommitted writes block
reads; same-row writes are serialized; an accepted incomplete read blocks a
younger same-row write. For simultaneously presented same-row requests,
32-bit transaction age decides, with read first for equal transaction tags.

At each bank, read wins against a waiting PSUM write until R read grants have
been accepted while a write is waiting. Then a write wins. A write grant or
absence of a waiting write resets the counter. A stalled selection remains
stable. Ordinary traffic preserves its relative index priority. Quota applies
to the heads visible after the existing slice buffers, not to requests hidden
upstream, and is not an absolute cycle deadline.

## Evidence and limitations

Runs, hashes, deterministic PASS results and waveforms are under
`agent-tasks/naive-psum-read-priority/runs/v2/`. `analyze.py` and
`audit_scheduler.py` in that task use `fsdb_cli`; captures are under
`captures/v2/`. Cycle C means the rising edge at C × 10 ns + 5 ns, sampled
immediately before the edge. Phase lengths use half-open intervals; stall
counters can overlap and must not be added as independent latency savings.

R1 M4 K64 N16 passes with exact pending-write RAW stalls at C6099–6103,
C6118–6122 and C6137–6141: 15 cycles total. These are the enabled node address
check at lines 594–596 and 730, not the removed bank-set fence. This workload
actually exercises same-row write-to-read reuse. Zero WAW/WAR or same-cycle
conflict counters do not establish coverage of those cases.

The tested geometry is 16 banks and eight lanes per PSUM row. Lane recovery
uses low-bit bank striping and requires at least as many banks as row lanes.
The transaction-age comparison assumes fewer than 2^31 in-flight transactions.
Tag-wrap, arbitrary DMA/software address races and aliasing with final output
regions are outside the observed workload coverage.

R1 M4 accepts 2,513 PSUM reads while other-row write metadata remains valid.
Examples include C9301, C9305–9307, C9309, and C9313–9315. The node's exact
address gate (`psum_rd_pending_conflict`, line 730) is zero in these cycles;
write metadata is nonempty. For bank 0, root read grants at C9305, C9313 and
C9321 are followed by quota write grants at C9306, C9314 and C9322. These map
to `force_write` and grant/counter logic at local-memory lines 870–906.
All 16 banks pass the R1 M4 quota audit; write metadata peaks at 7/16 and is
empty at GEMM completion. All 16 banks also pass the R2 M4 audit and reach read streak 2.

All eight short workloads pass: GEMM625 for M4 K64 N16 and GEMM797 for M16 K64 N16 at every quota. Additional waveform checks observe 15 exact-RAW cycles for R4 short4 and 5 for R2/R8 short16. WAW/WAR and same-cycle address counters remain zero in these inspected short captures.

R4 and R8 M4 are also audited across all 16 banks. Every bank reaches at most three reads while a write waits; no quota-triggered write grants occur for either setting. Thus the R4 and R8 caps are inactive throughout these captures, explaining their identical cycle and stall results. Both peak at seven pending-write metadata entries and empty the table by completion.

## Selected naive versus unchanged improve

| M | Backend | Startup | Input stream | Compute drain | Output tail | Finalization | Total |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4 | improve | 90 | 6,058 | 16 | 264 | 3 | 6,431 |
| 4 | naive R1 | 762 | 14,826 | 30 | 72 | 3 | 15,693 |
| 256 | improve | 152 | 270,341 | 16 | 2,344 | 3 | 272,856 |
| 256 | naive R1 | 1,582 | 574,450 | 36 | 692 | 3 | 576,763 |

Improve retains its 6,431/272,856-cycle measurements: its effective RTL is unchanged and those existing passing FSDBs are reused. Most of the remaining gap is in Input streaming. The smaller naive output tail offsets part of that gap; these phase distances add exactly to each total. Current overall comparisons are in [the cycle table](fpint_gemm_latency.md).

## Verification provenance

All 16 runs share the same 488-file source hash map, with no source or profile changes during any run. Deterministic checks require wrapper and runner success, numerical PASS, no strict failures, one GEMM/core measurement, and a nonempty FSDB. See [verification results](../../../agent-tasks/naive-psum-read-priority/verify/results.md). Only the selected production config was edited after all runs finished; its effective flags, including the observer added by the test runner, exactly match the tested R1 profile. `runs/final-consistency.json` records that check and continued improve RTL identity.

The first v1 attempt stopped at compile time because two assertion operands were declared later in the module. v2 moved their declarations before procedural use. All quoted performance results use the same frozen v2 source.
