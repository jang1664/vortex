# Shared row-major resident decoder

The C1, C2 and C3 application Makefiles compile this runner with a fixed candidate
selector. The host schedules the same decoder graph and reuses existing standalone
vector kernels, TCU GEMM and naive FP-INT GEMM. Only the explicit device reorder
helper and integration/dispatch code are new; standalone implementations stay intact.

| Candidate | Seven linear projections | QK and PV | Physical intermediates |
|---|---|---|---|
| C1 | FP16 TCU | FP16 TCU | Row-major |
| C2 | Naive FP-INT MXU | FP16 TCU | Row-major |
| C3 | Naive FP-INT MXU | Naive FP-INT MXU | Row-major |

All candidates perform signed asymmetric W4/KV4 quantization. C1 linear weights
are dequantized once during fixture preparation and uploaded as FP16 outside
`decoder.run()`. C1/C2 dequantize KV cache inside the device graph. C3 consumes
packed KV directly. Do not compare C1 timing to a sum that includes per-invocation
weight dequantization without accounting for this policy.

`reference.py` reuses the existing SpinQuant backend-aware PyTorch decoder and
C4 validation helpers. It preserves model dimensions, deterministic weights,
FP16 quantization arithmetic, SiLU rounding and RMS reduction policy, while
selecting FP16 or W4 arithmetic for each candidate. Fixtures carry a candidate
identifier; the runner rejects a fixture for another compiled candidate.

Example fixture generation (source the existing TVM Python environment first):

```sh
"$py" /absolute/repo/tests/regression/llama_decoder_common/reference.py generate \
  --candidate C3 --model llama3-8b --batch 1 --seq-len 32 \
  --fixture /absolute/repo/build_llama_decoder_c3/fixtures/llama3_b1_s32
```

From the configured build directory:

```sh
./ci/run_black.sh hw \
  --fpga-bin naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_axi_fix \
  --app llama_decoder_C3 \
  --args "--model llama3-8b --batch 1 --seq-len 32 --mode verify --fixture /absolute/fixture --output /absolute/result"
```

The existing C++ final-output check is the default correctness gate. Optional
intermediate and same-input diagnostics can be run separately:

```sh
"$py" /absolute/repo/tests/regression/llama_decoder_common/reference.py compare \
  --fixture /absolute/fixture --output /absolute/result
```

The optional comparison checks packed KV bytes exactly and local operations with
atol/rtol 0.002, but its result does not override a passing final-output gate.
Final output uses the previously agreed 0.005, preserving all fraction/L2/cosine/
finite guards. This policy follows the user's final-output-only instruction;
older reports retain their original, stricter local-check status.

`run_validation.sh` applies this policy to any candidate. Its `--timing` option
invokes timing mode directly: that mode already checks a preflight output and
the final timed output, so no duplicate verify graph is launched. For example:

```sh
bash /absolute/repo/tests/regression/llama_decoder_common/run_validation.sh \
  --candidate C2 --build /absolute/configured_build \
  --fixture /absolute/fixture --output /absolute/result \
  --timing --repetitions 3 --profile-repetitions 0
```

Add `--check-intermediates --python "$py"` to retain diagnostic comparison logs.
A diagnostic failure is reported separately and does not change the wrapper's
exit status when the C++ final-output check passes. Runtime or final-output
failures still return nonzero. No numeric tolerance is relaxed.

Decode fixtures require a matching candidate's CPU prefill fixture, e.g.
`--decoder-stage decode --seq-len 1 --past-kv-len 1024 --cache-capacity 1056
--past-fixture /absolute/prefill1024`.
The runtime uses `--stage decode` with the same dimensions. All heads execute,
new KV entries append at the fixed position, and repeating the graph does not
grow context length. Capacity 1056 covers the required 32-aligned prefix. The
naive ABI computes physical capacity rather than a separate effective extent;
this implementation therefore validates fixed first-step replay only.

Decode groups the query heads sharing one KV head into consecutive GEMM rows.
For Llama3 this is logical M=4 with eight QK and eight PV calls; TCU rounds the
group to its M=16 tile once. The row-major buffers retain logical head order,
so softmax and concat need no additional transform. Llama2 has group size one.
Prefill retains per-head GEMMs and its existing causal softmax row indexing.
The CPU reference and final-output tolerances remain independent of the
latency estimator; matching historical timings does not establish correctness.

Performance modes `timing` and `isolated` are inherited from the C4 harness.
They exclude setup transfers and final validation. `--profile-repetitions N`
controls extra counter passes in timing mode and defaults to `--repetitions`.
The mandatory preflight already writes `warmup_profile.csv`, so setting zero
avoids additional graph executions while retaining an operation-cycle breakdown.
It does not change the requested wall-time repetitions or final output check.
A failed final-output gate
must not be reported as validated latency. See each candidate's results for
actual verified coverage and known failures.

## Two independent decode references

`dual_reference.py` compares a saved final output against both the existing
IEEE reference and a reference accepting the characterized Xilinx native-half
latency1 multiplier's input/output subnormal flush. Both replay the entire
decode step from the fixture inputs, weights and initial KV cache. Device
intermediates are not supplied to either reference. The IEEE replay must match
the saved fixture reference bit-for-bit before the comparison can proceed.

```sh
"$py" /absolute/repo/tests/regression/llama_decoder_common/dual_reference.py \
  --fixture /absolute/decode_fixture --output /absolute/decoder_dump --gate ip
```

Use the existing TVM Python environment. No FPGA is needed. Candidate selection
comes from fixture metadata (C4 fixtures omit the candidate field). This command
supports C1–C4 decode fixtures and always records both outcomes in
`dual_reference.json`, plus predictions in `dual_reference_outputs.npz`.
`--gate ieee` is the default exit-status policy; `--gate ip` explicitly selects
IP-compatible acceptance. The C++ runner's existing IEEE check and its exit
status remain unchanged; this is a separate post-run comparison.

Only C3/C4 QROW PV scaling changes in the IP reference. It uses the known IP
multiplier behavior followed by correct accumulation/output conversion. C1/C2
retain IEEE semantics: their custom TCU input converter's subnormal-times-four
defect is not an IP limitation. The custom MXU output converter's missing-hidden-
bit defect is also excluded. Both modes use the same final-output thresholds.
An IP-reference PASS establishes compatibility within those thresholds, not
bit-exact arithmetic or the absence of smaller custom-RTL defects.

CPU policy tests: `"$py" tests/regression/llama_decoder_common/test_dual_reference.py`
from the repository root with the same Python environment.

## TCU rounded rows and comparison scope

The unchanged TCU kernel executes M rounded to its hardware tile. Allocations
reserve and zero `tileM - 1` extra rows without changing any logical row stride.
Head launches are sequential: rounded output rows may overlap a following
head's not-yet-produced region, which its own launch replaces before any
consumer runs. The final head remains within the reserved allocation tail.

The current `latency_on_hw/prepare.py` excludes all dequantization from plotted
latency. This connected graph includes dynamic KV dequantization for C1/C2 and
explicit device reorder launches. For that comparison, subtract the sum of KV
dequantization `host_seconds` in `warmup_profile.csv` from the measured wall time
in postprocessing, and retain the original full wall time. The operation host
times include launch/wait; also report their cycle sum divided by the FPGA clock.
The kernels still execute in the connected graph; they are not skipped or moved
outside its timer. Reorder costs and implementation differences must also be
identified when comparing to the historical aggregate.

## Variants matched to latency_on_hw rev5

The wrappers select the recorded variants in
`outputs_llama3_main.th16_20261007_rev5_pipeline/C1/kernel_variants.json`
(run `20261004T060802877116Z`), rather than including baseline implementations.

| App | Variant |
|---|---|
| eladd | row_coalesced_cursor, row size 4096 |
| head_concat | chunk16_packed |
| silu | linear |
| KV quant / dequant | groupwise_fp16 |
| RMSNorm | adaptive_m_rows |
| RoPE | task_chunk16 |
| Hadamard | r3_shuffle |
| Softmax | rev2_shuffle_grouped |
| TCU GEMM | b_colmajor |
| elmul / naive GEMM | existing default |

KV launch geometry uses the standalone host helpers, including thread-per-group
prefill quantization and warp-per-group decode quantization. RoPE, concat and
SiLU also use their standalone work-item counts and grid limits. Thread/warp
counts come from the device configuration. The decoder keeps its model's
attention scale and asymmetric KV arithmetic; changing a kernel variant does
not change those model semantics. Decoder-only head reorder launches remain
part of the connected execution and are not subtracted with dequantization.
