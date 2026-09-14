# SLR pipeline simulation results

Current primary simulation status: **the final source, including weight-data
TX preservation, MXU input-data TX/RX preservation and boundary reset-extraction
attributes, passes all four
measured host-PERF cases within 2%, and all 12 functional launches pass**.
Internal GEMM latency is not unchanged: the latest overlap compute-fire span
increases from frozen median 566 to 630 cycles (+11.31%), and serialized
output-store transport also costs cycles. This is a bounded whole-application
simulation gate, not physical timing/routing closure or a claim covering all
workloads. MXU16 compatibility is recorded separately in
`compatibility-results.md`. Earlier iterations below are retained evidence.

## Initial implementation, 2026-09-05 15:47

Functional checks pass, but the first implementation does **not** meet the
2% primary-profile performance acceptance criterion: the overlap QCOL case
regresses by 3.48%. These results are retained before further optimization.
No synthesis or PnR acceptance is implied.

### Build and functional evidence

- Configured build: `build/experiment-archive/build_slr_verify`, sourced primary TH16/MXU32/W4 config
  with `GEMM_SLR_PIPELINE`; eight response slots remain unchanged.
- Fresh candidate `simv` SHA256:
  `4aaa1f369aa1490612211caeeb1dfb9309be7a7973a4aafb19e24890fe535e24`.
  Source compiled and linked at 15:44, after initial SLR RTL implementation.
  Compiled RTL shared object `simv.daidir/_892155_archive_1.so` SHA256:
  `65dae522cc0e62db44665ef5e3fc8c6d711af15627b6c17ef92380276760ae96`.
- Invocation: `measure_gemm.py --build build/experiment-archive/build_slr_verify --out
  build/experiment-archive/build_slr_verify/gemm-results --repeat 3 --timeout 1800`, with vendor-only
  `SIMLIB_DIR` as in `baseline-results.md`.
- All 12 blackbox launches pass numerical checking and deterministic
  return-code/fatal-marker checks; `gemm-results/summary.json` retains exact
  arguments, configuration hash, image hashes and metrics. Per-run application
  and compressed RTL logs are adjacent. The optional legacy command ledger
  is disabled in both baseline and candidate, as documented in the baseline.

Focused tests ran through `tools/verify_rtl.py unittest --sim vcs` from the
configured build, using system GCC/G++:

| Test | Result | Evidence |
|---|---|---|
| `slr_stream` | PASS | 32 B/64 B plus 96 sideband bits, 4000 ordered transactions, sustained one-per-cycle transport, long/random backpressure and complete drain |
| `slr_mem_bus` | PASS | 32 B/64 B request/response transport and physical completion/drain checks |
| `gemm_dma_slr_bridge` | PASS | Command, prepare, completion and status bridge focused suite |
| `gemm_unit_v2`, SLR latency enabled | PASS | Full suite; `M3_D3_RAW_STALL_PASSED rows=3 qdir=row stalls=1 early=0 nominal=3 writes=6`; `M5_ACC_READ_WRITE_ARBITRATION_PASSED rows=5 qdir=row write_stalls=2 writes=10` |

Deterministic JSON reports are `build/experiment-archive/build_slr_verify/*-verification.json`;
individual compile/simulation logs are under each configured unittest's
`logs/` directory. The existing `gemm_unit_v2` unit flow uses its default
`FPU_FPNEW` numerical model; the whole-system blackbox uses the primary
Xilinx floating-point configuration.

### Performance comparison

Host values are independent-run medians, against the frozen baseline in
`baseline-results.md`.

| Case | Baseline cycles | Initial SLR cycles (all samples) | Median change | 2% gate |
|---|---:|---|---:|---|
| Smoke QCOL | 5799 | 5876, 5876, 5874 | +1.33% | PASS |
| Overlap QCOL | 6474 | 6699, 6697, 6699 | +3.48% | **FAIL** |
| QROW | 6176 | 6176, 6174, 6174 | -0.03% | PASS |
| Odd-tail QCOL | 5873 | 5872, 5873, 5874 | 0.00% | PASS |

Internal spans expose costs hidden by host-side run-to-run variation:

| Case | Baseline compute-fire span | Initial SLR compute-fire span | Baseline final store-accept span | Initial SLR final store-accept span |
|---|---:|---:|---:|---:|
| Smoke QCOL | 25 | 34 | 0 | 0 |
| Overlap QCOL | 563–568 | 747 | 84 | 108 |
| QROW | 216 | 216 | 88 | 96 |
| Odd-tail QCOL | 26 | 35 | 26 | 34 |

For overlap QCOL the first DMA accept to last logical completion increases
from 766–774 cycles to 991–993 cycles. The four serialized final output-store
accepts gain exactly 24 cycles across their three gaps. Source-registered
completion transport and drain have a visible cost even when the host
performance criterion passes.

### Overlap regression localization

The detailed comparison uses baseline and candidate `overlap_qcol-3` traces.
Baseline raw trace:
`/tmp/vortex-slr-baseline-5d8fc73f.4w9kmJ/results-w4/overlap_qcol-3.simv.log.gz`.
Candidate raw trace:
`build/experiment-archive/build_slr_verify/gemm-results/overlap_qcol-3.simv.log.gz`.

The weight DMA's next descriptor is already queued before the repeated gap:

| Event, simulation cycle | Baseline | Initial SLR |
|---|---:|---:|
| Weight command 0 enqueue | 5215 | 5224 |
| Command 0 first source request | 5216 | 5225 |
| Command 0 last (eighth) source request | 5223 | 5232 |
| Command 0 first local destination write | 5223 | 5235 |
| Command 0 last local destination write | 5230 | 5242 |
| Weight command 1 enqueue | 5216 | 5225 |
| Command 1 first source request | 5224 | 5236 |

- Matching weight source-request to local destination-write latency is
  exactly 7 cycles in the baseline and 10 in the initial SLR implementation.
- The same response slot's source-request reuse interval is 8 cycles in 62
  ordinary transitions of the baseline, versus 11 cycles in 62 candidate
  transitions. One inter-phase gap is excluded (67 versus 62 cycles).
- The queued command is ready well before the 3-cycle source gap, so this
  repeated bottleneck is slot reuse/round-trip latency, not late descriptor
  enqueue. Actual weight installation into SLR2 is later than the local
  destination write and is not established by these particular trace events.
- Compute retains 192 adjacent one-cycle transitions in both runs. The
  inter-group compute gap grows from predominantly 5 cycles (59 occurrences)
  to 8 cycles (60 occurrences), explaining most of the 181-cycle median
  compute-span increase.
- The peak **source requests minus local destination writes** is 7 baseline
  versus 8 candidate after combining simultaneous events by cycle; both
  return to zero. This is an in-flight proxy, not response-RAM occupancy:
  staging can free a response slot before destination acceptance. Never call
  this the exact slot-release measurement.

Follow-up optimization must reduce the lifetime/reuse delay of the existing
eight response slots or otherwise hide the added latency; it must not silently
increase response slot count. Dedicated guarded queue instrumentation is
needed to separate request/response transport, response-RAM staging, actual
slot release and full-slot stalls. Preserve this initial image/result when
recording subsequent iterations.

## Iteration 2: early response-RAM slot release, 2026-09-05 16:00

The SLR weight path now releases a response slot when its payload is captured
by the existing RAM output stage, with same-cycle slot recycling. Descriptor
and command completion still follow actual destination acceptance. The
physical response RAM remains eight slots; no additional payload RAM is used.

### Verification and image identity

- New `gemm_stream_dma_early_release` focused test: **PASS**, including 32 B
  and 64 B early-release modes plus the legacy 64 B mode, 23 beats across two
  descriptors, out-of-order responses, held sink data/metadata, same-slot
  rewrite while the old payload is held, and correct ordered completion.
- Existing `gemm_stream_dma_queue` suite: **PASS**. Both results come from
  `tools/verify_rtl.py` in `build/experiment-archive/build_slr_verify`. Queue-internal plain assertions
  are enabled because they are guarded by `ifndef SYNTHESIS`; the test's
  `NDEBUG` define does not disable these assertions.
- Fresh isolated full-system build: `build/experiment-archive/build_slr_early_verify`.
  The original `build/experiment-archive/build_slr_verify` image and initial results are preserved.
- Accepted image `simv` SHA256:
  `ebde4858a4961b75d98a83cbb2958281fa58920d899ef46f9170c19ff9216186`.
  RTL shared object `_1203784_archive_1.so` SHA256:
  `0e74d91de5c95d4c3e0a5b9d84f57e96a21a4c1ed9c1ab46ae8b4a37b8d5a7ef`.
- The kernel binary hash remains identical to the frozen baseline and initial
  candidate: `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.
- The same primary W4 matrix passes all **12/12** numerical/protocol checks.
  Evidence: `build/experiment-archive/build_slr_early_verify/gemm-results-early-release/summary.json`
  and adjacent per-run logs. The measurement helper also records compiled
  shared-object and application binary hashes.

### Performance: improved, still outside acceptance

| Case | Frozen median | Iteration 2 samples | Median change | 2% gate |
|---|---:|---|---:|---|
| Smoke QCOL | 5799 | 5879, 5801, 5800 | +0.03% | PASS |
| Overlap QCOL | 6474 | 6623, 6624, 6622 | +2.30% | **FAIL** |
| QROW | 6176 | 6174, 6175, 6176 | -0.02% | PASS |
| Odd-tail QCOL | 5873 | 5874, 5874, 5872 | +0.02% | PASS |

The first smoke host sample differs by approximately 79 cycles despite the
same 29-cycle compute span and identical slot metrics in all three launches.
This reinforces the need to retain internal metrics alongside host medians.
All three overlap samples independently exceed the 2% threshold, so its
remaining regression is not explained by that smoke-run variation.

Overlap compute-fire span improves from 747 to **654 cycles** (frozen
baseline 563–568), and total DMA span improves from 991–993 to **897–905**
(baseline 766–774). The final four output-store accept span remains 108
cycles, versus the baseline 84. Smoke, QROW and odd-tail compute spans are
29, 216 and 30 cycles respectively.

### Exact response-slot measurements

`SLOT_ALLOC`, `SLOT_RESPONSE`, `SLOT_RELEASE` and `SLOT_SUMMARY` now provide
actual queue measurements. These are distinct from the earlier
source-minus-destination proxy. Values below are representative third runs;
the full JSON retains each run. All instances report eight physical slots
and peak occupancy eight, and all allocation/response/release counts balance.

| Case | Allocations / responses / releases | Request-to-response latency min/mean/max | Allocation-to-release latency min/mean/max | Same-cycle recycles | Full-slot stalls |
|---|---|---|---|---:|---:|
| Smoke QCOL | 32 / 32 / 32 | 8 / 8.1875 / 9 | 9 / 9.1875 / 10 | 22 | 2 |
| Overlap QCOL | 512 / 512 / 512 | 8 / 8.0234 / 9 | 9 / 9.0527 / 11 | 483 | 7 |
| QROW | 48 / 48 / 48 | 8 / 8 / 8 | 9 / 26.3958 / 39 | 38 | 83 |
| Odd-tail QCOL | 32 / 32 / 32 | 8 / 8.1875 / 9 | 9 / 9.1875 / 10 | 22 | 2 |

Full-slot stalls count cycles with a valid fetch-head descriptor but no
available request slot; they do not include absent-descriptor cycles or every
possible upstream/downstream stall. QROW's longer held-slot latency does not
extend its compute span in these runs because consumer work hides that delay.

The remaining ordinary slot-0 reuse interval is mostly nine cycles (58 of
63 transitions), not eight. The overlap trace also shows descriptor residency
becoming part of the limitation: command 2 cannot enqueue until command 0's
last destination acceptance, even though most physical-slot waits have been
eliminated. For iteration-2 overlap run 1:

| Weight sequence | Enqueue | Source first–last | Destination first–last |
|---|---:|---|---|
| 0 | 5231 | 5232–5239 | 5242–5249 |
| 1 | 5232 | 5241–5248 | 5251–5259 |
| 2 | 5249 | 5250–5258 | 5260–5268 |

The first iteration's repeated 8-cycle compute group gap becomes mostly
6 cycles, versus baseline 5. Further optimization is required before claiming
the primary performance acceptance criterion; do not promote this iteration
as a completed PnR-ready result solely because numerical checks pass.

## Iteration 3: ordered-response stage bypass, 2026-09-05 16:14

The SLR/RAM-backed weight path can capture an arriving, correctly ordered
response directly into the existing logical sink-stage position. Other
responses continue through the response RAM. `RESPONSE_STAGE_BYPASS` defaults
to zero, and the optimized path retains eight physical response slots and the
existing descriptor depth. The implementation adds a private 512-bit payload
register and one selection FF in the primary profile (**513 logical FF bits**,
not a measured post-synthesis resource delta); it does not add a second active
sink-stage entry. Held stage data, metadata and command completion remain
protected against later RAM-slot reuse.

### Accepted image and focused coverage

- Fresh configured build: `build/experiment-archive/build_slr_bypass_verify`; prior iteration builds
  and full-system results are preserved.
- `simv` SHA256:
  `dea4c8b2d64232df985696e6e3ae86dccf13f7519889d9e74251cda70b47d010`.
- Compiled RTL `_1396267_archive_1.so` SHA256:
  `95f23356543ece967028459b7cbed18fd9c0da86756cfd5313d6e29b2b179fd1`.
- Evidence: `build/experiment-archive/build_slr_bypass_verify/gemm-results-bypass/summary.json` and
  adjacent logs; the same case order, three independent launches per case,
  primary config, W4, reference checks and tracing settings were used.
- Generic `gemm_stream_dma_queue` regression: **PASS**.
- Extended six-case `gemm_stream_dma_early_release` test: **PASS**.
  Both early-only widths, both bypass widths, and legacy 64 B mode pass the
  out-of-order/backpressure/held-stage overwrite tests. Each bypass width
  exercises both fast and RAM captures (1/22) and 15 recycle events.
- Its additional ordered 32-beat case reports **29 fast captures, 3 RAM
  captures, 19 consecutive fast captures, one fast-to-RAM and one RAM-to-fast
  transition, three held-fast-stage stall cycles, and 16 writes after sequence
  wrap**. Numerical payload, tags, final flags and completion are checked.
- Deterministic focused-test JSON, compile logs and simulation logs are
  copied into `build/experiment-archive/build_slr_bypass_verify/unit-evidence/`, including separate
  `early-release-ordered.*` files for the final six-case test.

### Primary performance gate: PASS

| Case | Frozen median | Iteration 3 samples | Median change | 2% host-PERF gate |
|---|---:|---|---:|---|
| Smoke QCOL | 5799 | 5799, 5800, 5800 | +0.017% | PASS |
| Overlap QCOL | 6474 | 6552, 6548, 6553 | +1.205% | PASS |
| QROW | 6176 | 6174, 6174, 6175 | -0.032% | PASS |
| Odd-tail QCOL | 5873 | 5873, 5875, 5875 | +0.034% | PASS |

All **12/12** full-system launches pass numerical/protocol checks. Every
individual host-cycle sample is also within 2% of its case's frozen median,
not just each candidate median. One image is used throughout the matrix and
all recorded slot allocation, response and release counts balance.

The internal cost remains real and is not covered up by the host gate:

| Case | Frozen compute span | Iteration 3 compute span | Frozen DMA total span | Iteration 3 DMA total span | Frozen / iteration 3 final store-accept span |
|---|---:|---:|---:|---:|---|
| Smoke QCOL | 25 | 28 | 120–121 | 141–142 | 0 / 0 |
| Overlap QCOL | 563–568 | 624–627 | 766–774 | 871–879 | 84 / 108–109 |
| QROW | 216 | 216 | 483–487 | 508–511 | 88 / 96 |
| Odd-tail QCOL | 26 | 29 | 149–156 | 177 | 26 / 34 |

In particular, overlap median compute span is **566 → 626 cycles (+10.60%)**,
while median host PERF is **6474 → 6552 (+1.205%)**. The implementation passes
the measured whole-application criterion; it does not meet a hypothetical
2% limit on the isolated compute span. No claim is made that internal
transport costs disappear for other application shapes.

### Exact slot metrics and fast-path use

Representative third-run values follow; every instance has eight physical
slots and peak occupancy eight.

| Case | Alloc / response / release | Request-to-response min/mean/max | Allocation-to-release min/mean/max | Bypass releases | Same-cycle recycles | Full-slot stalls |
|---|---|---|---|---:|---:|---:|
| Smoke QCOL | 32 / 32 / 32 | 8 / 8.4375 / 10 | 8 / 8.4375 / 10 | 32 | 14 | 1 |
| Overlap QCOL | 512 / 512 / 512 | 8 / 8 / 8 | 8 / 8.06055 / 12 | 504 | 255 | 3 |
| QROW | 48 / 48 / 48 | 8 / 8 / 8 | 8 / 26.0625 / 39 | 17 | 30 | 83 |
| Odd-tail QCOL | 32 / 32 / 32 | 8 / 8.4375 / 10 | 8 / 8.4375 / 10 | 32 | 14 | 1 |

The ordered fast path reduces overlap average allocation-to-release from
9.0527 to 8.06055 cycles, while still retaining the RAM path for reordered or
consumer-blocked responses. Counts are parsed from explicit queue events,
not inferred from destination-write timing. `measure_gemm.py` now includes
slot-event/final-summary balance validation in addition to deterministic
functional pass/failure parsing.

Primary simulation is ready for the plan's next physical implementation
phase. Before calling the overall task complete, require the separately
recorded compatibility checks and actual full-source PnR results: legal route,
intended SLR placement and registered crossings, 10 ns setup/hold closure,
resource accounting and congestion review. No such physical result is
established by this document.

## Post-synthesis TX-preservation check, 2026-09-05 18:25

The first physical audit found weight-response TX payload FFs absorbed into
BRAM output registers. A narrowly selected preservation parameter was added
to the weight response transport, defaulting off for generic streams and
other memory paths. This first verification covers preservation of the full
response payload vector; a subsequent refinement will restrict preservation
to the data bits so constant/unused tag fields are not unnecessarily retained.
This result must not be mistaken for sign-off of that upcoming refinement.

Fresh configured build `build/experiment-archive/build_slr_tx_verify` used the unchanged primary W4
config and the same measurement matrix/settings. `slr_stream`, `slr_mem_bus`
and `gemm_dma_slr_bridge` all pass deterministic VCS checks. All **12/12**
full-system runs pass numerical/protocol checks and slot-event/final-summary
balance checks; every individual host-cycle sample remains within 2% of the
frozen same-case baseline median.

| Case | Pre-attribute median | Full-payload preservation samples | Change from frozen baseline median | Internal compute span before / after attributes |
|---|---:|---|---:|---|
| Smoke QCOL | 5800 | 5875, 5874, 5800 | +1.293% | 28 / 28 |
| Overlap QCOL | 6552 | 6549, 6554, 6550 | +1.174% | 624–627 / 627–630 |
| QROW | 6174 | 6174, 6174, 6174 | -0.032% | 216 / 216 |
| Odd-tail QCOL | 5875 | 5872, 5872, 5873 | -0.017% | 29 / 29 |

The parameter changes synthesis preservation, not the pipeline equations or
number of stages. Observed host and inter-phase variation is nevertheless
reported rather than claiming exact whole-system cycle identity. In
particular, smoke host counts span 75 cycles while its internal compute span
is exactly unchanged, and the overlap internal span remains materially above
the frozen 563–568 cycles. No attribute-related VCS warning or compilation
error was found in the focused or integrated compile logs. Simulation does
not demonstrate whether synthesis retains or places the requested FFs.

- Evidence: `build/experiment-archive/build_slr_tx_verify/gemm-results-tx-preserve/summary.json`, its
  adjacent per-run logs, and `build/experiment-archive/build_slr_tx_verify/*-verification.json`.
- One accepted `simv` SHA256 for the entire matrix:
  `67e0397ec4a81a5ee602816d36b736413837655ac7f46b5856a013c85ff72d95`.
- Compiled RTL `_2878242_archive_1.so` SHA256:
  `c6d1238a882d2a0839e70827bb38d3a94336a35f36f05269c2b660fce823bbac`.
- This image and all earlier iteration images/results are preserved. The
  data-only preservation refinement requires its own fresh compilation and
  result record before physical implementation is retried from source.

## Final data-only TX-preservation verification, 2026-09-05 18:33

The final refinement elaborates individual TX payload FFs under
`g_payload[bit_idx].payload_tx_q` and applies `DONT_TOUCH` only at or above
`PRESERVE_TX_PAYLOAD_LSB`. The response wrapper derives that boundary from
`$bits(upstream_if.rsp_data.tag)`, so the weight response's data bits are
preserved without forcing unused tag bits to survive. Default preservation
remains off elsewhere. Handshake equations and pipeline stage counts are
unchanged; simulation does not establish whether synthesis/Laguna mapping
honors this preservation request.

Fresh configured `build/experiment-archive/build_slr_tx_data_verify` sourced the primary W4 config,
ran `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`,
and used the same vendor simulation library and measurement settings. The
whole-payload-preservation build remains untouched.

### Final functional and performance gate: PASS

- `slr_stream`, `slr_mem_bus` and `gemm_dma_slr_bridge`: **3/3 PASS** through
  deterministic `tools/verify_rtl.py` VCS runs with system GCC/G++.
- Full-system primary blackbox matrix: **12/12 PASS**, with all slot traces
  complete/balanced and every individual sample within 2% of the frozen
  same-case host-PERF median.
- No attribute-related VCS warning or compilation error was found in the
  focused or integrated compilation logs. Numerical/protocol success must not
  be substituted for the pending physical preservation checks.

| Case | Frozen median | Final data-only preservation samples | Median change | Compute span | Final store-accept span |
|---|---:|---|---:|---:|---:|
| Smoke QCOL | 5799 | 5801, 5875, 5875 | +1.311% | 28 | 0 |
| Overlap QCOL | 6474 | 6547, 6550, 6547 | +1.128% | 626–630 | 108 |
| QROW | 6176 | 6177, 6176, 6175 | 0.000% | 216 | 96 |
| Odd-tail QCOL | 5873 | 5873, 5873, 5874 | 0.000% | 29 | 34 |

Relative to the pre-attribute accepted image, the non-overlap internal spans
remain exactly 28/216/29 and the overlap range overlaps its previous
624–627-cycle range. Relative to the frozen unpipelined baseline, the latest
overlap median is **566 → 627 cycles (+10.78%)**; serialized store tail is
**84 → 108 cycles (+28.57%)**. These internal transport costs remain explicit
despite the passing +1.128% whole-application overlap result. The attribute
change itself does not introduce another RTL pipeline stage.

Final first-DMA-accept to last-logical-complete spans are 142–149 cycles for
smoke, 869–872 for overlap, 508–514 for QROW and 176–185 for odd-tail. Exact
slot measurements match the accepted bypass-path behavior: overlap has
512 allocations/responses/releases, 504 response-bypass releases, 255
same-cycle recycles, eight physical slots, peak occupancy eight and three
full-slot stalls. Its request-to-response latency is exactly eight cycles;
allocation-to-release is 8–12 cycles with mean 8.06055. All cases' full
metrics are retained in the JSON, including their long consumer-held slots.

### Final image and evidence

- `build/experiment-archive/build_slr_tx_data_verify/gemm-results-tx-data-preserve/summary.json` and
  adjacent per-run application, wrapper and compressed RTL logs.
- Focused reports: `build/experiment-archive/build_slr_tx_data_verify/*-verification.json`, with
  individual unittest compile/simulation logs under that configured build.
- One `simv` SHA256 across all twelve runs:
  `afa3465ffd89c9d3cc67dccef796b1373c900470b186275e632d29e21cdb6cce`.
- Compiled RTL `_2969206_archive_1.so` SHA256:
  `44a0edb68b65cade55f6ea23a931effc7eac81869f3bdb173912c31501664946`.
- Kernel SHA256 remains identical to the frozen baseline:
  `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.

The primary simulation gate is complete for the final source revision.
Synthesis and physical acceptance, including exact retained data-FF count,
SLR membership, registered crossing connectivity and timing/routing closure,
remain governed by the separate physical-results record.

## Final source including MXU input-data preservation, 2026-09-05 18:45

This final rerun covers both the preceding weight-response data-only
preservation and the MXU input TX/RX data FF preservation that prevents
absorption into DSP input registers. MXU input control and data are now
separately named placement groups; the packed payload remains an alias of
those registered fields. No extra transport stage is introduced by this
preservation change.

### Fresh builds and ACC compatibility

- Primary: `build/experiment-archive/build_slr_final_verify`, sourced TH16/MXU32/W4 config.
- MXU16 unit compatibility: `build/experiment-archive/build_slr_final_mxu16_verify`, sourced the
  MXU16/W4 config with `GEMM_SLR_PIPELINE` explicitly appended.
- Both builds were independently configured for XLEN64 with the standard
  configure command before verification. Prior images/results are preserved.
- Full `gemm_unit_v2` suites pass on **both geometries** using
  `tools/verify_rtl.py` and VCS. Both report the unchanged critical markers:
  `M3_D3_RAW_STALL_PASSED rows=3 qdir=row stalls=1 early=0 nominal=3 writes=6`
  and `M5_ACC_READ_WRITE_ARBITRATION_PASSED rows=5 qdir=row write_stalls=2 writes=10`.
- Primary unit image SHA256:
  `8b358a6b14f7850d6feb1c3c75686ba130e357588aff5b1ff088db946c54a225`.
  MXU16 unit image SHA256:
  `9b6ee9b33555237bd36c3a7989297823c59a2f2dc940686283ffe865de0fd3b7`.
- Final MXU16 compatibility is a module-level rerun, not a new MXU16
  end-to-end/PnR claim; see `compatibility-results.md` for precise scope.

### Final primary gate: PASS

The same four-case, three-sample `xrt-vcs-sim` matrix passes **12/12**
numerical/protocol checks, all exact slot-accounting checks, and the 2% host
criterion for **every individual sample** as well as each case median.

| Case | Frozen median | Final source samples | Median change | Internal compute span | Serialized final store-accept span |
|---|---:|---|---:|---:|---:|
| Smoke QCOL | 5799 | 5874, 5876, 5876 | +1.328% | 28 | 0 |
| Overlap QCOL | 6474 | 6546, 6548, 6547 | +1.128% | 630 | 108 |
| QROW | 6176 | 6176, 6174, 6177 | 0.000% | 216 | 96 |
| Odd-tail QCOL | 5873 | 5875, 5872, 5875 | +0.034% | 29 | 34 |

The final overlap compute span is **566 → 630 cycles (+11.31%)**, and its
serialized store tail is **84 → 108 cycles (+28.57%)**, relative to the frozen
baseline. These are real internal costs despite the passing +1.128% host
result. The final compute span of 630 cycles was already observed within the
preceding attribute-only rerun's 626–630 range; this is not evidence of a
new pipeline stage introduced by MXU data preservation.

First-DMA-accept to last-logical-complete spans are 147–151 (smoke), 872
(overlap), 508–519 (QROW) and 177–184 (odd-tail). Exact queue metrics remain
consistent with the accepted response-bypass design: the overlap case has
512 allocations, responses and releases; 504 bypass releases; 255 same-cycle
recycles; eight physical slots and peak occupancy eight; three full-slot
stalls; exactly eight-cycle request-to-response latency; and 8–12-cycle
allocation-to-release latency (mean 8.06055). All twelve runs report
`complete_and_balanced: true`.

### Final hardware-rerun source image

- Full-system evidence:
  `build/experiment-archive/build_slr_final_verify/gemm-results-final/summary.json` and adjacent
  per-run wrapper/application/compressed RTL logs.
- One `simv` image throughout the final matrix:
  `d4422bdf60fb4c38af50b47d9a8c040cb6e6e15b8e3c51688a2270c11ceed0d2`.
- Compiled RTL `_3094894_archive_1.so`:
  `4667827a5341904268f8f1cd291e89129505001b236efb5e5d6fb50f2286b439`.
- Kernel SHA256 remains identical to the frozen baseline:
  `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.
- Focused JSON reports: `gemm-unit-v2-verification.json` in each fresh build;
  complete unit logs are under `hw/unittest/gemm_unit_v2/logs/`.
- No attribute-related VCS warning or integrated compilation failure was
  found. Verification performed no RTL edits or synthesis.

The final-source primary simulation and requested MXU16 ACC compatibility
gates are ready for the normal source-based hardware rerun. Actual preserved
FFs, SLR placement/crossing coverage and setup/hold/routing closure must still
be established by the hardware implementation evidence, not by these tests.

## Reset-extraction attribute verification, 2026-09-05 20:04

This fresh iteration covers `EXTRACT_RESET="yes"` at ten already-resettable
`USER_SLL_REG` declarations in `VX_slr_stream`, `VX_gemm_dma_slr_bridge` and
`VX_gemm_compute_core`. It does not change sequential assignments, reset
semantics or pipeline depth. Whether synthesis now places reset on the FF
reset pin rather than a D-input LUT is a separate physical audit; RTL
simulation cannot establish that mapping.

### Focused and compatibility gates

Fresh configured builds are `build/experiment-archive/build_slr_reset_verify` (primary TH16/MXU32/W4)
and `build/experiment-archive/build_slr_reset_mxu16_verify` (TH16/MXU16/W4 with
`-DGEMM_SLR_PIPELINE` explicitly appended). Both sourced their corresponding
config before XLEN64 configuration. No previous image or results were replaced.
All tests used `tools/verify_rtl.py unittest --sim vcs --timeout 1800` and
system GCC/G++.

- Primary `slr_stream`, `slr_mem_bus`, and `gemm_dma_slr_bridge`: **PASS**.
- Full primary and MXU16 `gemm_unit_v2` suites: **PASS**. Both retain
  `M3_D3_RAW_STALL_PASSED rows=3 qdir=row stalls=1 early=0 nominal=3 writes=6`
  and `M5_ACC_READ_WRITE_ARBITRATION_PASSED rows=5 qdir=row write_stalls=2 writes=10`.
- Primary unit image SHA256:
  `780fc2d39d52f0cd8ef04126b23cb72d5b7f882f3ace8620e5ef890bdfe243e7`.
- MXU16 unit image SHA256:
  `676edb0b88c371d2fb4aeef7fce8d747ddde024841a5b982bc829639ccb6d3eb`.
- Evidence: `*-verification.json` in both builds and each unittest's
  `logs/compile.log` / `logs/sim.log`. No attribute-related VCS warning or
  compilation failure was found. Existing unrelated compile warnings remain.

### Primary twelve-sample gate: PASS

The same four cases, each repeated three times through `ci/run_black.sh
xrt-vcs-sim`, pass functional/numerical checking, deterministic fatal-marker
checks, exact slot accounting and the 2% host threshold for **every sample**.

| Case | Frozen median | Reset-extraction samples | Median change | Internal compute span | Final store-accept span |
|---|---:|---|---:|---|---|
| Smoke QCOL | 5799 | 5800, 5806, 5801 | +0.034% | 28 | 0 |
| Overlap QCOL | 6474 | 6549, 6549, 6550 | +1.158% | 630, 627, 633 | 108 |
| QROW | 6176 | 6176, 6175, 6174 | -0.016% | 216 | 96, 96, 98 |
| Odd-tail QCOL | 5873 | 5872, 5878, 5872 | -0.017% | 29 | 34 |

The overlap internal median remains **566 → 630 cycles (+11.31%)** and its
serialized store tail remains **84 → 108 (+28.57%)**. The passing host gate
must not be interpreted as unchanged internal latency. Host smoke variation
from the preceding image is also not evidence of an attribute-induced
pipeline improvement: its compute span remains exactly 28 cycles.
DMA first-accept to last-logical-complete spans are 141–143, 870–878,
508–513 and 176–177 cycles, respectively.

Overlap exact slot metrics remain 512 allocations/responses/releases, 504
bypass releases, 255 same-cycle recycles, eight physical slots/peak occupancy
eight and three full-slot stalls. Request-to-response is exactly eight cycles;
allocation-to-release is 8–12 cycles (mean 8.06055). All twelve runs report
`complete_and_balanced: true`.

### Frozen iteration-seven artifacts

- Full-system summary and per-run application/wrapper/compressed RTL logs:
  `build/experiment-archive/build_slr_reset_verify/gemm-results-reset/summary.json`.
- One `simv` SHA256 throughout the matrix:
  `6e41fda0990eb57f7aedfc8ee38e1169fe6a27d1aa8e057048271111c85a1694`.
- Compiled RTL `_3975316_archive_1.so` SHA256:
  `cbfb353fc0ce5363aeb0fd384645b79ee46bd5ec726fa4b09dffe1d3b6c068b0`.
- Kernel remains byte-identical to the frozen baseline:
  `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.

The requested simulation gates are ready for the next normal source-based
hardware run. This verification step made no RTL edits and ran no synthesis
or OOC; reset-pin extraction, exact Q-to-D crossings and timing/routing
acceptance remain the responsibility of the physical evidence.
