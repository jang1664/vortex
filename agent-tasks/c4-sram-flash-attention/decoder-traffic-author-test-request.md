# Host attention replay implementation handoff

- test_type: host checks, then blackbox
- test_path: tests/regression/llama_decoder_C4
- sim_tool: xrt-vcs-sim through configured `ci/run_black.sh`
- primary verification contract: `decoder-traffic-test-request.md`
- changed files: `decoder.h`, `main.cpp`, `README.md`, new `ops/host_attention_traffic.cpp`
- author build/simulation status: not run; source/ABI-field coverage and localized diff inspected
- production device/RTL changes: none

The explicit CLI mode is implemented. The new host translation unit is included
by the existing `ops/host_*.cpp` wildcard. It uses the vendored nlohmann header;
no new library or crypto dependency is added. `decoder.cpp`, the resident
builder, device attention wrapper and decoder dispatch source retain their
pre-edit hashes. The running legacy session 5987 and resident simulation
binaries have not been rebuilt or restarted. Source receipts and original
snapshots are in `logs/decoder_traffic_author/`.

The host validates the existing fixture metadata without uploading projection
weights. Since `Decoder::load` has no metadata-only helper, its small metadata
checks are repeated locally, with the replay additionally restricted to full
Llama3 decode B1/S1/P16/C32 and C4 geometry. All 49 required snapshot input
names, layouts, dimensions and sizes are validated. Q/context preserve the
original eight matrices of four logical rows, padded to eight rows, D128.
The exact existing `build_resident_attention` and `launch` run once for all
eight records. Input-padding allocations come only from that builder.

The manifest uses the agreed `c4_decoder_attention_traffic_v1` schema, hexadecimal
address strings, decimal counts, actual `sizeof` values, actual allocator
addresses, and all 67 named attention ABI fields plus every outer-record field.
It contains no expected DMA byte or GEMM job totals. Kernel address and runtime
geometry are included; the exact kernel reservation remains the allocator's
single `MEM_RESERVE` log record. The prelaunch manifest remains unchanged.
After normal launch/status validation, `OUTPUT/completion.json` uses
`c4_decoder_attention_completion_v1`, returns the actual record fields/counters,
and declares `full_decoder_pass=false`. Only context is downloaded as tensor
data. Its zero-initialized padded rows are checked with the existing C layout
helper. Host success does not claim the independent numerical comparison passed.

Independent verification owns checking archived snapshot hashes before and
after execution, preserving the raw host manifest/hash, numerical comparison,
strict range-envelope/traffic audit, and command-ledger reconstruction. Canonical
snapshot and individual input paths are recorded for provenance augmentation.
Output/manifest paths inside the immutable snapshot are rejected.

Suggested host checks before the long run:

- Existing default timeout and normal mode parsing remain unchanged.
- Missing replay input/manifest, legacy backend, per-head mode, diagnostic timing, or stop-after are rejected.
- Input/manifest options in a non-replay mode are rejected.
- A wrong fixture model/stage/past/capacity, missing or duplicate catalog record, wrong required shape/size, or short tensor file is rejected.
- Source hashes of all unchanged device/builder files and the live binaries still match their recorded versions.

Then run the prescribed isolated FP16 replay followed by FP32 using identical
immutable Q/K/V. Keep the complete 64-bit argument fields and all eight groups.
Require application exit zero, all returned statuses, padded canaries, fixed
local context comparison, strict DMA/all-AFU audits, and complete command-ledger
accounting. The host marker is exactly
`ATTENTION_TRAFFIC_REPLAY PASSED full_decoder_pass=0 context_comparison=external`.
