# Why MXU32 M1/M4 lose little performance with four channels

## Conclusion

The captured executions are primarily limited by the **single 64-byte/cycle
Weight local-DMA-to-GEMM stream**, not sustained saturation of the aggregate
HBM interface or all TMEM banks. Halving HBM/DMA/TMEM channels does increase
transfer time and bank contention, but leaves this dominant serial stream
unchanged. Much of the HBM work occurs while that stream is being consumed.

There is also an important simulation limitation: the XRT-VCS host memory
thread advances Ramulator independently of RTL clock edges. These results
measure the current co-simulation's RTL scheduling/streaming behavior; they
must not be interpreted as a cycle-accurate prediction of board HBM bandwidth
sensitivity. The measured AXI read response latency is overwhelmingly only
three RTL cycles, despite Ramulator being present.

No RTL, runtime, kernel, configuration, memory model, or timing-cut changes
were made for this diagnosis. No PnR, hardware run, or commit was performed.

## Capture and method

- MXU32x32, thread16, C2 cuts, total TMEM512KiB in both profiles.
- Eight channels: HBM8/DMA8/TMEM8; four channels: HBM4/DMA4/TMEM4.
- `fpint_gemm_ffn_hw`, M1 or M4, K=N256, q32/d0/t0/r1.
- Same configured builds and release/PERF simulators as the preceding
  comparison; `ci/run_black.sh xrt-vcs-sim --perf 3`. Source/config/binary
  identities checked before and after capture. Four strict PASS results.
- Existing last-M256 FSDBs were archived before rerunning M1/M4.
- Used `fsdb_cli.report()` directly on the four saved FSDBs: 197 signals per
  eight-channel case and125 per four-channel case, including internal bank
  requests, physical SRAM enables, AXI handshakes, local-DMA queues, and the
  active `VX_gemm_unit_v2/u_compute_core`.
- Samples are stable falling-edge values consumed at the following rising
  edge, period10,000ps. Cycle0 is the first invocation-active interval. For
  every sample, `perf_total_cycles_r == sample_index`; window lengths exactly
  equal the host GEMM-node `total_cycles` values below. Transactions are
  counted with valid AND ready per cycle, not signal transitions.
- All measured controls are known. The unused command payload is X during
  its initial15 invalid cycles; it is checked/used only on command enqueue.

| M | Eight channels, captured | Four channels, captured | Difference | Previous three-run medians |
| ---: | ---: | ---: | ---: | --- |
| 1 | 757 | 816 | +59 / +7.79% | 756 /816 |
| 4 | 783 | 824 | +41 / +5.24% | 784 /824 |

Use the captured values for waveform accounting, not the earlier medians.
The one-cycle differences do not change the conclusion.

## 1. The unchanged serial Weight path dominates

The256x256 INT4 matrix contains32KiB of Weight. Both M values perform64
Weight commands of8 beats each: **512 accepted64B beats**. A32x32 INT4
microtile is512B; `MXU_WLOAD_NUM=4` loads four rows per cycle and takes8
cycles per tile. Increasing HBM ports does not widen this one GEMM input.

M1 performs one compute issue per microtile; M4 reuses it for four issues.
Consequently the underlying cadence is approximately one issue per8cycles
for M1, or four consecutive issues per8cycles for M4, even with ready data.

| Metric | M1 ch8 | M1 ch4 | M4 ch8 | M4 ch4 |
| --- | ---: | ---: | ---: | ---: |
| Accepted Weight beats | 512 | 512 | 512 | 512 |
| First / last Weight beat, cycle | 79 /650 | 98 /709 | 73 /649 | 96 /690 |
| Weight first-to-last span, inclusive | 572 | 612 | 577 | 595 |
| Weight bubbles inside that span | 60 | 100 | 65 | 83 |
| Weight GEMM valid AND NOT ready, whole invocation | 0 | 0 | 0 | 0 |
| Input / compute issues | 64 /64 | 64 /64 | 256 /256 | 256 /256 |
| First / last compute issue | 87 /651 | 106 /710 | 81 /653 | 104 /694 |
| Pending compute with Weight version not ready | 457 | 484 | 250 | 253 |

`pending` means both prealigner output and its metadata are valid. Zero-point
not-ready occurs for2 pending cycles in each case, overlapping Weight waits;
there are no pending cycles with zero tree credits. Do not sum overlapping
wait predicates.

The Weight sink never backpressures a valid beat. All512 bank-side Weight
grants appear at the sink **exactly five cycles later**, in all four captures.
Thus the measured Weight gaps are upstream supply gaps, not rejection by
the GEMM weight register. For M4, excluding one long command-supply gap,
ch8 supplies512 beats in512cycles and ch4 in515cycles.

Input-fire gaps alone are not compute utilization: the prealigner buffers
input. The actual `compute_fire` gap histograms are in `summary.json`. For
example, M4 has192 consecutive-issue gaps and59 four-bubble gaps in both
profiles. This is the same four-issue/eight-cycle pattern, not a halving of
the compute feed rate when channels are halved.

RTL references:

- [Active unit instantiation](../../../hw/rtl/core/gemm/VX_gemm_node.sv#L1522).
- [Single Weight handshake](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1066).
- [Weight-version gating of compute](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1531).
- [Weight local DMA](../../../hw/rtl/mem/VX_tmem_subsystem.sv#L903).

## 2. HBM and TMEM bandwidth reduction is visible, but is not the main limit

Measured AXI traffic is at `vortex_axi/dma_axi_m[p]`, on the DMA side of the
per-HBM-port mux. It excludes LSU traffic and is not a physical HBM-pin
measurement. One accepted data beat is64B. The number of read-active cycles
is the union of cycles with at least one accepted DMA R beat, not the
first-to-last transaction span or the HBM engine's busy counter.

| Metric | M1 ch8 | M1 ch4 | M4 ch8 | M4 ch4 |
| --- | ---: | ---: | ---: | ---: |
| AXI read beats | 656 | 656 | 704 | 704 |
| AXI write beats | 8 | 8 | 32 | 32 |
| Cycles with at least one R beat | 87 | 184 | 90 | 202 |
| Peak simultaneously accepted R beats/cycle | 8 | 4 | 8 | 4 |
| Read beat utilization of ports over invocation | 10.83% | 20.10% | 11.24% | 21.36% |
| Physical TMEM accesses, read +write | 1376 | 1376 | 1664 | 1664 |
| Physical TMEM bank-slot utilization over invocation | 22.72% | 42.16% | 26.56% | 50.49% |
| Last AXI R cycle | 505 | 556 | 509 | 550 |
| Last Weight sink cycle | 650 | 709 | 649 | 690 |

Utilization denominators are `ports * total_cycles` and `banks * total_cycles`.
TMEM banks are single-ported, so read and write use the same capacity. These
are whole-invocation averages, not a claim that individual bursts never
saturate: bursts demonstrably reach all8 or4 ports simultaneously.

HBM reads consume about twice as many active cycles with four ports. Yet
the last read still completes140-153cycles before the last Weight beat.
The current stream consumes at most64B/cycle while four ports can accept
up to256B/cycle in this model. Bank aggregation also exceeds this one
stream's demand, although other clients occasionally contend with it.

Read traffic is not just the32KiB Weight matrix: the measured total includes
input and quantization data and their actual DMA access granularity. The
report uses accepted bus beats rather than estimating traffic from tensor
element counts. Burst lengths are1 or4beats:128 four-beat AR requests in
every case, plus144 single-beat requests for M1 or192 for M4.

## 3. Overlap and exact location of the extra cycles

Of the AXI read beats,488/656 for M1 and512/704 for M4 arrive between the
first and last Weight sink beats, in both profiles. Most HBM read work is
therefore temporally overlapped with the long Weight-stream phase.

The HBM busy/pipeline-occupied overlap increases from174 to245cycles for
M1 and169 to266 for M4. Physical R transfers occur simultaneously with a
Weight sink handshake for53 to107cycles (M1) and43 to109cycles (M4).
These are different predicates; none means one arithmetic issue every cycle.

In particular, class3's `any_dma_busy` includes **local** DMA and CPU DMA,
not only HBM. Its overlap values553/581 for M1 and532/535 for M4 cannot
be presented as HBM-only DMA/compute overlap. `gemm_unit_computing` itself
means the pipeline is nonempty, including dependency waits.

The following is an exact, non-overlapping accounting of each invocation:

| Component, cycles | M1 ch8 | M1 ch4 | M1 delta | M4 ch8 | M4 ch4 | M4 delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Invocation start to first Weight beat | 79 | 98 | +19 | 73 | 96 | +23 |
| Accepted Weight beats | 512 | 512 | 0 | 512 | 512 | 0 |
| Weight bubbles corresponding to bank arbitration losses | 24 | 51 | +27 | 0 | 3 | +3 |
| One long Weight command-supply gap | 36 | 49 | +13 | 65 | 80 | +15 |
| After last Weight beat to invocation end | 106 | 106 | 0 | 133 | 133 | 0 |
| **Total** | **757** | **816** | **+59** | **783** | **824** | **+41** |

This is observed schedule accounting, not a counterfactual prediction that
removing one stall would leave every other event unchanged.

For every Weight arbitration loss, another requester wins the same bank:

| Winner during Weight denial | M1 ch8 | M1 ch4 | M4 ch8 | M4 ch4 |
| --- | ---: | ---: | ---: | ---: |
| HBM DMA | 8 | 17 | 0 | 0 |
| Input | 9 | 9 | 0 | 0 |
| Scale | 3 | 17 | 0 | 1 |
| Zero-point | 4 | 8 | 0 | 2 |

The long gap occurs after384 Weight beats in all four runs. In sink-cycle
coordinates the gaps are482-517,520-568,457-521,483-562 respectively.
Their corresponding bank-side windows contain **no Weight request**, so
these are not long arbitration stalls. The local-DMA command queue empties;
the next command enqueues at510,561,514,555 and its first Weight reaches
the GEMM sink8cycles later. HBM is active during much of this interval.
This establishes an upstream command/data preparation gap. It does not
alone identify every controller dependency responsible for withholding
the next command, and no unmeasured dependency is assigned a cycle cost.

## 4. Important memory-model limitation

The exact FIFO-matched `AR handshake -> first R handshake` histograms,
using the DMA engine's fixed read ID0, are:

| Case | 3 cycles | 4 cycles | 5 cycles |
| --- | ---: | ---: | ---: |
| M1 ch8 | 256 | 14 | 2 |
| M1 ch4 | 269 | 3 | 0 |
| M4 ch8 | 316 | 4 | 0 |
| M4 ch4 | 318 | 2 | 0 |

All four simulator logs record request/response stall-entry probabilities0%.
This does **not** mean there is no Ramulator: `sim/common/dram_sim.cpp`
instantiates an HBM2 model. The relevant integration is:

1. [The asynchronous host loop](../../../sim/xrtsim_vcs/xrt_sim_vcs.cpp#L125)
   repeatedly calls `process_axi_events()` without an RTL-cycle token.
2. [Every such call ticks DramSim](../../../sim/xrtsim_vcs/xrt_sim_vcs.cpp#L468).
3. [The memory socket protocol](../../../sim/xrtsim_vcs/vcs_protocol.h#L31)
   transfers AR/AW/W/R/B transactions, not synchronized clock ticks.
4. [The testbench response driver](../../../sim/xrtsim_vcs/tb_vcs_xrtsim.sv#L486)
   drains queued R beats back-to-back when not stalled; the
   [stall parameters](../../../sim/xrtsim_vcs/tb_vcs_xrtsim.sv#L601) default to0% entry.

Thus Ramulator time is not guaranteed to correspond to RTL-cycle time in
this integration. The waveform proves the low effective response latency
for these captures; the source explains why merely enabling Ramulator does
not make these node-cycle results calibrated board-HBM measurements.

The architectural conclusion is consequently scoped: **in this simulation,
small-M is Weight-feed limited, not aggregate-HBM-bandwidth saturated**.
The user's expectation can still hold on hardware or a clock-synchronized
memory model if external service bandwidth/latency becomes the bottleneck.
No quantitative hardware slowdown can be inferred from these four waves.

## Artifacts and reproduction

- [Capture script](capture.py), [capture results](capture_results.json).
- [fsdb_cli extraction](extract.py), [cycle-accounting script](analyze.py).
- [Combined metrics](summary.json); each case has `analysis.json`,
  `sampled.json`, and per-signal raw timestamp/value caches under `signals/`.
- FSDBs: [M1 ch8](ch8/m1/vcs_cosim.fsdb), [M1 ch4](ch4/m1/vcs_cosim.fsdb),
  [M4 ch8](ch8/m4/vcs_cosim.fsdb), [M4 ch4](ch4/m4/vcs_cosim.fsdb).
- Per-case `result.json`, `wrapper.log`, `simv.log`, and `command.json`
  preserve PASS/error checks, cycle counters, wave hashes and exact commands.

From the repository root, regenerate the analysis without rerunning RTL:

```sh
python3 agent-tasks/mxu32-channel8-vs4/fsdb-analysis/extract.py
python3 agent-tasks/mxu32-channel8-vs4/fsdb-analysis/analyze.py
```

Extraction caches all successfully read signals. The initial missing-clock
path in `extract.log` was an analysis-tool lookup error, corrected to
`/tb_vcs_xrtsim/ap_clk`; `extract_extended.log` records successful extraction
of all four cases. It was not a simulator failure or RTL change.
