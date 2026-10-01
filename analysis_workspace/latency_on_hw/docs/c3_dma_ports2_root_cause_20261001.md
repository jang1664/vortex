# C3 two-port D-cache DMA failure: root cause

The C3 v2 failure is caused by response misassociation in the legacy D-cache
splitter. LMEM port/bank address calculation is correct for the reproduced case.
The existing tag-indexed response reorder path resolves the failure.

## Reproducer and controlled comparison

All blackbox runs use `ci/run_black.sh xrt-vcs-sim`, independent configured
build directories, the same current-source snapshot, and the same kernel binary:
`e02e64ff8a4e42ca33c0fe4d43dba867ee7e03c803c2c6206dc038715fd62ed2`.

- Config: `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh`.
- App: `fpint_gemm_ffn_hw_naive`.
- Args: `-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1`.
- Geometry: M=128, N=256, K=256, QBLK=32, QDIR=0.
- C3 v2 LMEM: 1,310,720 bytes, 16 banks, 16 lanes of 8 bytes.
- D-cache: two 64-byte DMA ports, aggregate beat 128 bytes.

| Setting | Verification | Mismatches | Core cycles | Splitter tag mismatches |
|---|---|---:|---:|---:|
| Original C3 v2: ports=2, reorder=0 | FAIL | 1,024 | 47,446 | 16 |
| Same config plus `DMA_SPLIT_RSP_REORDER=1` | PASS | 0 | 47,446 | 0 |
| Prior control: ports=1, otherwise same C3 v2 config | PASS | 0 | 48,348 | Not measured |

The first two runs include identical bounded observational tracing. Their
47,446-cycle result is also identical to the earlier untraced failing case.
The ports=1 control is historical evidence from
`candidate_pair_latency_compare_20261001_230859/C3_v2/gemm_naive_dma1`.
It retains the new LMEM capacity, cache bank count, and HBM configuration.

## Failure mechanism and direct trace evidence

`VX_mem_unit.sv` bypasses the cache splitter for `DMA_DCACHE_PORTS=1`.
For two ports, `dma_dcache_split` joins two independent cache-line responses.
Its `g_masked_response` legacy path queues each lane in arrival order and assigns
the aggregate response the oldest request-context tag. It does not use the
returned lane tags to select matching payloads. D-cache responses are not
required to preserve request order; misses and independent memory responses
can complete in different orders.

The very first aggregate requests in the failing run are:

| Aggregate tag | Aggregate source byte address | Lane 0 source | Lane 1 source |
|---|---|---|---|
| 0 | `0x10000` | `0x10000` | `0x10040` |
| 1 | `0x10080` | `0x10080` | `0x100c0` |

The observed sequence is:

1. At t=89,245,000 ps, lane 1 returns **tag 1** before tag 0.
2. At t=89,265,000 ps, lane 0 returns tag 0.
3. At t=89,275,000 ps, the splitter combines those halves using context tag 0:
   `TAG_MISMATCH lane=1 context_tag=00 returned_tag=01 context_mask=3`.
4. At t=89,295,000 ps, the DMA accepts that mixed aggregate beat as tag 0.
5. At t=89,325,000 ps, it writes the mixed beat to LMEM `0x1ffc00000`.
   Its upper 64 bytes came from `0x100c0`, although they should come from
   `0x10040`.

The DMA read slot and LMEM mapping faithfully process the incorrect upstream
payload. Corruption therefore precedes the LMEM port calculation.
There are 16 such lane/tag mismatches in the first input descriptor.

Reconstructing all 65,536 output bytes from accepted DMA writes shows exactly
1,024 FP16 values differ from the passing run: **rows 0–7, columns 0–127**.
Only the first eight rows of the first input tile differ in the input-DMA
comparison. Of the 1,024 byte positions carried by the swapped 64-byte halves,
512 actual byte values change; unchanged bytes do not imply correct association.
This accounts for the existing host verification failure without relying on
its ten printed mismatch samples.

## Other hypotheses checked

| Perspective | Evidence | Finding |
|---|---|---|
| Host LMEM offsets/capacity | Previously shifted the same scratch layout by 1 MiB; identical 1,024 errors. Scratch uses 184,320 bytes and fits the 1.25 MiB capacity. Ports=1 passes at the same capacity. | Not the reproduced cause. |
| LMEM bank/port calculation | Checked 29,696 accepted narrow requests against aggregate address, data, byte enables, and direction in each traced run; zero discrepancies. | Mapping is correct. |
| Width conversion / realignment | Ports=2 uses 128 B on both sides. The corruption already exists in `DC_RSP` before the equal-width realigner; enabling reorder alone fixes it. | Not the reproduced cause. |
| Response tags and ordering | Actual cache-lane tag differs from context tag 16 times. | Direct cause. |
| LMEM write completion / fence | All 18 descriptor completions show `pending=0`, `reserved=0` in each traced run. | No premature completion observed. |
| Kernel/software binary | Passing and failing traced runs have identical kernel SHA-256. | Software changes do not explain the difference. |

For a 128-byte aligned aggregate address A, LMEM lane i receives word address
`(A >> 3) + i`, equivalently `((A >> 7) << 4) | i`. The bank is the low four
word-address bits. Total LMEM capacity does not enter this bank selection.
Earlier capacity tests also passed at 1 MiB, 1.25 MiB, 1.5 MiB, and 2 MiB.

## Independent splitter regression

Reused `hw/unittest/mem_bus_split_depth/tb_mem_bus_split_depth.sv` with C3's
2×64 B cache geometry, response depth 16, masks and output backpressure:

| Reorder implementation | Inject out-of-order responses | Result |
|---:|---:|---|
| 0 | 0 | PASS, 906 read responses |
| 0 | 1 | Expected FAIL: payload mismatch, request id=2, lane=1 |
| 1 | 1 | PASS, 906 read responses, 139 reordered returns |

This independently reproduces the missing ordering assumption in the splitter.
It does not need GEMM execution or LMEM capacity changes.

## Applied correction

Added `-DDMA_SPLIT_RSP_REORDER=1` beside `DMA_SPLIT_RSP_DEPTH=16` in the C3 v2
config. The existing SRAM-backed `VX_mem_bus_split_reorder` stores each lane
response under its private transport tag and only combines the matching lanes
for a request before restoring its original tag.

Only that C3 config is changed in the repository. No functional RTL or improve
config is changed. Observational RTL additions exist only in the temporary
snapshot and are archived as `observational_trace.patch`. This task does not
measure synthesis resources or estimate any resource increase from enabling
the existing naive reorder buffer.

## Final verification without observational tracing

The corrected config was sourced from `config_fixed.sh`, an exact copy of the
modified repository config. Neither run adds debug trace defines.

| Weight layout | Host validation | Core cycles | Instructions |
|---|---|---:|---:|
| `-t 0` | PASS | 47,446 | 9,575 |
| `-t 1` | PASS | 47,671 | 9,593 |

Both use the same M=128, N=256, K=256 workload, with only the weight-layout
argument changed. All four full-GEMM runs have the same kernel SHA-256. The
untraced `-t 0` run reproduces the traced passing result exactly. Reorder changes
correctness with zero measured cycle delta in this case. This is a workload
observation, not a general claim about every DMA transfer.

Config syntax, uniqueness of the reorder define, and the scoped Git diff were
also checked. The repository's DMA node and splitter RTL still match HEAD.

## Evidence and reproduction

Artifact directory: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c3-dma-ports2-debug-20261001_233758`.

- `run_debug.py`, `experiment.json`: traced full-GEMM controlled experiment.
- `ports2_original/gemm_naive/` and `ports2_reorder/gemm_naive/`: full run logs,
  VCS logs, compile logs, model manifests, commands and result JSON.
- `audit_trace.py`, `trace_audit.json`: accepted LMEM lane and fence audit.
- `audit_data_corruption.py`, `data_corruption_audit.json`: reconstructed
  input/output difference locations.
- `test_split_debug.py`, `split_verified_results.json`, `split_unit/`: focused
  VCS regression, including the deliberately failing legacy-path case.
- `run_fixed.py`, `config_fixed.sh`: untraced verification of the applied config,
  with both `-t 0` and `-t 1` weight layouts.
- `source_sha256.json`, `final_source_hashes.json`, `observational_trace.patch`:
  source provenance and observational changes.

After configuring a build and sourcing the corrected C3 config:

```sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive \
  --args "-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1"
```
