# C160 CPU input replay: author handoff

- test_type: host checks, then blackbox
- test_path: tests/regression/llama_decoder_C4
- test_params: Llama3 decode B1/S1/P128/C160, resident FP16, all eight records
- sim_tool: xrt-vcs-sim through configured `ci/run_black.sh`
- changed_files: app `ops/host_attention_traffic.cpp`, app `README.md`, task `prepare_attention_cpu_inputs.py`
- author execution: none; source inspection only
- production builder/kernel/decoder/RTL/checker changes: none

The preceding C256 host/packer/README sources are archived under
`logs/decoder_traffic_author/c160_extension/*.before`, with hashes in
`before.json`. Existing C256 results are preserved; live legacy session5987 is
unchanged. Root owns strict traffic-checker generalization.

## Prepare immutable inputs

Using the existing TVM environment and C4 config in bash, run the task utility
with the full fixture
`build_c4_sram_fusion/fixtures/resident_attention/llama3-8b_decode_p128_c160`,
a new output directory, and
`--expected-reference-sha256 18cac510887add471effc5a48ebe2a5e5805a5f4182b53b3e14ddcdaca2bb23e`.
It uses updated `reference.npz` arrays, not the initial cache. All six updated
arrays must differ at row128 and match initial cache in every other original
row. Preserve all original rows0–159, including inactive rows129–159.

K uses the original capacity160 plan `(1,160,128,128,true,0)`: weight10240 B,
scale/zero1024 B each. The unchanged resident builder/device adapter pads the
weight to16384 B on device. Both K qparam slots retain their512 B reservation;
the second slot has64 B payload and448 B zero padding.

V canonical weights `(160,64)` and scale/zero `(160,1)` are zero-padded to256
rows, then passed to the existing plan `(1,128,256,128,false,1)` and pack helpers.
This yields weight16384 B and scale/zero4096 B each. Original logical capacity
remains160. No V input adapter is allocated. Appending zeros to compact tiled V
bytes is invalid because the second-tile N-microtile strides differ.

The existing provenance and49-input receipt schemas are unchanged. Both declare
`kind="cpu-fixture-input"`; host manifest.snapshot.kind agrees. Provenance adds:

```json
"physical_padding": {
  "logical_capacity": 160,
  "value_execution_rows": 256,
  "value_zero_rows": [160, 256],
  "key_input_bytes": 10240,
  "key_adapter_bytes": 16384
}
```

`value_zero_rows` is a half-open interval. C256 emits the same description with
capacity256, empty interval `[256,256]`, and key_input_bytes16384. Hash/provenance
metadata changes with the utility revision; packed C256 data must not change.

## Independent verification before device execution

1. Regenerate C256 into a fresh directory and require byte-identical50 `.bin`
   files and `buffers.tsv` against the accepted C256 input snapshot. Check
   provenance/receipt hashes and explicit kind independently.
2. For C160, verify every physical packed weight nibble, every K/V qparam copy,
   and every reserved slot/tail byte against independent C++ offsets. Reuse the
   existing random-access/offset helpers described in
   `decoder-traffic-shape-extension-notes.md`; merely invoking the same TVM packer
   twice is insufficient. Invert all physical offsets to canonical cache arrays,
   require original rows0–159 exact and V rows160–255 allzero. Check every unused
   K qparam slot byte is zero. Require Q/context logical roundtrips and output
   padded-row zeros as before.
3. Require rejection of wrong shape/past/capacity pair, prefill, missing or wrong
   CPU provenance/model/paths, false updated-cache-key list, initial-cache
   substitution, compact V shape/bytes, and modified source/input/catalog hashes.
   Use temporary copies for negatives. A same-size corrupt/tail-poisoned input
   is rejected by the independent physical/hash check; host alone does not hash.
4. Recheck P16/C32 device-snapshot handling and P128/C256 CPU handling. Normal
   decoder paths, positive timeout parsing and default300000ms remain unchanged.

## Complete attention execution gate

Use a new isolated configured build, source `configs/c4_sram_fusion.sh`, use host
GCC/G++ `/usr/bin`, unique SHM, and the same complete traffic tracing setup and
independent checker gates as C256. Pass the full Llama3 decode B1/S1 P128/C160
fixture/input paths, `--mode attention-traffic`, `--attention-backend resident`,
`--timeout-ms 7200000`, and finite outer43200s. The wrapper is configured
`ci/run_black.sh xrt-vcs-sim`.

Require exit0, all eight returned statuses/counters, all32 GEMM jobs, unchanged
local context numerical thresholds, preserved padding, strict GEMM and all-AFU
traffic audits, and complete ledger accounting. Both tiles execute; Q is reused
on tile1. The GEMM logical read total remains352256 B, while all-AFU must
separately attribute the existing K input-padding read/write traffic to its
exact named original/scratch buffers. No score/P/PV/online-state HBM allocation
is permitted. No partial operation or full-decoder claim is allowed.

This authorization adds only C160 decode. Prefill remains rejected; no FP32 C160
run is requested until the FP16 evidence is reviewed.
