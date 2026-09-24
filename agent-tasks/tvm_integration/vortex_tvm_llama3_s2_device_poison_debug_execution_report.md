# Vortex TVM Llama3 S2 Device-Poison Debug Execution Report

## 1. Outcome

The current C4/fused S2 implementation passes the requested stability matrix without retries,
sleeps, device resets, weaker numerical thresholds, RTL changes, or xclbin changes:

- three full strict canonical chains in one persistent XRT process: **PASS**;
- three full strict canonical chains in fresh Python processes: **PASS**;
- one production-like S2 free-running prefill plus three decode steps: **PASS**;
- S1 free-running and S4 decode-3 canonical strict representatives: **PASS**;
- pooled and naive allocator stress: **PASS**.

The historical failure has a precise signature, but its causal owner was not reproduced. The
correct conclusion is therefore **current stability acceptance passed; historical transient root
cause remains unproven**. No production or RTL fix was made without a failing bounded reproducer.

## 2. Revisions and immutable identities

| Item | Value |
| --- | --- |
| Vortex revision | `88c971648c76afa72a55064335abe29e30268045` |
| TVM revision | `e2ca2b0bebe9a7fc0fa234d13451afafc0a11d20` |
| C4 profile fingerprint | `62540fb747aa762d5cfab874e36d1daac7119d8cff3e32d659a104b460383256` |
| xclbin SHA-256 | `f661b63a88db967072c1cfdf63373bfa7ad36e87d7002d6eba28d8fa036da6bf` |
| S2 package SHA-256 | `f97068b28a46ca5e34170af61bc9a5b636108cb53dad851e636efc708f7b612c` |
| S2 reference SHA-256 | `9b4903e0fbb0fda0e08a04cb9a6a918cab74cd54b08760c92d6ec91a390255f9` |
| XRT device | index 1, BDF `0000:3d:00.1` |
| Shape | `(batch=1, prompt=7, cache capacity=16)` |

The package embeds older build revisions (`Vortex 3c47d2df`, `TVM 14745fed`), but every artifact,
manifest, profile, and xclbin hash was checked before device use. The current source revisions were
recorded separately in every event trace.

## 3. Historical failure classification

Two retained logs contain the same first runtime signature:

```text
RuntimeError: Vortex kernel wait failed with error -1;
the device is poisoned and the process must be restarted
```

- `hardware_s2_run.log`: first timeout while entering prefill layer 10;
- `hardware_s2_canonical_inputs_run.log`: layers 0-19 returned finite, numerically acceptable
  hidden states, then the next prefill invocation timed out;
- `-1` is the 300,000 ms `vx_ready_wait` timeout; the TVM runtime marks the process device as
  poisoned after that timeout, so `poisoned` is a consequence of the failed wait rather than a
  separate numerical diagnosis;
- neither log shows an operation-local tensor mismatch before the timeout.

This is Section 3 case 1 from the plan. The old runs did not have a pre-failure health probe or an
action-level JSONL trace, so they cannot prove whether the transient was inside the invoked kernel,
the physical device command state, or XRT infrastructure.

Historical log hashes:

- `hardware_s2_run.log`: `2f5ae334779bdeeed0fe7627bc7d40ac9ee5a23ea35556f344c3a54c38cc1554`;
- `hardware_s2_canonical_inputs_run.log`:
  `faea2b8a3cc67c210122c321d22e6f8a660997854ce5351ab6c27b0a121f655b`.

## 4. Diagnostic implementation

TVM now contains `apps/vortex_llama3/debug_canonical_layer_range.py` with:

- ordered `prefill,decode_N` phase selection and inclusive `START:END` layer replay;
- complete reference-key validation before XRT opens;
- exact canonical hidden and seven prior-phase KV inputs per selected layer;
- `none`, `hidden`, and `full` D2H modes;
- pooled/naive allocator and shared/per-call VM controls;
- persistent repetitions in one device/process/archive lifetime;
- exact BDF discovery and optional BDF assertion;
- a validated embedding health probe at explicit run/phase boundaries;
- flushed JSONL events around launch and D2H boundaries, including addresses, byte sizes, hashes,
  finite/magnitude summaries, revisions, package/xclbin/reference hashes, Slurm IDs, VM identity,
  logical module, and cumulative/internal kernel counts;
- no retry or recovery path.

Host tests cover phase/range parsing, missing-reference rejection, persistent CLI parsing, and
per-event JSONL flushing. `test_vortex_llama3_inference_app.py` passes **11/11** under Python 3.12,
and the Python 3.10 hardware environment validates all 1,044 required S2 reference arrays.

## 5. Hardware results

### 5.1 Full S2 strict acceptance

Each chain executes 128 canonical layer invocations and validates hidden plus all seven KV/cache
outputs with the accepted hybrid FP16 and semantic KV4 policy.

| Run | Process policy | Layers | Internal kernels | Duration | Result |
| --- | --- | ---: | ---: | ---: | --- |
| fresh trial 1, job 4646 | fresh | 128 | 314,560 | 421.8 s | PASS |
| persistent repetition 0, job 4647 | retained | 128 | 314,560 | included below | PASS |
| persistent repetition 1, job 4647 | retained | 128 | 314,560 | included below | PASS |
| persistent repetition 2, job 4647 | retained | 128 | 314,560 | included below | PASS |
| fresh trial 2, job 4650 | fresh | 128 | 314,560 | 420.2 s | PASS |
| fresh trial 3, job 4650 | fresh | 128 | 314,560 | 423.7 s | PASS |

The persistent process completed 384 layers and 943,680 internal kernels in 1,264.8 seconds with
one device open and one parameter upload. Across the six accepted full chains there were zero
timeouts, first-failure events, unhealthy probes, retries, and non-finite outputs. Current measured
full-chain failure frequency is **0/6**.

### 5.2 Allocator and copy stress

The historical long strict runner used naive allocation, while the main acceptance used pooled
allocation. An explicit naive A/B repeated all 32 prefill layers three times with full eight-output
D2H comparison in one process:

- 96/96 layers passed;
- 243,264 internal kernels completed;
- all phase health probes passed;
- failure frequency was 0/3 prefill chains;
- pooled persistent execution used two hidden addresses; naive stress reused one hidden address;
- both policies remained stable, so allocator churn/address policy is not a demonstrated cause.

### 5.3 Free-running and shape regressions

- S2 free-running: token IDs `[89754, 29229, 89754]`, exact cache lengths `7,8,9,10`, zero
  recovered retries, and kernel counts `81,152/77,886/77,886/77,886`;
- S1 free-running: token IDs `[89754, 29229, 89754]`, exact cache lengths `1,2,3,4`, zero
  recovered retries;
- S4 batch-2 decode-3 canonical strict: 32/32 layers, 143,296 internal kernels, full hidden/KV
  comparisons and start/end health probes passed;
- retained baseline S1 full strict and S4 full free traces remain valid and were not weakened.

## 6. Hypotheses rejected by evidence

| Hypothesis | Evidence |
| --- | --- |
| fixed layer 10 or 20 defect | every full chain passes both layers; 32-layer repetitions pass |
| canonical tensor value defect | all phases use exact canonical hidden/KV inputs and pass |
| strict D2H volume alone | full eight-output copy passes 768 full-chain layer checks |
| cumulative process launch count | 943,680 internal kernels pass in one persistent process |
| fresh-process-only instability | three fresh and three persistent chains pass |
| pooled allocator hides the issue | naive full-copy prefill passes three repetitions |
| S2-only shape-local RTL mismatch | S1 free and S4 batch-2 canonical representative pass |

The data does not support an RTL/FSM, GEMM tail, compiler kernel, tensor-lifetime, or deterministic
allocator fix. RTL simulation was not started because no identical physical invocation failed
operation-locally.

## 7. Root-cause status and disposition

The only proven root-level fact is an intermittent physical kernel-completion timeout in the old
logs. Under pinned package/xclbin/BDF identity, unique per-run shared-status paths, managed Slurm
allocation, and action-level tracing, more than 1.8 million internal kernels in the six full strict
chains completed without reproducing it. The strongest classification is therefore a historical
transient XRT/U55C command-completion event, but the evidence is insufficient to name its causal
hardware or infrastructure mechanism.

Consequently:

- no production code change is claimed as a causal fix;
- pooled allocation is retained as a diagnostic control, not a required workaround;
- unique shared-status paths and BDF pinning are reproducibility/isolation requirements, not
  device recovery;
- if the event returns, the new trace will identify the exact last completed launch/D2H boundary,
  addresses, inputs, and same-process probe result needed for infrastructure escalation or an
  operation-local RTL replay.

## 8. Acceptance audit

| Criterion | Status |
| --- | --- |
| precise first-failure signature | PASS |
| bounded reproducer and durable event trace | PASS; trigger did not recur |
| proven causal owner/fix | **OPEN: not reproducible, no unsupported fix claimed** |
| three persistent full strict chains | PASS |
| three fresh-process full strict chains | PASS |
| S2 free-running and S1/S4 regressions | PASS |
| exact package/xclbin/profile/address/allocation evidence | PASS |
| no unjustified RTL/FSM change | PASS |

This report closes the stability prerequisite for normal C1/C2/C3 compiler work, while preserving
the causal-root-cause item as an infrastructure escalation condition if the timeout reappears.

## 9. Retained artifact index

Large logs and `.npz` files remain under the TVM build tree and are not committed. The concise
machine-readable index is
`agent-tasks/tvm_integration/vortex_tvm_llama3_s2_device_poison_debug_evidence.json`.
