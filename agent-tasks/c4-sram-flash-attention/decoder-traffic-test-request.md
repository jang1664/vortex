# Decoder attention production traffic: proposed bounded replay

Status: read-only investigation / implementation request, 2026-10-24. No new execution or production-code edit has been performed. Proposed CLI/API/auditor additions below do not exist yet.

**Recommendation:** add one explicit host-only attention replay mode that uses the existing decoder argument builder and normal production kernel. Start with all eight GQA records from the completed Llama3 decode P16/C32 attention snapshot. This can establish decoder-attention traffic and compute accounting for that case without repeating expensive upstream projections. It does **not** replace full-graph correctness, prefill/decode hardware comparison, or unexecuted layout cases.

## Existing evidence and missing records

| Existing component / artifact | What can be reused; what is missing |
|---|---|
| [Quiet resident invocation](logs/decoder_resident_quiet/run_timeout7200000.sh), [compiled flags](logs/decoder_resident_quiet/flags_timeout7200000.json) | Full decoder uses C4 fusion, `DISABLE_FSDB`, `DEBUG_LEVEL=0`, no address/command trace macros. Its live binary must remain untouched. Control polling alone cannot reconstruct GEMM/CPU HBM addresses or pure compute cycles. |
| [Completed snapshot receipt](logs/decoder_resident_quiet/partial_after_concat_timeout7200000.json), [snapshot directory](logs/decoder_resident_quiet/partial_after_concat_timeout7200000) | Actual device `q_hadamard`, all updated packed K/V weights/scales/zeros, context and concat are archived with hashes after their operations completed. `buffers.tsv` records layout, dimensions and size, **not device addresses**. This is a partial graph snapshot, not a full-decoder pass. |
| [Decoder host](../../tests/regression/llama_decoder_C4/decoder.cpp), [API](../../tests/regression/llama_decoder_C4/decoder.h) | `alloc` already tracks address/size; `append` owns argument/dispatch allocations; `launch` downloads normal status and aggregates phase counters. `isolated()` first runs the entire graph and loops all ops. There is no existing attention-only CLI; private buffers/launch cannot be accessed through the public const operation list. |
| [Production builder](../../tests/regression/llama_decoder_C4/ops/host_flash_attention.cpp), [device wrapper](../../tests/regression/llama_decoder_C4/ops/device_flash_attention.cpp), [dispatch](../../tests/regression/llama_decoder_C4/kernel.cpp) | Reuse unchanged GQA grouping, query/output offsets, qparam strides, SRAM allocation, input padding, batching and shared attention implementation. Do not copy descriptors/kernel logic into a synthetic standalone test. |
| [GEMM DMA auditor](../../tests/regression/flash_attn/check_dma_trace.py), [all-AFU auditor](../../tests/regression/flash_attn/check_external_trace.py) | Reuse inverse C4 remapping, burst/beat accounting, AXI strobes and fence/DCR decoding. Current CLIs require seven standalone ranges, one argument allocation, shared zero data and standalone success strings. They cannot be passed decoder logs unchanged. |
| [Command ledger checker](logs/audit_cmd_perf_r2.py), [current standalone receipt](logs/cmd_perf_owner_core_fp32_m4_n256.json) | Reuse UID/FIFO/order/drain/class reconstruction. Existing script hardcodes four jobs; parameterize expected count from replay records and tiles, keeping all invariants. `gemm_wait_cycles` includes input loading and polling and is not pure compute. |

## Minimal host-only addition

Add diagnostic `--mode attention-traffic --attention-inputs DIR --traffic-manifest FILE` to the existing `llama_decoder_C4` host, backed by a narrow explicit `Decoder` replay API. Keep existing modes/default behavior unchanged. Do not use a `private` preprocessor override.

1. Validate the original model/stage/fixture metadata and immutable snapshot hashes/catalog. Load only `q_hadamard` and each `key.B.H` / `value.B.H` `.weight/.scale/.zero` input. Decode inputs must be the **updated** cache from the completed quantization boundary, not the fixture's initial past cache. No fabricated/minimized model dimensions.
2. Allocate Q and context with the same original `B`, `Q/G`, `G*S`, `pad8` and C-tiled/A-tiled metadata. Reuse `alloc`, then call existing `build_resident_attention(B,S,Q,V,D,G,C,L)` and `launch` once for its complete batched attention operation. Do not call full `load/build/run` merely to discard their huge weight allocations and upstream work. Keep the normal production `kernel.vxbin` built from the unchanged decoder source list/variant flags.
3. Export the manifest **before** `vx_start`, using actual allocator addresses and verbatim constructed `DecoderFlashArgs`. Include exact argument/dispatch sizes and addresses, runtime geometry, all input/output/padding ranges, access roles, logical sizes versus cache-line envelopes, each record's group/query indices, original tensor dimensions, byte offsets/strides, qdir/wtrans/qblk, SRAM addresses and `debug_export=0`. Use source-derived `sizeof`, not an assumed ABI constant. Reject overlapping role envelopes or classify a shared cache line with exact strobes.
4. Execute normal producer padding and the production batch wrapper; no device debug tensor export, score/P/partial/state download, alternate softmax, force, or host intervention between its records. After completion, download normal status/counters and context only. Preserve padded output canaries and compare logical context with the archived same-input resident output and existing `logical`/`hybrid_metrics`/`LOCAL_THRESHOLDS` helpers. This is an attention-boundary check, not the full `compare_attention_backends.py` gate, which also requires final decoder output.
5. Print distinct markers such as `DECODER_ATTENTION_REPLAY records=8 diagnostics=0`, per-record OK/tile/copy/sequence counters, and `ATTENTION_TRAFFIC_REPLAY PASSED full_decoder_pass=0`. Do not spoof standalone `flash_attn` success strings to bypass its auditor assumptions.

## Approved manifest contract v1

Host emits actual allocations, records, configuration, paths and sizes into a raw manifest; no new host SHA/JSON dependency is required solely for provenance. Independent verification preserves that raw file and SHA, captures inputs/sources/binaries before and after execution, and emits an augmented provenance receipt. Never overwrite the raw host manifest or imply a post-run hash proves an uncaptured compile input.

```text
schema: "c4_decoder_attention_traffic_v1"
model: {name, batch, seq, stage, past_kv, capacity, q_heads, kv_heads, head_dim}
backend: "resident" | "resident-fp32"
snapshot: {path}                       # receipt/input hashes added independently
geometry: {banks:32, ports:4, beat_bytes:64, address_bits:34,
           cores:1, warps:4, threads:16}
buffers: [{name, base, bytes, role, layout, matrices, rows, cols}]
dispatch: {base, bytes, operation, args_base, count}
arguments: {base, bytes, record_bytes}
records: [{index, batch, query_head_start, kv_head, row_start,
           attention:{ALL actual vx_flash_attention_args_t fields},
           key_source, key_source_bytes, key_padded_bytes,
           value_source, value_scale_source, value_zero_source, value_source_rows}]
```

Addresses are hexadecimal strings; sizes/counts are decimal integers. Buffer roles are exactly `q`, `k_weight`, `k_scale`, `k_zero`, `v_weight`, `v_scale`, `v_zero`, `context`, `pad_k_weight`, `pad_v_weight`, `pad_v_scale`, `pad_v_zero`. Emit actual `sizeof(DecoderDispatch)` and `sizeof(DecoderFlashArgs)` (currently 16/512 bytes), not hardcoded values. Records contain constructed argument fields verbatim; expected byte/job counts are independently derived by the checkers, not supplied as trusted manifest totals. Post-run downloaded statuses/counters belong in a separate completed-record receipt.

The code reservation comes from the **single existing app `MEM_RESERVE` log**; host does not parse vxbin. Retain the existing source-verified fixed stack/performance/fence rules. Require DCR startup ARG to equal `dispatch.base`, `dispatch.args_base == arguments.base`, and `dispatch.count * arguments.record_bytes == arguments.bytes`. Decode exact AXI-Lite startup DCR writes when base-DCR trace is absent, as in the existing selective-trace auditor. Do not treat dispatch and arguments as interchangeable ranges.

Independent augmentation records `snapshot.receipt_sha256`, input `{name,sha256,bytes}` entries, source/config/binary hashes and raw-host-manifest SHA. The [input manifest](logs/decoder_traffic_planning/input_manifest.json) freezes all 49 actual inputs (65536 bytes), catalog and expected context hashes. Its SHA256 is `32f381951ee6917c7039d695f7525ea245f972c76679f3688201ce73f81d5db6`; the immutable snapshot receipt SHA256 is `2e5dbd80aed9ec4454b4271feaae35eb810701472be0c6f14d367e0dd2f06373`. The snapshot explicitly has `full_decoder_pass=false`.

## Initial coverage and exact accounting

Use the archived `llama3-8b_decode_p16_c32` snapshot: B1/S1/Q32/V8/D128, G=4, eight records of M4 padded to M8, valid KV length17/capacity32, QK WTRANS1/QDIR0 and PV WTRANS0/QDIR1, qblk128, tiled context. Execute **all eight** original groups, not a single synthetic head. Run FP16 resident first, then FP32 with identical Q/K/V; FP32 changes SRAM export format, not external input geometry. Keep the known full-graph comparisons separate.

Per record with one KV tile, expected GEMM DMA reads follow the real command lengths in `VX_gemm_fsm` (not allocated slot size): Q2048, K-weight8192, K-scale256, K-zero256, V-weight8192, V-scale2048, V-zero2048 bytes. Thus all eight records require Q16384, K/V weights65536 each, K-scale/zero2048 each, V-scale/zero16384 each: **184320 total GEMM read bytes, zero GEMM AW, 16 GEMM jobs**. Independently check each address window and tile offset. K qparam slots are 512-byte aligned but only 256 bytes are loaded per tile; do not substitute slot capacity for transfer length. Derive and assert these expectations from original geometry/layout formulas before examining observed counts.

Production input padding is legitimate external traffic and must remain visible:

- Snapshot per KV head has 2048-byte K/V weights and 512-byte scale/zero allocations. The wrapper pads K/V weights to 8192 bytes and V scale/zero to 2048 bytes each.
- These named `attention.key_pad.*`, `attention.value_pad.*`, `attention.value_scale_pad.*`, `attention.value_zero_pad.*` ranges are **input adapters**, not score/P/partial/online-state spill buffers. Permit CPU writes only to these exact constructed destinations plus context/runtime/status; original Q/K/V are read-only during the measured launch. Check actual source byte reads and destination stores against the wrapper's dimensions.
- Logical adapter stores total 20480 bytes per record, but cache writeback/strobe traffic need not equal the count of software stores. Report actual AFU read response payload, write bus bytes and valid strobe bytes separately; do not manufacture exact CPU byte expectations from allocation sizes.
- Enumerate LMEM score/P/partial/U/m/l/alpha ranges from every argument record and confirm they are in reserved LMEM; no corresponding HBM allocation or accesses are allowed. Only final context is an attention output in HBM. Count runtime stack/arguments/code/fences separately, preserving all-AFU coverage.

This first replay covers real GQA, padded rows, QCOL/QROW input layouts and the small-cache adapters. It does not cover multi-KV stride advancement or prefill query chunk offsets. Later accounting cases must retain actual metadata for decode P128/C160 and P128/C256 (KV129/two tiles, padded versus direct inputs), and prefill144 (128+16 query chunks, causal offsets/tail). Prepared CPU fixtures exist under `build_c4_sram_fusion/fixtures/resident_attention`, but their `reference/` contains only final output; packed **updated attention-boundary** inputs are not automatically a replay-ready device snapshot. Obtain completed device boundary snapshots, or explicitly label a separately packed `reference.npz` replay as CPU-fixture-input coverage. Reuse existing packing helpers; do not silently substitute initial cache contents. A selected-record prefill replay may cover a layout edge but cannot claim whole-operation traffic totals.

## Trace/auditor changes and compute evidence

### P128/C256 follow-up

The next admitted shape is complete Llama3 decode P128/C256, with all eight
GQA records and two KV tiles per record. No matching device snapshot was found
in the inspected workspace catalogs. Inputs will therefore be explicitly
labeled `CPU-fixture-input`, packed from the prepared fixture's **updated**
`reference.npz` cache arrays and Q, with independent packing round-trip checks.
The initial cache is not a valid substitute. Numerical context comparison is
against that CPU reference; actual-device full-decoder comparisons remain open.

Each head owns 16,384-byte K and V weights, 1,024-byte K scale/zero buffers,
and 4,096-byte V scale/zero buffers. No input-padding allocation is allowed.
Q/context remain 16,384 bytes each across all groups. Exact expected GEMM
reads are 352,256 bytes, with zero stores and 32 complete jobs. Q is loaded
once per record; weights advance by 8,192 bytes, K qparam slots by 512 bytes
(256 bytes read), and V qparam slots by 2,048 bytes. Per-record completion
requires two completed tiles, current tile 1, DMA sequence 7, and 16 QK/PV
progress events. Total SRAM copies are 114,688 bytes for FP16 or 196,608 bytes
for FP32. Existing trace, drain, ledger, numerical and provenance gates apply.

The checker accepts only the original P16/C32 and this P128/C256 shape.
P128/C160 and prefill144 remain separate requirements: their CPU V packing
must reconcile the existing TVM plan with the decoder's full-128-row physical
padding before replay. Prefill also requires correct multi-record query-chunk
metadata. Neither shape is silently accepted through the C256 extension.

Use existing selective trace macros plus `DBG_TRACE_GEMM_CMD_PERF`, no `DBG_TRACE_PIPELINE` and no generic wrapper `--debug`. Host `MAKEFLAGS=DEBUG=3` enables existing allocator diagnostics. An addressful JSON manifest is still required: decoder uses separate dispatch and record arrays, many named tensors and padding buffers, so allocation log count assumptions from the standalone script are invalid.

Add optional `--decoder-manifest` modes to the existing DMA and all-AFU checkers, reusing `logical_address` and existing parsing/validation logic. Preserve existing standalone guards and negative controls. It must:

- Audit exact GEMM DMA per-record input intervals/byte counts, including separate K-zero and V-zero, expected reused inputs/multiplicity and zero stores.
- Classify **all** AFU requests across startup, the one attention launch and final drain; bound dispatch/argument arrays independently. Track DCR startup-argument pointer to the actual dispatch packet, not directly to the attention records. Account for code/stack/performance/fence accesses using existing source-backed rules. Reject unknown/ambiguous ranges, any Q/K/V input write, or a newly allocated intermediate spill range. Validate bursts/responses/strobes rather than merely counting request addresses.
- Cross-check expected record/tile/GEMM job counts and final OK/sequence/copy counters. Missing trace, missing jobs, partial execution or absent final drain must fail.
- Reconstruct every command ledger and require exact emitted/issued/completed equality, zero incomplete records, child FIFO/order/final-drain invariants. Sum `compute_pipeline_cycles` across the expected16 jobs and report per-class service/queue and whole attention/copy/SIMD/control intervals. Compute-active intervals can overlap memory service; never add them blindly or relabel GEMM wait as compute. Generalize the existing four-job checker rather than dropping its assertions.
- Add negative controls: missing/tampered record manifest, wrong expected byte multiplicity, injected GEMM AW, injected CPU write to Q or a score-spill range, and missing final job. Keep DMA-only and all-AFU outcomes separate.

No new RTL trace hook is required for this first proposal: allocator/argument manifest plus existing AFU/MEM/CACHE/GEMM/CMD_PERF traces supply the needed observations. If phase attribution of adapter traffic later needs a marker, use a passive simulation observer or host launch boundary; do not add device debug exports to normal attention.

## Proposed commands after implementation review

The following new mode/options and auditor options are a concrete proposed interface, **not currently runnable**. All paths are isolated; neither live decoder build is modified.

```bash
repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
source /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
source "$repo/configs/c4_sram_fusion.sh"
unset DEBUG DEBUG_AXI
export CC=/usr/bin/gcc CXX=/usr/bin/g++ PATH="/usr/bin:$PATH"
mkdir -p "$repo/build_c4_decoder_traffic"
cd "$repo/build_c4_decoder_traffic"
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
make -C hw config
make -C kernel
make -C runtime/stub
export LD_LIBRARY_PATH="$PWD/runtime:${LD_LIBRARY_PATH:-}"
export MAKEFLAGS='DEBUG=3'
export VORTEX_SHM_PATH="/dev/shm/vortex_decoder_traffic_fp16_$UID"
out="$repo/agent-tasks/c4-sram-flash-attention/logs/decoder_traffic/fp16_p16_c32"
mkdir -p "$out"
timeout 10800s ci/run_black.sh xrt-vcs-sim --app llama_decoder_C4 \
  --configs-extra '-DDISABLE_FSDB -DDBG_TRACE_AFU -DDBG_TRACE_MEM -DDBG_TRACE_CACHE -DDBG_TRACE_GEMM -DDBG_TRACE_GEMM_CMD_PERF' \
  --args "--model llama3-8b --batch 1 --seq-len 1 --stage decode --past-kv-len 16 --cache-capacity 32 --mode attention-traffic --attention-backend resident --timeout-ms 7200000 --fixture $repo/build_c4_sram_fusion/fixtures/resident_attention/llama3-8b_decode_p16_c32 --attention-inputs $repo/agent-tasks/c4-sram-flash-attention/logs/decoder_resident_quiet/partial_after_concat_timeout7200000 --traffic-manifest $out/manifest.json --output $out" \
  > "$out/wrapper.log" 2>&1
run_status=$?
printf 'BLACKBOX_EXIT=%s\n' "$run_status" >> "$out/wrapper.log"
cp sim/xrtsim_vcs/simv.log "$out/simv.log"
[ "$run_status" -eq 0 ] || exit "$run_status"
python3 "$repo/tests/regression/flash_attn/check_dma_trace.py" \
  --decoder-manifest "$out/manifest.json" --app-log "$out/wrapper.log" \
  --trace "$out/simv.log" --output "$out/dma_audit.json"
python3 "$repo/tests/regression/flash_attn/check_external_trace.py" \
  --decoder-manifest "$out/manifest.json" --app-log "$out/wrapper.log" \
  --trace "$out/simv.log" --dma-audit "$out/dma_audit.json" --output "$out/external_audit.json"
# Run the generalized command-ledger checker for the 16 jobs derived from records.
```

Preserve the first trace before another launch. For FP32, use a distinct result directory/SHM and `resident-fp32`; retain all other geometry/inputs. The proposed finite host/outer caps are declared up front for eight production records plus input adapters, informed by measured standalone run costs; never silently extend a live cap. Follow normal observation/polling guidance and preserve timeout failures.

Acceptance requires terminal application and auditor success, exact expected job/byte counts, context comparison with fixed limits, all source/fixture/binary/config hashes, normal `debug_export=0`, no unclassified external request, and complete command-ledger compute accounting. Record this as **decoder attention-only traffic/compute evidence for the executed shapes**, with full-decoder correctness and new-FPGA comparisons explicitly still pending.
