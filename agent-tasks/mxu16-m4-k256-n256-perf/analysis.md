# MXU16 M4 K256 N256 performance analysis

## Scope

- Configuration: `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`
- Blackbox: `fpint_gemm_ffn_hw`
- Arguments: `-m 4 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1`
- Mode: `ci/run_black.sh xrt-vcs-sim --debug 3`
- Result: `PASSED`
- VCS clock period: 10 ns. All conclusions below use cycle counts, not VCS wall-clock runtime.

The application reports `M=4 (padded to 8)`, but the RTL emits four Input
packets per microtile command. There is no extra eight-row arithmetic work.

## Work decomposition

For a 16x16 MXU:

- K microtiles: 256 / 16 = 16
- N microtiles: 256 / 16 = 16
- GEMM microtile commands: 16 x 16 = 256
- Row packets per command: 4
- Input handshakes and compute issues: 256 x 4 = 1,024
- MACs per compute issue: 16 K lanes x 16 N lanes = 256
- Total MACs: 1,024 x 256 = 262,144, equal to M x K x N

The 256 commands form two 128-column phases. Each phase has 128 commands and
512 compute issues. Inside a phase, each 128-wide K tile contributes eight K
microtile commands per accumulator base.

## HBM DMA and compute overlap

The final `TMEM_DMA_SCHED_PERF` record reports 32 completed HBM descriptors,
16 loads, 16 stores, 1,436 compute-active cycles, 264 load-active cycles, and
202 load/compute overlap cycles. Reconstructing the serialized descriptor
intervals from `TMEM_DMA_CHUNK_ISSUE/COMPLETE` reproduces the 202-cycle load
overlap exactly and also measures store overlap.

| DMA direction | Descriptors | DMA-active cycles | Overlap with compute | DMA cycles hidden | Compute cycles covered |
|---|---:|---:|---:|---:|---:|
| HBM -> TMEM load | 16 | 264 | 202 | 76.5% | 14.1% |
| TMEM -> HBM store | 16 | 179 | 49 | 27.4% | 3.4% |
| Combined | 32 | 443 | 251 | 56.7% | 17.5% |

Important timing facts:

- All 62 non-overlapped load cycles are the initial load prologue. After
  compute starts, every remaining active HBM-load cycle overlaps compute.
- The compute pipeline is active in two intervals of 720 and 716 cycles,
  separated by 110 pipeline-empty cycles at the 128-column phase boundary.
- During that 110-cycle gap, the first output phase consumes 42 active HBM
  store cycles; the other 68 cycles are output-command/local-store setup and
  spacing, not active external DMA transfer.
- The final compute-active cycle is followed by a 224-cycle output epilogue.
  The last eight stores are active for 88 of those cycles; 136 cycles are
  descriptor/control spacing.
- From the first active HBM descriptor cycle to the final store completion is
  1,832 cycles: 62-cycle load prologue + 1,546-cycle first-to-last compute span
  (including the 110-cycle phase gap) + 224-cycle store epilogue.
- `pending_max=4`, but `store_to_load_switch=0`. The M=4 output stores are
  non-chunkable single-descriptor bypass operations, so store preemption and
  reorder switching do not contribute to this case.

Conclusion: HBM read bandwidth/latency is already well hidden after startup.
Output-store phase handoff and epilogue are much less overlapped and matter
more to end-to-end latency.

## Bubble at the gemm_unit input

`GEMM_INPUT_PACKET` is the actual local-DMA-to-gemm-unit ready/valid
handshake. Between the first and last accepted packets:

| Metric | Cycles/count |
|---|---:|
| Accepted packets | 1,024 |
| First-to-last span | 1,530 cycles |
| Bubble cycles | 506 cycles (33.1%) |
| Input utilization | 66.9% |

The 506 bubbles split as follows:

| Cause at the interface | Cycles | Share of bubbles |
|---|---:|---:|
| No ordered local-DMA data valid | 479 | 94.7% |
| gemm input pipe backpressure | 27 | 5.3% |
| W/S/Z/ACC admission dependency not ready while data was valid | 0 | 0% |

The 479 producer-side bubbles break down further:

- 121 cycles have no command at the install head. These are all inside the
  128-column phase transition.
- 358 cycles have a command but no sink owner/data valid.
  - 258 cycles are recovery/fill of the registered response-RAM sink stage.
  - 98 cycles wait for the expected TMEM response.
  - 2 cycles occur before the expected response slot is issued.
- In the 98 response-wait cycles, no later response slot is ready. Therefore
  there are zero observed head-of-line stalls from ordered/reordered response
  handling in this shape. Increasing reorder depth alone would not remove
  these bubbles.

All 27 input-pipe backpressure cycles coincide with `weight_ready=0`; they are
weight-generation stalls propagated back to the local-DMA sink.

Removing the one 126-cycle inter-phase packet gap gives the steady two-phase
issue view:

- 1,024 accepts in 1,404 cycles
- 380 bubbles (27.1%)
- 72.9% input utilization
- 353 ordered-data-not-ready bubbles and 27 weight-induced backpressure bubbles

Burst shape matters for M=4. Of 256 four-row bursts, 122 have all four packets
back-to-back. Burst-internal gaps cost 230 cycles; inter-burst gaps cost 276
cycles, including the one 126-cycle phase-boundary gap.

## Bubble at actual MXU compute issue

`GEMM_V2_COMPUTE_FIRE` counts actual accepted MXU work. The first-to-last issue
span contains 1,024 fires and 505 holes, for 67.0% issue utilization. Excluding
the 126-cycle phase-boundary gap gives 73.0%.

Using the exact `!pipeline_empty` intervals is the cleaner utilization metric:

| Metric | Cycles/count |
|---|---:|
| Compute-active cycles | 1,436 |
| Compute fires | 1,024 |
| Active cycles without a compute fire | 412 (28.7%) |
| Compute-fire utilization while active | 71.3% |

The 412 active-but-no-fire cycles are:

- 294 cycles without an aligned preprocessed input/control pair. This includes
  input-stream spacing plus pipeline fill/drain effects.
- 118 cycles with a valid preprocessed input but `compute_ready=0`.
  Every one of these is `weight_ready=0`; none is caused by tree credit,
  zero-point generation, or the zero-point consume channel.

Weight writes themselves are efficient once started: all 256 weight commands
deliver their four 32-byte physical beats in four consecutive cycles. The
remaining problem is inter-command timing. The next ping-pong weight
generation is not always complete when a four-row M=4 compute burst needs it.
With only four rows of reuse, the four-cycle weight fill has little time to be
amortized.

Input-to-compute latency is bounded and stable:

- 5 cycles: 817 packets
- 6 cycles: 178 packets
- 7 cycles: 29 packets

## Optimization priority implied by this run

1. Improve sustained Input local-DMA delivery. Outside the large phase gap,
   353 of 380 input bubbles are missing ordered sink data, dominated by the
   registered sink-stage refill behavior and real TMEM response gaps.
2. Improve output phase handoff/store overlap. The 110-cycle middle gap and
   224-cycle final epilogue are much more exposed than HBM loads.
3. Pull the next weight generation earlier or reduce inter-weight-command
   spacing. Weight availability causes all 118 compute-resource stalls and all
   27 input backpressure cycles.
4. Do not prioritize deeper response reordering for this shape. No later-ready
   response was blocked behind a missing head response.

The arithmetic datapath itself accepts one packet per cycle whenever data and
the next weight generation are ready; tree credit, scale, zero point, and ACC
admission do not limit this run.
