# Isolated naive Input DMA issue experiment

The compulsory allocation-only cycle has been removed when a next row and free slot are available. Both xrt-vcs-sim tests pass, and FSDB confirms consecutive row requests. **Performance regressed: M4 by3.59%, M256 by5.14%.** The implementation is retained as the requested isolated experiment; no LMEM optimization or additional tuning was applied.

The experiment corrects the earlier interpretation of allocation residency: a large number of allocation-only cycles did not imply an equally large recoverable kernel latency. Eliminating most of those cycles changes the timing of traffic through shared resources and increases other waits.

## RTL change and fixed conditions

Only two RTL files changed relative to the frozen R1 baseline:

- [VX_naive_qparam_dma.sv:14](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L14) adds `PIPELINED_ISSUE=0`. Candidate selection at line89 chooses the next row, or the next already-admitted command, when all lanes of the current request complete. The allocation condition at line99 permits replacement on that edge. Allocation at line314 and completion accounting at line331 execute independently; the request remains registered.
- [VX_naive_input_executor.sv:68](../../../hw/rtl/core/gemm/VX_naive_input_executor.sv#L68) enables the parameter only for Input. The S/Z instances retain the default behavior. A partial-lane stall retains the current slot/address/tag; no just-freed slot recycling or same-cycle command-admission bypass was added.

Both workloads use TH16/MXU16x16, N-fast, K=N512, QCOL, Weight8, Input response16/lane FIFO8, PSUM read/response16, PSUM R=1, external DMA naive32/improve16 per channel. LMEM topology, bank arbitration, PSUM scheduling, FSM, data layouts and depths are unchanged. The actual before/after naive compile flags and app arguments match exactly.

Improve's active preprocessed RTL is identical for both edited modules with NDEBUG on and off, and no other RTL file changed. See [identity evidence](../../../agent-tasks/naive-input-single-cycle-issue/improve_identity.json) and [baseline comparison](../../../agent-tasks/naive-input-single-cycle-issue/baseline_comparison.json). Existing improve measurements are reused; no synthesis or new improve run was required.

## Cycle results

| M | Naive before GEMM | Naive after GEMM | Change | Improve GEMM | After naive / improve |
|---:|---:|---:|---:|---:|---:|
| 4 | 15,693 | 16,257 | +564 / +3.59% | 6,431 | 2.528x |
| 256 | 576,763 | 606,387 | +29,624 / +5.14% | 272,856 | 2.222x |

| M | Naive before core | Naive after core | Change | Improve core |
|---:|---:|---:|---:|---:|
| 4 | 22,254 | 22,854 | +600 | 12,205 |
| 256 | 583,329 | 612,954 | +29,625 | 278,622 |

M256's entire GEMM regression is inside the first-to-last Input interval:574,450 to604,074 cycles. Its other phases remain1,582 startup,36 compute drain,692 output tail and3 finalize cycles. M4's Input interval increases566 cycles; compute drain decreases2 cycles, giving564 net.

The [current cycle comparison](fpint_gemm_latency.md) contains only the latest cycle figures. The [machine-readable comparison](../../../agent-tasks/naive-input-single-cycle-issue/comparison.json) preserves both sides of this experiment.

## FSDB shows the requested issue change working

Samples are strictly before the positive edge at `10*C+5 ns`; intervals are half-open. Absolute cycles are local to each run, not aligned work identifiers across runs.

New M4: configuration C8,421, first Input C9,183, last Input C24,575, completion C24,678. New M256: configuration C21,191, first Input C22,773, last Input C626,847, completion C627,578.

The Input DMA hierarchy is `CORE/gemm_node_naive/input_executor/source_dma`, where `CORE` is `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core`.

| Observation | M4 | M256 |
|---|---:|---:|
| Complete Input vectors / complete row requests, whole GEMM | 4,096 | 262,144 |
| Request completion plus next-slot reservation, whole GEMM | 3,111 | 239,519 |
| Replacement across a command boundary | 39 | 1,852 |
| Request intervals of one cycle, Input stream | 2,683 | 202,944 |
| Eligible replacements skipped | 0 | 0 |

At M256 C22,758, the initial slot is allocated. At C22,759–22,766, `request_done=1`, `allocate=1` and `request_fire=0xf` every cycle: four64-bit lanes complete a row while the next slot is reserved. This is the intended one-row-per-cycle capability. See [continuous-request CSV](../../../agent-tasks/naive-input-single-cycle-issue/m256-continuous.csv).

At M256 C23,082, row127 completes and the next command's row0 is reserved. The new request is present at C23,083, but its lanes accept at C23,085. The allocation bubble is absent; actual memory backpressure still applies. See [command-boundary CSV](../../../agent-tasks/naive-input-single-cycle-issue/m256-command.csv). M4 also crosses a command boundary at C9,172 and accepts the next command's first row at C9,173.

Waveform checks also confirm exact row/command delivery order, exactly one acceptance per lane per vector, stable slot/address and sent-lane tracking during partial stalls, and no missing eligible replacement. Existing response ownership assertions pass. These checks use the two application FSDBs; no reset-specific tests were added.

## Why the kernel is slower despite more consecutive requests

The following states partition each M256 Input interval exactly. Completion with replacement is counted as request completion, not as allocation-only time.

| Local Input DMA state | Before | After | Change |
|---|---:|---:|---:|
| Allocation only | 262,136 | 22,624 | **-239,512** |
| Complete a row request | 262,137 | 262,130 | -7 |
| Await unfinished lane acceptance | 43,636 | 231,028 | **+187,392** |
| Inactive with no free response slot | 6,514 | 88,263 | **+81,749** |
| Other inactive cycles with a free slot | 27 | 29 | +2 |
| Total | **574,450** | **604,074** | **+29,624** |

The completed-request counts differ slightly inside this interval because prefetch and drain straddle its boundaries. Across the whole GEMM, both runs complete262,144 requests. After-change completion comprises239,505 completions with replacement and22,625 without replacement inside the stream.

This table proves the intrinsic issue restriction was substantially removed, and also shows why counting removed allocation cycles as net saved latency was wrong. More time is now spent waiting for the local request path and for Input response capacity. This does not establish which particular bank-arbitration decision causes every wait; that would require a separate investigation or intervention, excluded from this experiment.

At the compute Input interface, the independent, exclusive partition is:

| M256 compute Input condition | Before | After | Change |
|---|---:|---:|---:|
| `valid && ready` | 262,143 | 262,143 | 0 |
| `valid && !ready` | 10,316 | 120,031 | **+109,715** |
| `!valid` | 301,991 | 221,900 | **-80,091** |
| Total | 574,450 | 604,074 | +29,624 |

More data is available, but the compute Input interface refuses it more often. Of the new120,031 backpressure cycles,75,631 overlap a waiting head PSUM transaction without a Weight wait;24 overlap Weight wait alone, and44,376 overlap neither of those two sampled conditions. The latter category is not automatically PSUM-free causally: backpressure can persist through registered queues and credit paths. It is deliberately left unattributed here.

PSUM wait while its scaled operand is already ready increases from67,708 to134,203 cycles. Total PSUM-wait occupancy actually decreases from156,515 to150,870 cycles, demonstrating why raw overlapping wait counts should not be treated as additive kernel penalties.

At M256 `[96578,96602)`, Input valid is1 and ready is0, Weight is ready, and the head PSUM is unavailable. From C96,580 in the exported window, all16 Input response slots are occupied and the local Input DMA cannot reserve another slot. See [PSUM/backpressure CSV](../../../agent-tasks/naive-input-single-cycle-issue/m256-psum-backpressure.csv). Compute Input admission is at [VX_gemm_compute_core.sv:632](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L632); PSUM-head readiness at [line2246](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L2246); the existing free-slot condition is [VX_naive_qparam_dma.sv:99](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L99).

M4 behaves differently. Its no-supply cycles decrease only43, while Input backpressure increases609, explaining its566-cycle longer Input interval. Weight-wait overlap accounts for the increase: backpressure overlapping Weight wait rises9,360 to9,971; backpressure without Weight wait falls5 to3. A representative new pure Weight-wait interval is `[22230,22272)`. The loaded-weight target comparison and compute gating are at [VX_gemm_compute_core.sv:1764](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1764). See [M4 stall details](../../../agent-tasks/naive-input-single-cycle-issue/m4-stall-detail.json). This observation does not by itself identify why upstream Weight completion timing changed.

## Reproduction and retained evidence

Follow-up readiness and lane-skew audit: [readiness-detail.json](../../../agent-tasks/naive-input-single-cycle-issue/readiness-detail.json), generated by `readiness_detail.py`. Of M256's120,031 Input backpressure cycles,105,824 have only `in_pipe_ready_in=0`,117 have only accumulator admission blocked, and14,090 have both blocked. Transaction metadata never fills (maximum19/64); all admission-blocked cycles require PSUM prefetch with no free read slot. Tree-result credit is unavailable in119,915 backpressure cycles; this is an overlapping downstream-capacity condition, not a fourth additive category.

Of231,028 local Input request-wait cycles,215,615 have no lane accepted either previously or on the current edge, and15,413 have at least one accepted lane. Only8,934 already have a sent lane at the beginning of the cycle. Lane-independent issue can remove this cross-lane restriction, but the current trace does not establish its counterfactual speedup. Consecutive complete rows target the same four-bank group in261,888 of262,143 adjacent pairs: row stride256 bytes preserves the low bank bits within each command. More outstanding requests cannot by itself remove this concentration or the shared bank-service limit.

The dedicated configured build is `build_naive_input_issue_vcs`. Both runs source `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh`; the frozen-run helper executes `ci/run_black.sh xrt-vcs-sim --perf 3 --app fpint_gemm_ffn_hw_naive` with `-m 4` or `-m 256` and `-k 512 -n 512 -q 32 -t 0 -d 0 -r 1`.

Both runs have app PASS, zero wrapper exit status, no strict failure according to `tools/verify_rtl.py`, matching config hashes and no source changes during execution. Manifests, logs and FSDBs remain under `agent-tasks/naive-input-single-cycle-issue/runs/v1/{m4,m256}/`. The runner refuses to overwrite existing evidence.

```sh
python3 agent-tasks/naive-input-single-cycle-issue/analyze.py m4
python3 agent-tasks/naive-input-single-cycle-issue/analyze.py m256
python3 agent-tasks/naive-input-single-cycle-issue/check_improve_identity.py
python3 agent-tasks/naive-input-single-cycle-issue/compare.py
```

The final command regenerates the cycle-only comparison. Detailed results are [M4](../../../agent-tasks/naive-input-single-cycle-issue/m4-analysis.json) and [M256](../../../agent-tasks/naive-input-single-cycle-issue/m256-analysis.json). The original allocation-bubble observation remains valid, but this isolated experiment supersedes the claim that removing it would recover most of the M256 performance gap.
