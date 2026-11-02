# Full prefill144 traffic checker candidate

The candidate is task-local under `prefill_checker_candidate/`; shared Python,
host, kernel, RTL and active-run files are unchanged. `manifest.json` freezes
candidate/baseline hashes, and `install.patch` contains only two checker edits.
Root authored this candidate; independent review/execution is required.

The exact additional model is Llama3, B1, S144, prefill, P0, effective C144,
32 query heads, 8 KV heads and D128. The three existing decode shapes remain
supported with identical byte/address expectations. Prefill requires all 64
records, index `2*query_head+chunk`, rows128/16, KV head `query_head//4`, row
position0/128, causal masking, 512-byte records and a single64-record dispatch.
Q/context each occupy1,179,648B. K sources are9,216B with eight16,384B adapters;
V is packed from canonical256 rows and has no device adapter. No extra tensor
allocation, intermediate HBM export, original-input write or partial record
list is admitted. Q/output offsets are `(144*head+row)*256`.

Expected totals are3,866,624 GEMM read bytes, zero GEMM writes,256 GEMM jobs,
8,257,536 FP16 SRAM-copy bytes or14,155,776 FP32 bytes. Per-record copy size
uses the actual padded query rows, while QK/PV software progress remains16
for both row sizes (the kernel counts row0 for QK and column groups for PV).
Both KV tiles remain required even when the first query chunk causally masks
the entire second tile. Prefill LMEM arena addresses are checked exactly,
including permitted score/probability/partial reuse and separate live row/U
state. Completion and ledger checks retain their previous interval, FIFO,
overlap, queue-capacity and drain requirements.

CPU provenance must name all six actual `cache_0..5` reference outputs, retain
the reference NPZ hash, declare `cache_source_stage=prefill` and
`checks.prefill_cache_outputs=true`, and specify canonical V padding144→256.
This does not assert decode's row128 cache-update/preservation checks. Input
hashes, complete49-file catalog and reference-context comparison remain
separate obligations.

Author checks: `test_candidate.py` passes30 tests (existing22 plus8 prefill
cases). It preloads the candidate manifest into unchanged real DMA/AFU parser
processes for a complete synthetic64-record trace. It tests shape/order/causal/
padding/LMEM tampering, missing or duplicate records, missing weight traffic,
both-format copy totals, all256 ledger jobs and provenance corruption. Synthetic
provenance does not prove physical packing. Historical actual P16/C32,
P128/C160 and P128/C256 manifests have identical counters, beats, ranges,
writable sets and dispatch geometry under old/new adapters; see the dedicated
equivalence receipt. No real prefill trace has been produced or audited.

Independent verifier should inspect against unchanged production
`host_flash_attention.cpp`, resident kernel loops and
`logs/prefill144_planning/independent_manifest_plan.json`; rerun the candidate
suite and historical manifest equivalence; check the separately produced real
host-only64-record manifest; and review exact source/hash scope. Before shared
installation, coordinate with the active full-decoder provenance owner and
record any authorized diagnostic-source drift. No running binary is rebuilt or
restarted, and R5 production inputs remain frozen. After installation, verify
the installed files match this candidate and repeat relevant actual decode
audit/CPU receipt checks. Full prefill execution, compressed capture correctness,
complete trace audit, fixed CPU context gates, full decoder and hardware remain
distinct unfinished gates.
