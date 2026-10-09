# C3 decoder validation (2026-10-09)

Hardware alias: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_axi_fix`.
Build: `build_llama_decoder_c3_parallel_20261009`.
All heads executed on one FPGA with resident intermediate tensors. No standalone
kernel implementation or RTL was changed for these tests.

| Workload | Model | Overall | Final relative L2 | Final max absolute error | Final violating elements |
|---|---|---|---:|---:|---:|
| Prefill B1/S32 | llama3 | PASS | 0.0443% | 0.00390625 | 1/131072 |
| Prefill B1/S32 | llama2 | PASS | 0.1047% | 0.01269531 | 1463/131072 |
| Decode B1/past1024/query1 | llama3 | FAIL | 0.3560% | 0.00878906 | 635/4096 |
| Decode B1/past1024/query1 | llama2 | FAIL | 0.2785% | 0.00634766 | 381/4096 |

## Meaning of PASS

The final output passes the agreed atol/rtol=0.005 gate, including the unchanged
2% violation-fraction, 1% relative-L2, 0.999 cosine and finite-value guards.
All 22 same-input local checks pass atol/rtol=0.002 plus the original guards.
Packed KV bytes, scale and zero-point arrays are exact. Some propagated chain
boundaries fail the tighter 0.002 criterion; their failures remain in the JSON
and are accepted only when the corresponding same-input local operation passes.
Final output failures are never overridden by local checks.

Prefill has propagated discrepancies at QK (the generic mathematical reference
rounds dequantized weights to FP16, while the naive QCOL pipeline does not), and
at later sensitive quantization boundaries. Llama2 has more propagated failures
than Llama3, but every same-input operation and the independent final output pass.

## Decode failure diagnosis

The first-step test uses logical KV length 1025 and physical capacity 1056, the
smallest 32-aligned prefix. The existing naive ABI has no separate effective K/N
and physical stride, so QK/PV execute 1056 lanes and softmax masks the last 31.
The past cache comes from the matching candidate's CPU prefill 1024 reference.
It is preloaded outside the measured graph. This is fixed-length replay, not
multiple-token dynamic cache growth.

For both models, only the same-input `context` (PV) check fails. QK, softmax,
all vector operations and all linear projections pass local checks. New KV
append matches exactly, including preserved prefix and zero unused tail.

| Diagnostic | Llama3 | Llama2 |
|---|---:|---:|
| PV relative L2 vs IEEE QROW arithmetic | 1.5057% | 1.6141% |
| PV element violation fraction | 29.9072% | 26.9531% |
| Activation-scale products flushed to zero | 10242 | 10025 |
| Mismatches vs previously documented RTL defect model | 0/4096 | 0/4096 |

The existing QROW FP16 multiplier flushes subnormal products, and the current
FP32-to-FP16 output converter mishandles subnormal output. Replaying the existing
`vortex_llama3/debug_pv_numerics.py` defect models reproduces every context
output exactly. This explains the failure; it does **not** turn it into PASS.
No RTL or tolerance changes were made, and no performance result is presented
as validated decode functionality.

## Artifacts

- Prefill: `build_llama_decoder_c3_parallel_20261009/results/prefill_s32/{llama3,llama2}`.
- Decode: `build_llama_decoder_c3_parallel_20261009/results/decode_p1024_c1056/{llama3,llama2}`.
- Each directory contains `run.log`, `verification.json`, `compare.log`,
  `intermediate_comparison.json`, `profile.csv` and logical/cache dumps.
- Decode directories additionally contain `pv_diagnostic.json`; its reproduction
  script is in the decode result root. The defect model is diagnostic only.
- `session.txt` records allocation and BDF. Both allocations have been released.

## Llama3 prefill B1/S1024 latency experiment

This is the later same-candidate comparison requested against `latency_on_hw`
rev5. The measured image is the C3 alias above; no device kernel or RTL changed
between repetitions. Slurm job 5782 used BDF `0000:3d:00.1` and was released at
completion. The root comparison report reconciles the historical image and
kernel-variant differences separately.

| Wall repetition | Connected `decoder.run()` seconds |
|---|---:|
| 0 | 33.256803700 |
| 1 | 33.235481980 |
| 2 | 33.228245962 |

Wall median: **33.235481980s**. All 103 operations and all 32 query
heads execute. Setup, uploads, intermediate downloads/checks, final validation
and counter reads are outside the wall interval. Resident launches, normal
runtime completion polling and host launch overhead remain inside it.

Separate instrumented passes recorded cycle sums 3,328,813,396;
3,328,895,660; and 3,325,628,393. Their median is **33.288133960s at 100 MHz**.
The wall median is 0.1582% below that separate-profile median; these are separate
passes, so this difference is not an isolated launch-overhead measurement.

Final output passes the agreed final gate before and after the wall repeats:
relative L2=0.1120304%, max absolute error=0.013671875, violating elements
35,763/4,194,304. Packed KV matches exactly. **Strict overall correctness remains
FAIL** because the same-input PV context check has relative L2=0.5039235% and
10.815072% violating elements. Every other local check passes. This is the
previously identified subnormal defect, not a new layout or cache append failure.
These timings are therefore diagnostic performance results, not a full
functionality PASS.

This C3 run uses baseline standalone concat/elementwise variants where some historical `latency_on_hw` Makefiles selected newer variants.
Consequently, a rev5 difference must not be attributed entirely to launch overhead.
C3 has no standalone dequantization operation. No variant was changed during
this measurement.

Artifacts: `build_llama_decoder_c3_parallel_20261009/results/prefill_s1024_20261009`.
`summary.json` includes exact wall samples, separate profile totals, per-operation
median cycles, final-output checks and retained local failures. `verify/` and
`timing/` each contain logs, comparisons, physical dumps and provenance; `run.sh`
records the executable command.

## Updated standalone variants and final-output-only acceptance

The subsequent user instruction makes the final decoder output the acceptance
gate. Intermediate checks are optional diagnostics and were not executed in this
run. The shared adapters now select the standalone Makefile variants and host
launch helpers rather than the earlier baseline concat/elementwise launch paths.
No existing standalone kernel implementation or RTL was changed. The fixture,
signed asymmetric KV math and required attention scale remain unchanged.

C3 Llama3 B1/S1024 completed on job 5785, BDF `0000:3d:00.1`; allocation released.

| Wall repetition | Connected seconds |
|---|---:|
| 0 | 31.837744606 |
| 1 | 31.832400584 |
| 2 | 31.824960277 |

**Final-output PASS. Wall median: 31.832400584s.**
The mandatory warmup also recorded 103 per-operation counter samples outside the
wall measurement: 3,182,154,125 cycles = 31.821541250s at 100 MHz. There are no C3
standalone dequantization operations, so subtracting dequantization leaves the
median unchanged. Explicit q/k/v head reorders account for 1.985731s of the
warmup profile and remain part of the connected graph.

The final output is byte-for-byte identical to the earlier variant run, with
SHA256 `3d50f1fc01e5c7dc8ec717d052625ccb8f480e726818983aeb20d944ab30e007`. Its existing final numerical metrics therefore
remain unchanged. The prior PV diagnostic remains recorded above, but it is not
an acceptance gate under the new instruction.

This run uses 3 wall repetitions and 0 extra profile passes; counter values come
from the mandatory preflight/warmup. It avoids a separate verification graph
and optional intermediate comparison. The user-requested rev5 comparison and
post-hoc dequantization reconciliation are reported by the parent experiment.

Artifacts:
`build_llama_decoder_c3_parallel_20261009/results/matched_variants_b1_s1024_20261009`.
`summary.json` contains samples, all operation cycles, final checks and the
zero-dequantization adjustment; `provenance.json` records source and device-binary
hashes. `timing/warmup_profile.csv` and `timing/timings.csv` are the raw samples.
