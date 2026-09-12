# Why improve gains more at M=4: FSDB analysis

Analyzed on 2026-09-10 using `tools/fsdb_cli`, with fresh final-RTL `xrt-vcs-sim` captures for th16 / MXU16x16, M=4, K=N=512. Both runs passed numerical verification and reproduced the previous GEMM/core counts exactly: improve 6,448/12,206 cycles; naive 61,552/68,154 cycles. Configuration and M256 results are in [the latency report](fpint_gemm_latency.md).

## Finding

**The external-memory path is faster in improve, but HBM bandwidth alone does not explain the 9.546x M4 speedup. The waveform exposes repeated command startup and completion serialization in naive, leaving the MXU input idle even when external DMA is idle.** Improve pipelines these short commands and retires ordinary input commands at ingress completion instead of waiting for each command's writeback drain.

If “bandwidth” means the achieved rate of supplying operands to the MXU, improve does supply them much faster. The distinction is the cause: the evidence points to command latency, synchronization, and local data delivery, rather than a demonstrated physical HBM bandwidth ceiling. These captures do not isolate the bandwidth limit of LMEM/TMEM or measure performance under a bandwidth-only change.

The [input-gap root-cause follow-up](fpint_gemm_naive_input_gap_root_cause.md) decomposes the 23-cycle startup into 7 cycles of DMA launch, 13 cycles of LMEM round trip, and 3 cycles of response staging. It also traces the writeback fence and the subsequent NOTIFY/WAIT command sequence.

## 1. Same external bytes, faster external transfer path

All cycle counts below are within the controller's GEMM-active interval. “External DMA” means naive's `accel_perf.cpu_dma.busy` or improve's `accel_perf.hbm_dma.aggregate.busy`; the CPU-DMA name denotes the naive transfer engine, not CPU instruction execution.

| Measurement | naive | improve |
|---|---:|---:|
| GEMM cycles | 61,552 | 6,448 |
| External DMA read bytes | 180,224 | 180,224 |
| External DMA write bytes | 4,096 | 4,096 |
| External DMA busy, elapsed cycles | 10,130 | 1,599 |
| External DMA idle, elapsed cycles | 51,422 | 4,849 |
| Useful bytes / external-DMA-busy cycle | 18.20 | 115.27 |
| Equivalent useful transfer rate at 100 MHz | 1.820 GB/s | 11.527 GB/s |

The useful transfer-rate ratio is **6.335x**. It includes request/wait/drain time while the DMA engine is busy and uses DMA payload counters; it is **not peak HBM bus bandwidth**, nor an AXI wire-byte measurement. Improve uses eight tile-DMA channels and dedicated TMEM; naive uses the CPU-DMA/D-cache/LMEM path. Both use the same simulated HBM configuration. The model is uncalibrated, so these rates are simulated rates, not board measurements.

Improve's `hbm_dma.aggregate.active_cycles = 10,356` is a sum across concurrent channels. It must not be used as elapsed transfer time. The waveform's aggregate `busy` predicate gives 1,599 cycles; individual channel active-cycle extrema are 1,191 and 1,378.

An accounting partition of the total 55,104-cycle difference is:

| Partition | Difference, naive minus improve | Share of total difference |
|---|---:|---:|
| Cycles with external DMA busy | 8,531 | 15.48% |
| Cycles with external DMA idle | 46,573 | 84.52% |

This is a partition of two observed timelines, **not causal attribution of 15.48% to bandwidth**. Changing bandwidth can also change overlap and scheduling. Nevertheless, most of the observed difference is outside external-DMA activity, and the repeated idle-DMA command stalls below cannot be described as ongoing external payload transfers.

## 2. Naive's MXU is ready, but receives input only 6.65% of the time

The common compute core's `input_fire` is the input valid/ready handshake. Both runs accept exactly 4,096 input packets.

| GEMM-window measurement | naive | improve |
|---|---:|---:|
| Input handshake cycles | 4,096 | 4,096 |
| Handshake cycles / GEMM cycles | 6.655% | 63.524% |
| Input ready high | 61,552 | 5,634 |
| Input valid, not ready | 0 | 31 |
| Input not valid, ready | 57,456 | 1,538 |
| Input not valid, not ready | 0 | 783 |
| External DMA idle and no input handshake | 47,868 | 1,719 |
| Input-DMA command starts | 1,024 | 1,024 |
| Command start interval, median | 58 cycles | 5 cycles |
| Command start to first input, median | 23 cycles | 7 cycles |

Naive's ready is high for the entire job. Its missing input cycles are therefore upstream supply gaps, not input backpressure from a saturated MXU. In particular, 47,868 cycles have neither external DMA activity nor an MXU input handshake. `consumer_block_raw_valid` and `psum_rd_order_block` are also zero throughout naive's active interval.

These percentages measure input admission, not array-wide arithmetic utilization. The existing `compute_cycles` and `mac_count` counters are unimplemented and cannot supply a FLOPs-based utilization estimate.

## 3. A four-row command repeatedly waits through its whole completion path

Pairing naive's 1,024 input-DMA starts with its 4,096 input handshakes, 1,024 tagged writebacks, and 1,024 packetizer completions gives:

| Event-to-event latency | Minimum | Median | Maximum |
|---|---:|---:|---:|
| Command start → first input | 23 | 23 | 23 |
| First input → last input | 3 | 3 | 6 |
| Last input → tagged writeback | 16 | 16 | 20 |
| Tagged writeback → command done | 3 | 3 | 3 |
| Command done → next command start | 7 | 13 | 144 |
| Command start → next command start | 53 | 58 | 193 |

Units are logic cycles. Four consecutive input handshakes span three event-to-event cycles. The 23-cycle startup is an observed end-to-end command-to-input latency; this analysis does not divide it into pure SRAM latency versus DMA/control pipeline stages.

The following consecutive commands occur entirely while external DMA is idle. Timestamps are cycles relative to naive GEMM activation, whose absolute FSDB time is 83,325,000 ps.

| Command index (zero-based) | Start | First input | Last input | Writeback | Done | Next start |
|---:|---:|---:|---:|---:|---:|---:|
| 12 | 1,501 | 1,524 | 1,527 | 1,543 | 1,546 | 1,559 |
| 13 | 1,559 | 1,582 | 1,585 | 1,601 | 1,604 | 1,617 |
| 14 | 1,617 | 1,640 | 1,643 | 1,659 | 1,662 | 1,675 |

Each representative 58-cycle interval consists of `23 + 3 + 16 + 3 + 13` event-to-event cycles, with only four accepted input rows. Improve has the same 1,024 four-row commands but a median start interval of five cycles, a 6–12-cycle start-to-first-input latency, and up to three input command contexts in flight.

The RTL explains the difference:

- In [VX_gemm_node_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv), `input_read_flag.idle` requires `!packetizer_active`. `common_writeback_drained` drives the packetizer's `completion_valid`; this waits for compute completion and physical LMEM write queues to drain. [VX_gemm_input_packetizer.sv](../../../hw/rtl/core/gemm/VX_gemm_input_packetizer.sv) derives `command_done` from this completion, rather than the last admitted input packet.
- [VX_gemm_fsm_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_fsm_naive.sv) emits a GEMM completion NOTIFY/WAIT for each microcommand. The parent command queue is full for 51,113 cycles; 42,611 of those occur with external DMA idle. The FSM spends 47,871 cycles in `S_MXU_PRE_NEXT_W_NTF`, whose transition waits for `can_emit`. Its name does not mean all those cycles are waiting for weight bytes: the immediate block is command-queue availability, as wired in [VX_gemm_ctrl_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv).
- In [VX_gemm_node.sv](../../../hw/rtl/core/gemm/VX_gemm_node.sv), `normal_input_complete` retires an ordinary input context after registered ingress completion. Commands marked `notify_on_writeback` retain the writeback fence. Multiple contexts allow subsequent work to proceed before prior arithmetic/writeback drains. The waveform has only 16 tagged-writeback pulses in improve versus 1,024 in naive; those completion granularities differ and should not be treated as equal work counts.

The mechanism is therefore repeated startup plus serialized completion and synchronization, with different local delivery paths. The waveform does not support attributing every supply gap to an LMEM bank-bandwidth shortage.

## 4. Why the relative gain is larger at M=4 than M=256

The measured GEMM speedups are 9.546x at M=4 and 5.031x at M=256. The controller uses MT=KT=NT=128, with MXU K/N microtiles of 16. Consequently:

| Shape | Input microcommands | Effective rows per input command |
|---|---:|---:|
| M4/K512/N512 | 1,024, directly counted in these FSDBs | 4 |
| M256/K512/N512 | 2,048, derived from tiling | 128 |

The command count is `ceil(M/128) × (512/128)² × (128/16)²`. Thus M256 has only twice as many commands, but each command streams 32 times as many rows. Startup and completion latency can be amortized over much more useful work. At M4, the naive pipeline repeatedly starts and drains for only four rows, so improve's ability to overlap commands has a larger relative benefit.

This M256 explanation is an inference from RTL tiling and the verified latency results. The fresh waveform analysis here covers M4 only; it does not claim that M256 has the same exact 23/16/3-cycle phase latencies or quantify its bandwidth-only contribution. A controlled bandwidth sweep or matching M256 signal extraction would be needed for that attribution.

## Counter correction to the earlier latency report

The logged DMA/MXU overlap values (M4: 28.470% naive and 91.795% improve) use different DMA visibility. Under `GEMM_NAIVE`, [VX_core.sv](../../../hw/rtl/core/VX_core.sv) ties `lmem_dma_input`, `lmem_dma_weight`, `lmem_dma_sz`, and `lmem_dma_output` performance structs to zero. The shared `any_dma_busy` predicate ORs these fields with CPU/HBM DMA activity. Improve therefore includes local operand/output DMA activity that naive omits.

Those logged percentages are not an apples-to-apples scheduling metric. This analysis instead uses explicitly selected external-DMA busy signals and the common input valid/ready interface within each GEMM window.

## Evidence and reproduction

- [Computed comparison and phase statistics](fsdb_m4/analysis_summary.json).
- Improve: [capture manifest and verification](fsdb_m4/improve/manifest.json), [FSDB](fsdb_m4/improve/m4.fsdb), [active window](fsdb_m4/improve/active_window.json), [counters](fsdb_m4/improve/counters.json), [signal paths and cycle statistics](fsdb_m4/improve/timeline_summary.json).
- Naive: [capture manifest and verification](fsdb_m4/naive/manifest.json), [FSDB](fsdb_m4/naive/m4.fsdb), [active window](fsdb_m4/naive/active_window.json), [counters](fsdb_m4/naive/counters.json), [signal paths and cycle statistics](fsdb_m4/naive/timeline_summary.json), [all command phases](fsdb_m4/naive/command_phases.json).
- Raw `fsdbreport` CSVs and compressed per-cycle arrays are retained in each variant's `csv/` directory and `timeline.npz` file. Critical valid/ready/start/busy signals contain no unknown samples. Improve's unused `input_dma_idle` signal has four unknown samples and is excluded from conclusions.

`extract_summary.py` finds the active controller interval with `fsdb_cli.report` and exports scalar counters just after completion. `extract_timeline.py` exports signal transitions with the same API and samples them once per 10,000 ps logic cycle over the half-open active interval. The resulting cycle lengths and input counts match the simulation PERF logs. The improve interval is [81,985,000, 146,465,000) ps; naive is [83,325,000, 698,845,000) ps.

From the repository root, re-extract the retained captures without rerunning simulation:

```bash
for variant in improve naive; do
  python3 agent-tasks/fpint-gemm-bandwidth-analysis/extract_summary.py "$variant"
  python3 agent-tasks/fpint-gemm-bandwidth-analysis/extract_timeline.py "$variant"
done
python3 agent-tasks/fpint-gemm-bandwidth-analysis/summarize.py
```

The extractor uses cached CSVs if present. Each JSON summary records the full hierarchy paths. Interface members use slash paths; packed performance-struct fields use dot suffixes such as `/core/accel_perf.cpu_dma.busy`.

The [capture script](../../../agent-tasks/fpint-gemm-bandwidth-analysis/run_capture.py) records the exact wrapper command/config in each manifest. It runs from the previously configured build directory after sourcing the matching task configuration, enables FSDB, and preserves the earlier simulator executable before forcing re-elaboration. No RTL was changed for this waveform analysis.
