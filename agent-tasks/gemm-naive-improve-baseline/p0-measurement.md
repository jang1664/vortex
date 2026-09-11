# P0 measurement evidence and endpoint audit

Status: in progress. This document does not freeze a performance baseline or close P0.

## Observation contract

`VX_gemm_latency_observer` records pre-NBA controller inputs at each rising edge. Its edge counter advances during reset, starts at the first rising edge, and is never reset. Epoch/job/entry identity separates observations. The monitor is excluded by `SYNTHESIS` and synthesis translate-off directives. Controller additions are only guarded observer instances; excluding them and their blank separators reproduces the HEAD controller text exactly (see `p0-baseline/observer-isolation.json`). No original counters or handshake logic are changed.

The independent `extract_latency.py` uses `fsdb_cli` to read actual controller inputs, not monitor timestamp registers. It samples transitions strictly before each rising edge, excluding same-edge NBA changes. It checks the start control bit, tracks the final controller store-retirement pulse, and computes all five plan latency fields. Full CSV event evidence and JSON endpoints are retained per extraction. When `--log` is supplied, endpoint indices, identity, store count and latency fields must agree exactly with observer logs.

## Verified tests

Three VCS suites passed both before and after correcting standalone module library integration: observer arithmetic/ownership, real improve controller completion logic, real naive controller completion logic. Controller tests cover D=0/1/17, delayed final-store stimulus (0/7 cycles), two store completions per invocation, and six jobs without reset. Quiescence is modeled; actual compute and memory are not exercised by these tests. See `p0-verification/iteration2/` for deterministic verify_rtl.py reports and source hashes.

A focused Python trace test independently checked strict-before-edge semantics, a store update on an accepting edge, last-of-two-store selection, epoch indexing, and exact latency subtraction.

## Historical waveform diagnostic

The old M4 captures independently yield:

| Backend | cfg edge | final store edge | first done-valid/handshake edge | normalized GEMM | store | finalize | delivery | stores |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| naive | 8332 | 69877 | 69884 | 61552 | 61545 | 7 | 0 | 4 |
| improve | 8198 | 14644 | 14647 | 6449 | 6446 | 3 | 0 | 32 |

Improve's historical legacy counter was 6448, confirming that it cannot directly substitute for cfg-to-first-valid latency. These captures use historical vectors and cannot serve as corrected-vector acceptance baselines. Extraction evidence is in `p0-baseline/legacy-*-endpoints/`.

## Corrected M4 captures

Both new shared-vector M4/K512/N512 captures passed numerical verification at 0.1%. Neither run changed source hashes during execution. Every endpoint/identity/latency field matches the independent FSDB extraction with zero disagreement.

| Backend | Normalized GEMM | Core cycles | Finalize | Delivery | Evidence |
|---|---:|---:|---:|---:|---|
| improve | 6,449 | 12,206 | 3 | 0 | `p0-baseline/improve-m4-retry1/` |
| naive | 61,552 | 68,154 | 7 | 0 | `p0-baseline/naive-m4-retry1/` |

Core cycles use the existing `PERF: instrs=..., cycles=...` runtime report boundary. These measurements establish the corrected M4 observation result only; P0 remains open for M256, repeated payload jobs, physical install fault coverage, storage elaboration and visibility proofs, and final baseline freeze.

## Corrected M256 capture status

Improve passed numerical verification with stable source hashes. Its normalized GEMM latency is 272,870 cycles (store 272,867, finalize 3, delivery 0), and core latency is 278,684 cycles. Every endpoint matches the independent FSDB extraction in `p0-baseline/improve-m256/endpoints/latency.json`.

The first naive M256 run reached its 1,800-second process timeout and exited with code 124 without a completed numerical result. It is not a baseline. Its partial waveform, logs, and stable source manifest remain in `p0-baseline/naive-m256/`.

The identical-source retry passed numerical verification with no source changes during execution. Independent FSDB extraction matches every endpoint: cfg 21,171; final store 1,393,893; first done-valid/handshake 1,393,900. Normalized GEMM latency is **1,372,729 cycles**, store 1,372,722, finalize 7, delivery 0, and core latency 1,379,304. The capture has eight store completions. Evidence is `p0-baseline/naive-m256-retry1/`, including `endpoints/latency.json` and `final-checks.log`.

`p0-numeric-gates.json` now derives all required cycle/service/resource targets from these four corrected captures. Naive maximum GEMM cycles are 46,164 for M4 and 1,386,456 for M256; core maxima are 68,835 and 1,393,097. Improve must remain exactly 6,449/272,870 GEMM and 12,206/278,684 core cycles. This numeric derivation does not by itself close the physical ownership/storage prerequisites or accept a candidate.

## Store visibility contract and remaining candidate proof

The observed signal is `output_store_done_i`. Current naive `VX_gemm_dma_ctrl_naive` defines it from completed MMIO polling for an OP_DMA_ST descriptor. Its source comment explicitly excludes final HBM visibility: descriptor retirement on the cache path can precede write-through drain. The source and actual M4 waveform audit in `p0-visibility.md` establishes that this event follows OBUF source-response retirement and destination request acceptance, releasing OBUF source ownership. Improve's source-store retirement is separately observable. Neither endpoint is relabeled HBM completion.

Logs therefore carry `store_endpoint=output_store_done_i visibility=controller_retirement_only`. Primary cfg-to-done-valid latency remains exactly the plan definition. Final core/AFU cache drain is a separate boundary; the captured AFU completion satisfies it. The same audit shows that current node pending-write zero precedes actual LMEM bank writes: 32,256 writes were matched, with bank commit three cycles after node acceptance. Existing serialized operation showed no overtaking, which does not prove arbitrary-stall safety. The planned naive-only terminal fence must account for physical bank commits rather than assume this fixed delay. No current observation proves the redesigned fence or SRC_FREE generation join.

## Reproduction

Use `run_baseline.py BACKEND --m M --output NEW_DIRECTORY --rebuild` to source the preserved backend config and run the authorized xrt-vcs-sim wrapper from its configured build. Each run captures command/config/source hashes, simulator logs, memory-model manifest and FSDB. It rejects source changes during the run and never marks itself a frozen baseline.

Then run `extract_latency.py BACKEND NEW_DIRECTORY/wave.fsdb --log NEW_DIRECTORY/simv.log --output NEW_DIRECTORY/endpoints`. Do not reuse an extraction directory from another waveform.

## Improve resource baseline

The unchanged improve design completed OOC synthesis for U55C with Vivado2025.1 and the existing7ns constraint. The wrapper top uses168816LUT,90387FF,265RAMB36,16RAMB18,32URAM and826DSP; the node itself excludes806 wrapper FF. Reports and checkpoint provenance are in `p0-baseline/improve-cost/summary.json`.

The existing design fails the7ns timing gate: WNS=-0.690ns, official report TNS=-31.566ns,65 failing endpoints. The custom setup-gate script sums rounded path slacks and gives TNS=-31.543ns; both source reports are preserved. This is a baseline timing failure, not a successful timing-closure claim. The user requires improve to remain unchanged, so the RTL and constraints are retained. Candidate resource/latency/structural comparisons have not run.
