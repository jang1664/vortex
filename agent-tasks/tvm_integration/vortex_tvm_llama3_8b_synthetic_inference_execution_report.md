# Llama3-8B Synthetic Inference Execution Report

## Outcome

The partitioned synthetic Llama3-8B implementation now completes S1/alone prefill followed by
three decode steps on the pinned U55C, including the physical embedding and LM head, without layer
retries. Two complete chains pass in one persistent process with one device open, one xclbin
programming event, one archive upload, and device-resident KV state. Both runs generate
`[89754, 29229, 89754]`, preserve exact cache lengths 1/2/3/4, and produce identical per-step
hashes.

The earlier `inf`/large-hidden symptom was not gradual model divergence. Checkpointed execution
located the first bad value in the MLP R4 Hadamard transform. The former graph emitted a chain of
pairwise butterfly kernels whose last stage could intermittently jump from a normal maximum of
44.89 to 4407.50. Keeping every intermediate alive removed one aliasing trigger but did not make
the final butterfly kernel repeatable. Replacing that chain with an equivalent dense mixed-radix
Hadamard removes the transient boundary. The new transform passed a 100-call alternating stress
test and 512 full decoder-layer calls across the final persistent host-snapshot and device-copy
runs with zero non-finite values and zero retries. No RTL or xclbin change was required.

Separately, W4/K4/V4 cache requantization causes the live decode chain to drift from the canonical
PyTorch chain after multiple decode steps. Layer-local eager replay proves that the hardware still
matches the operation for its actual quantized input, so decode-3 canonical drift remains distinct
from the resolved transient corruption.

## Implemented deliverables

- Real Llama3-8B geometry: 32 layers, hidden 4096, intermediate 14336, Q32/KV8, head dimension 128,
  vocabulary 128256.
- Signed asymmetric W4/K4/V4 synthetic parameters with deterministic depth-scaled residual
  projections.
- Separate embedding prefill/decode, decoder prefill/decode, and final-head prefill/decode VM
  artifacts.
- One compiled physical decoder layer reused over 32 global archive slices.
- A 5,741,617,152-byte profile-bound archive with tensor and whole-archive integrity checks.
- Selective, cached device upload and global-to-local layer parameter mapping.
- Package and run modes that separate compilation from fresh-process inference reload.
- Prefill/decode KV-state flow, device-to-device handoff, deterministic argmax, and JSON traces.
- Hybrid FP16 validation: absolute error for small references, relative error for large references,
  plus relative-L2, cosine, and violation-fraction gates.
- Per-layer semantic K/V checks and first-failure diagnostics, including scalar cache-length and
  singleton layer-axis handling.

## Successful but non-repeatable full-run evidence

One card-0 S1/alone prefill completed all 32 layers and the final head:

- trace: `tvm/build/llama3_synthetic_s1_alone_layer1_reset/s1-prefill-clean-idle-a-trace.json`;
- 32 validated layer states and all cache lengths equal to 1;
- final normalized relative-L2: 0.0011141;
- logits relative-L2: 0.00030909;
- logits cosine: 0.99999958;
- top-1 agreement: 1.0;
- prefill latency: 94.79 seconds.

That run used an experimental clean-IDLE launch handshake. Repeating the same experiment failed,
so it is diagnostic evidence rather than an acceptance result. The experimental runtime changes
were removed from source.

The cleaned production runtime later completed two fresh-process pooled S1/alone prefills. Both
produced token 89754 and identical logits hash
`f651c150dd88694cbc6fe00bca2c7e4e6a3b19efe386197a4738cb234b940415`; logits relative-L2 was
0.0002740 and normalized relative-L2 was 0.0008875. A following prefill plus three-step decode
remained finite, but its decode hidden state became a large plateau at a variable layer and did
not match the eager reference.

## Address and state-transfer reduction

The runtime now exposes the physical Vortex address of a Tensor for diagnostics, and the reduced
runner records hidden, position, parameter, cache, raw-output, and persisted-output addresses.
The following physical U55C results replace the earlier assumption that a repeated identical layer
fails by itself:

1. Prefill layer 28 with one fixed input address passed 20/20; 32 distinct swept addresses also
   passed 32/32.
2. Exact decode layer 11 and layer 24 with the full 5.7 GB archive passed 20/20 each. Inputs and
   outputs were above 4 GB, rejecting a simple 32-bit address truncation theory.
3. Two complete fixed contexts for decode layers 11 and 24 alternated in one VM for 40/40 calls.
   Changing the hidden/parameter/KV address set by itself is therefore insufficient to trigger the
   failure.
4. Adding the full runner's eight device-to-device state copies reproduced corruption: both the
   raw VM hidden and its copy failed together at iteration 12 or 16. A bad current copy is not the
   explanation; earlier state transfers poison a later launch.
5. Copying hidden alone passed 25/25. Copying key-cache outputs reproduced at iteration 11, and
   copying only the 128-byte FP16 key-scale output reproduced at iteration 14. Key payload and key
   zero each passed 45/45, value state passed 30/30, and length passed 30/30.
6. Avoiding key-scale copy passed the short alternating test 25/25, but the full chain still failed
   later. With all copies removed, a naive-allocator prefill failed at layer 24, proving transfer is
   an accelerator but not the only trigger.
7. Reusing one fixed hidden input buffer allowed one full 32-layer prefill, including semantic KV
   checks, to pass. A fresh run with the same fixed-buffer policy failed at layer 3, so address
   fixation is not a repeatable fix and a particular address is not the root cause.

Earlier AP-reset/settle and launch-handshake experiments also remained non-repeatable and were
removed. No production reset workaround is retained.

## Persistent-process result

The runner now supports repeating complete inference while retaining one Python process, one
`vx_dev_open`/xclbin programming event, and one resident parameter archive. Per-repetition traces
and failures are written without stopping the process after the first numerical mismatch.

- Three consecutive S1/alone prefills passed 3/3 with pooled allocation and copy-all state
  persistence. The driver contained exactly one `XRT device` initialization line, and layer-0
  parameter addresses were identical across repetitions.
- Prefill latency was 95.10, 93.68, and 92.33 seconds. Logits relative-L2 stayed between 0.000274
  and 0.000292; normalized relative-L2 stayed between 0.000882 and 0.000997.
- The logits hashes differed slightly across repetitions despite all tolerance checks passing, so
  the hardware result is numerically stable but not bitwise deterministic.
- Two persistent prefill-plus-three-decode attempts both passed prefill and failed in decode 1.
  Repetition 0 failed hidden validation at layer 2 (`relative_l2=729.49`, max 18560 versus 14.79).
  Repetition 1 passed hidden validation through layer 31, then failed layer-1 key-cache semantic
  validation (`key_dequantized relative_l2=0.08173`).

Therefore process exit and repeated xclbin programming were important prefill confounders, but
they are not the decode root cause. The remaining phase-specific difference is the sequence of
Vortex program binaries and state transitions from prefill/head/embedding into decode, while the
FPGA xclbin and resident weights remain fixed.

## Divergence diagnosis and recovered end-to-end result

Further reduction separated the apparent divergence into two independent effects:

1. A fixed full-resident layer-24 context passed 100/100 calls. Alternating canonical prefill
   layers 24 and 25 exposed five transient layer-24 corruptions in 100 calls. Immediate identical
   retries recovered six failures on retry 1 and one on retry 2 in a separate 100-call run, with
   zero unrecovered failures. The corrupted tensor did not match any other canonical layer output,
   ruling out a stale packet that merely selected another layer.
2. A captured decode-3/layer-1 mismatch was replayed in PyTorch eager with the exact live hidden
   and KV inputs. Hardware versus eager had hidden relative-L2 `0.0005878`, cosine
   `0.999999827`, and maximum absolute error `0.03125`; K outputs were exact and V payload differed
   at only 0.0244% of codes by at most one. Canonical-chain versus eager relative-L2 was `0.25999`.
   The large canonical difference is accumulated quantized-input drift, not a bad local GEMM.

The runner now enforces canonical numerical comparisons through prefill, decode 1, and decode 2.
Starting at decode 3 it records canonical drift but enforces finite output and a 4096 hidden-value
sanity bound. Cache lengths remain exact in every phase. This policy follows the measured boundary;
it does not silently weaken early-phase validation.

Final physical evidence:

- Host embedding/reference-head control: prefill plus decode 1-3 passed; cache lengths were
  1/2/3/4 and three transient layer failures all recovered on retry 1.
- Physical embedding and physical LM head: the same chain passed and generated
  `[89754, 29229, 89754]`; eight transient failures all recovered on retry 1.
- Persistent execution: two complete physical chains passed in one Python process, one device-open
  and xclbin-programming event, and one archive upload. Both generated
  `[89754, 29229, 89754]`. Repetition 0 recovered four events (one required retry 2), repetition 1
  recovered seven events on retry 1, and neither repetition leaked a bad hidden state forward.

Primary traces:

- `tvm/build/llama3-s1-alone-host-snapshot-retry3-decode3-f.json`
- `tvm/build/llama3-s1-alone-actual-embed-head-retry3-decode3-a.json`
- `tvm/build/llama3-s1-alone-actual-persistent-repeat2-retry3-decode3-a.json`
- `tvm/build/llama3-s1-alone-decode3-layer1-local-eager-analysis.json`

## Final no-retry root fix and acceptance

Checkpoint modules exposed Q/K/V projection, attention, residual, activation, Hadamard, and down
projection boundaries without changing the production operation order. Across eight captured
failures, Q/K/V, attention, residual, and activated MLP values were valid; the first functional
divergence was always the transformed MLP. A staged capture then isolated a representative jump
to the final pairwise butterfly stage: stage 7 had maximum magnitude 44.89 and stage 8 returned
4407.50. K and V cache outputs remained bit-exact in the same failed call. This identifies the
`inf` value as a downstream amplification of a finite Hadamard corruption, not FP16 overflow at
the original boundary.

The production graph now expresses the power-of-two factor as one dense Sylvester transform and
the mixed-radix base as the existing left transform. For the Llama3 intermediate width 14336 this
is a 28-by-512 reshape, a 512-point dense transform, and the existing 28-point base transform.
Host comparison against the former butterfly graph has relative-L2 at most `1e-5`, cosine at
least `0.99999`, and at most one FP16 ULP absolute difference for small values in the focused
tests. The packaged decoder keeps the normal eight-output state ABI; it does not depend on debug
lifetime guards.

Final physical evidence on the pinned U55C:

- alternating canonical prefill layers 24/25: 100/100 calls passed, retry 0, mismatch 0,
  non-finite 0; maximum relative-L2 was `8.09e-5`;
- one complete physical chain: all 128 decoder calls passed, generated
  `[89754, 29229, 89754]`, exact cache lengths 1/2/3/4, retry 0;
- persistent host-snapshot control: two complete chains and 256 decoder calls passed in one
  process, retry 0, with identical generated tokens and step hashes;
- persistent production state transport: two complete chains and 256 decoder calls passed with
  1028 device-to-device state copies per repetition and zero cache-state host snapshots;
- both device-copy repetitions had zero non-finite values, maximum hidden magnitude 542.5, and a
  maximum enforced canonical relative-L2 of `0.04642`, below the `0.05` gate;
- device-copy phase latencies were 78.19-84.85 seconds in repetition 0 and 81.48-84.44 seconds in
  repetition 1.

Primary no-retry traces:

- `tvm/build/llama3-layer24-25-dense-hadamard-no-retry100-a.jsonl`
- `tvm/build/llama3-s1-alone-dense-hadamard-no-retry-decode3-a.json`
- `tvm/build/llama3-s1-alone-dense-hadamard-persistent2-no-retry-a.json`
- `tvm/build/llama3-s1-alone-dense-hadamard-device-copy-persistent2-no-retry-a.json`

## Milestone disposition

| Milestone | Status | Evidence |
| --- | --- | --- |
| A — partitioned components | Pass for S1/alone | All six real-shape artifacts package with the normal ABI; archive and host tests cover mappings and metadata. |
| B — S1/alone live inference | Pass | Physical embedding/head prefill plus three decode steps passed twice in one persistent process with device-resident cache state and retries disabled. |
| C — fused and S1-S4 | Not started after gate | Deliberately held behind stable S1/alone. |
| D — reusable driver | Implemented | Direct CLI supports package/run, token IDs, cache capacity, argmax, references, and traces. |
| E — serialization/reload | Pass for the synthetic package | Fresh package reload was used for the final hardware acceptance runs without rebuilding. |
| F — real checkpoint | Deferred | Remains after synthetic hardware acceptance. |

## Final software verification

- Python byte-compilation for the runner, archive implementation, PyTorch boundaries, and focused
  tests: pass.
- Real-shape prefill and decode strict export plus all six package builds: pass.
- Dense mixed-radix equivalence at widths 128 and 14336: pass under hybrid FP16 absolute/relative
  criteria.
- Prefill reference, checkpoint ABI, three-step cache reuse, two-layer stack export, and
  partitioned embedding/head boundary checks: pass through direct focused invocation.
- All eight runner parsing, persistence, layer mapping, depth scaling, top-k, and scalar
  cache-state tests: pass through direct focused invocation.
- Tiny archive creation, metadata validation, selective upload, resident reuse, and layer mapping
  smoke: pass.
- Repository `git diff --check` in both Vortex and TVM worktrees: pass.
- The Torch-capable Python environment does not contain pytest, so the newly added pytest cases
  were invoked directly rather than through pytest discovery.

## Required follow-up

S1/alone synthetic inference is no longer gated by transient corruption. Keep the checkpoint,
mismatch-capture, and retry controls as diagnostic observability, but the accepted path uses zero
retries and the normal decoder-state ABI. Do not classify later canonical W4/K4/V4 chain drift as
an accelerator failure.

The remaining planned work is outside this S1/alone gate: package and validate fused, expand the
S2-S4 shape matrix, and finally convert/load a real checkpoint. A later optimization may replace
the dense 512-point transform with a single O(N log N) kernel if needed, but the accepted dense
form measured 78-85 seconds per complete 32-layer phase and was not slower than the prior retained
butterfly diagnostic package. No RTL or xclbin change was made for this fix.
