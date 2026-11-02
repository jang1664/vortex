# C256 CPU input attention replay: author handoff

- test_type: host checks, then blackbox
- test_path: tests/regression/llama_decoder_C4
- test_params: Llama3-8B decode B1/S1/P128/C256, resident FP16, all eight GQA records
- sim_tool: xrt-vcs-sim through configured `ci/run_black.sh`
- changed_files: `ops/host_attention_traffic.cpp`, app `README.md`, task-only `prepare_attention_cpu_inputs.py`
- author execution: no packer, host build, simulation, or checker run; source review only
- production builder, device kernel, decoder implementation and RTL changes: none

This extends only the host diagnostic shape guard and provenance requirements.
P16/C32 continues to use its actual device snapshot. The new exact pair
P128/C256 requires CPU fixture provenance; P128/C160 and arbitrary combinations
remain rejected. The same loader, resident builder and launch execute all eight
records. No expected DMA/job counts are inserted into the host manifest.
Live legacy session 5987 and all existing binaries remain unchanged.

## Input preparation

Source the existing TVM environment and the C4 configuration in bash. From the
repository root, choose a new output directory outside the immutable fixture:

```bash
python3 agent-tasks/c4-sram-flash-attention/prepare_attention_cpu_inputs.py \
  --fixture build_c4_sram_fusion/fixtures/resident_attention/llama3-8b_decode_p128_c256 \
  --output agent-tasks/c4-sram-flash-attention/logs/decoder_traffic/cpu_inputs_p128_c256 \
  --expected-reference-sha256 2f1b21745670b08cfd0261509309a08f317c564701a4e1072726823821957251
```

The utility checks exact fixture metadata/profile and source hash, reads updated
`q_hadamard`, `cache_0` through `cache_5`, and independent `context`. It rejects
initial-cache substitution: all six arrays must differ at row 128 and preserve
all other rows. K uses existing plan `(1,256,128,128,true,0)`; V uses
`(1,128,256,128,false,1)`. Existing weight/qparam pack helpers produce per-head
weights 16384 B, K qparams 1024 B each, V qparams 4096 B each. Q/context use the
existing `reference.logical` index map in reverse and require bit-exact logical
roundtrips; all padded rows start zero. No parallel layout formula is added.

`buffers.tsv` includes 49 inputs plus context. `input_manifest.json` contains
exactly 49 input hashes and the existing checker-compatible model, snapshot,
catalog and receipt fields, plus `kind="cpu-fixture-input"`. Its receipt is the
new `provenance.json`, never a copied device-run receipt. Provenance schema:

```text
schema: c4_attention_input_provenance_v1
kind: cpu-fixture-input
full_decoder_pass: false
model: {name,batch,seq,stage,past_kv,capacity,q_heads,kv_heads,head_dim}
snapshot, fixture: canonical paths
source_npz, initial_cache_npz: {path,sha256}
updated_cache_keys: [cache_0,cache_1,cache_2,cache_3,cache_4,cache_5]
profile: {path,sha256,fingerprint,layout_fields}
sources: [{path,sha256}]
files: [{name,path,bytes,sha256}]  # 49 inputs plus reference context
catalog_sha256
reference_context: {name,path,bytes,sha256}
checks: {q_context_logical_roundtrip_bitexact,unchanged_cache_rows_except_128,
         changed_elements_at_row_128,input_count,device_execution:false}
```

Verify helper/profile/source/output hashes independently, including byte
comparison of required packed inputs against the existing packing helpers and
both Q/context logical roundtrips. Verify all input hashes before and after
execution; preserve raw host manifest and its hash. Host intentionally does not
implement cryptographic hashing. It validates provenance identity/paths and
required catalog shapes/bytes; the independent checker validates the hashes.

## Rejections and regression checks

Use temporary copies, preserving immutable original inputs. Require rejection
for wrong P/C pair, prefill, missing provenance, wrong kind/model/source path,
`full_decoder_pass=true`, wrong updated-cache-key list, missing/duplicate catalog
row, required shape/size mismatch or truncated input. The packer must reject an
existing output directory, wrong reference hash, wrong fixture/profile, and an
initial-cache substitution. Check the current P16/C32 input manifest retains
`device-snapshot` behavior and normal decoder CLI/default timeout is unchanged.
Use independent checker negatives for data/hash and provenance tampering.

## Execution and numerical scope

Reuse the configured `build_c4_decoder_traffic` only after confirming both prior
replays are terminal and their traces/binaries are archived. Source `configs/c4_sram_fusion.sh` in
bash, host GCC/G++ `/usr/bin`, and the existing decoder traffic tracing flags
and finite bounds from `decoder-traffic-test-request.md`. Use unique SHM and
explicit `--timeout-ms 7200000` and the agreed outer 10800-second cap. Required
arguments in the configured `ci/run_black.sh xrt-vcs-sim` command are:

```text
--model llama3-8b --batch 1 --seq-len 1 --stage decode
--past-kv-len 128 --cache-capacity 256 --mode attention-traffic
--attention-backend resident --fixture ABS_FIXTURE --attention-inputs ABS_INPUTS
--traffic-manifest ABS_MANIFEST --output ABS_OUTPUT --timeout-ms 7200000
```

Use the parent-owned current strict DMA/all-AFU/ledger/numerical checkers.
Require exit zero, all eight statuses/counters, 32 GEMM jobs, independently
derived 352256 GEMM read bytes, exact SRAM traffic/copy counters, no forbidden
intermediate HBM traffic, preserved padding, and logical context comparison
against CPU fixture `context` using unchanged local thresholds. Q is reused on
the second KV tile; do not double its HBM count. C256 uses no input-padding
scratch. Host success alone is not the independent numerical gate. Any numerical
failure remains a failure; do not relax tolerances or claim full decoder PASS.

This first run is FP16 only. FP32 needs a subsequent explicit decision. No C160
or prefill extension is included: V execution-K padding and prefill record/input
layout require additional work and must not be inferred from this exact shape.
