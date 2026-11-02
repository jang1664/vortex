# Full prefill144 replay: resource and manifest plan

Initial read-only assessment, 2026-10-24; implementation status updated below.
All64 records remain required for full-operation traffic claims and the complete
hardware numerical gate. Selected records can only supplement those gates.

## Launch contract selected at 03:50 KST

The prefill host/packer and traffic auditors were installed after independent
review (`logs/prefill_shared_install.json`). Lossless gzip wrapper/readers were
installed separately (`logs/trace_gzip_shared_install.json`), with the reviewed
collector retained at `trace_gzip_candidate/capture_vcs_trace.py`. These are
diagnostic changes; all389 frozen R5 FPGA inputs remain unchanged. No full
prefill device run had started at that installation boundary. The independently
reviewed full64-record runner subsequently launched as session49228 at04:08 KST
in `build_c4_prefill144_trace`, after all658 dependency hashes and49 input files
passed preflight. Launch free space was68,598,259,712 bytes. Evidence is
`logs/prefill144_full/fp16/`; compilation/capture is active, with terminal
traffic/context acceptance still pending.

Use a fresh configured build and fixed bounds: host operation259200000 ms
(72 hours), collector outer345600 seconds (96 hours), drain/final verification
3600 seconds within the outer bound. The historical51–59 hour estimate motivates
the operation allowance; the outer bound also covers compilation, upload and
verification. These bounds apply only to the new run and are not extensions of
any live run. They are finite limits, not runtime guarantees.

After capture, the complete traffic/ledger audit has a separate21600-second
(6-hour) allowance and CPU-context comparison has600 seconds. They are outside
the96-hour capture cap: auditors reread the entire decompressed stream, whose
estimated raw size is175.6GB. Do not reuse the small smoke's300-second audit cap
or describe the96-hour bound as covering these subsequent checks.

Require at least40 GiB available immediately before fresh build/launch; the
03:49 observation was65 GiB. The estimated14 GB gzip stream leaves room for
build products and existing concurrent work, but shared filesystem usage must
be checked again. Never materialize the full raw trace or delete prior evidence
to satisfy this gate. Preserve every trace byte and all five trace macros.

Before launching the full run, require an actual configured-wrapper/FIFO VCS
attention smoke with successful host/simulator/wrapper/collector exits, complete
gzip integrity verification, and numerical/traffic/ledger audits. Process mocks
and archived-log equivalence alone do not satisfy this integration prerequisite.
The full run must then pass all64 records,256 GEMM jobs, completion, DMA/all-AFU
traffic and CPU-context checks. The complete new-image hardware matrix remains
a separate requirement.

## Independent complete-operation contract

The64 planned records and relative byte offsets are enumerated in
`logs/prefill144_planning/independent_manifest_plan.json`. These are independent
expected mappings, not device allocation addresses or observed results.

For query head `h=0..31` and chunk `c=0..1`, record index is `2*h+c`, KV head is
`floor(h/4)`, row-start is `128*c`, M is128/16, and G is1. Both records use
causal=true, query_position_base=row-start, KV length144 and two128-key tiles.
Q and output offsets are `(144*h+row_start)*256` bytes. Each record executes
two QK/PV pairs, including the first chunk's entirely future-masked second tile.

| Complete-operation item | Expected bytes/count |
|---|---:|
| Records / GEMM jobs | 64 /256 |
| Q /context allocation each | 1179648 B |
| All49 input tensors | 1466368 B |
| Input +context +eight key-padding allocations | 2777088 B |
| Arguments /dispatch | 32768 B /16 B |
| GEMM input reads | 3866624 B |
| SRAM bridge copies, FP16 | 8257536 B |
| Key-adapter logical loads /stores | 589824 B /1048576 B |

The last row describes device copy-loop logical bytes. It is not an AFU request
count: cache reuse affects actual HBM traffic. Each of eight key weights is9216 B,
each K scale/zero is1024 B. Key scratch is16384 B per KV head. V canonical rows
144–255 must be zero-padded before packing: weight16384 B and scale/zero4096 B
per KV head. Q is loaded once per record and reused on its second KV tile.

## Measured inputs to the estimate

Immutable archived standalone runs:

| Run | VCS CPU seconds | Core cycles | Raw trace bytes |
|---|---:|---:|---:|
| FP16 M128/KV128, one tile | 2560.930 |1084828 |2416212688 |
| FP16 M16/KV384 causal, three tiles |954.180 |358295 |982981257 |

Sources are `simv_selective_fp16_m128_n128_retry.log` and
`simv_fp16_v2_m16_n384_causal.log`, with app logs of matching names under `logs/`.
VCS footer CPU times are measured. The M128 start banner20:56 and footer21:38:53
give wall time2514–2573s at minute-resolution start; M16 19:41→19:59:27 gives
1048–1107s. CPU seconds are not wall seconds.

A simple two-tile extrapolation is
`32 * (2*M128_one_tile + 2/3*M16_three_tiles)`:184255 CPU seconds, about51.2 CPU
hours, and175607878848 raw trace bytes (175.6 GB,163.5 GiB). This is an estimate,
not an observed full-prefill runtime or guaranteed upper bound. It scales fixed
initialization/finalization incorrectly, and standalone qparam settings, causal
masking and pre-local-owner-repair source differ from the decoder target.
The observed CPU/wall factors suggest roughly51–59 wall hours under similar
conditions; current scheduling/load could change that. Existing7200000ms
per-launch and43200s outer limits are much smaller. No current limit is changed.

The shared filesystem had about69 GiB free (`df -h`,75027734528 B in the recorded
planning sample). A full raw trace at that extrapolated size does not fit. A new
full run cannot assume it may delete existing evidence or silently reduce64
records to selected records.

## Required trace events and existing switches

| Auditor data | Existing source /compile-time switch |
|---|---|
| `gemm:tmem:dma ... AR_FIRE/AW_FIRE` | `VX_dma_engine.sv:544`, `DBG_TRACE_GEMM` |
| All AXI read/write addresses, read responses, write data strobes | `VX_afu_wrap.sv:715`, `DBG_TRACE_AFU` |
| `tags-flush` UUIDs | `VX_cache_bank.sv:702`, `DBG_TRACE_CACHE` |
| Zero-address `MEM Rd Req` with matching UUID | `Vortex.sv:318`, `DBG_TRACE_MEM` |
| Six structured ledger record kinds | `VX_gemm_ctrl.sv:1577`, `VX_gemm_tmem_dma_ctrl.sv:2384`, `DBG_TRACE_GEMM_CMD_PERF` |
| Startup argument writes | Unconditional `[TB] REG_WRITE` in `tb_vcs_xrtsim.sv:466`; optional base-DCR records also accepted |

The six ledger kinds are GEMM_CMD_PERF_SUMMARY, GEMM_CMD_CLASS_SUMMARY,
GEMM_CMD_TIMELINE, GEMM_CMD_OVERLAP_PAIR, GEMM_TILE_OVERLAP and TMEM_DMA_CMD_PERF.
`check_external_trace.py` requires CACHE+MEM UUID association to classify fence
reads at address0. Dropping either flag currently loses required evidence. The
other three flags also directly feed the auditors. Thus none of the existing
five flags is obviously removable with unchanged auditors. FSDB is already
disabled. Removing a trace flag cannot be presented as an equivalent gate
without a separate validated replacement.

## Storage alternatives supported by measured trace sizes

Read-only scans retained source hashes, event counts and ordered event-stream
hashes in `logs/prefill144_planning/trace_size_scan_v2.json`. M128 contains192 DMA
bursts,79171 AXI lines,4352 flush records,2zero-address reads and complete535-command
ledger records. Its complete parser-event subset is9846541 B. The M16 subset is
5814500 B; that historical run has no command ledger, so it cannot prove ledger
coverage on its own. The initial scan undercounted ledger markers; it is retained
as v1, and v2 includes all six kinds.

Two future storage choices can preserve complete64-record execution:

1. **Lossless streaming compression:** actual gzip-level1 compressed-byte counts
   of the immutable full traces are191143416 B and79317178 B. The same workload
   extrapolation is about14 GB. This retains every line, including errors and
   unknown future records. It fits current free space in principle if the raw
   stream is never simultaneously written to disk. A future runner must preserve
   process exits, terminal markers and stream hashes, and let each existing
   parser read a fresh decompression stream without materializing the full raw
   trace. At the initial assessment parsers used ordinary `Path.open`;
   compressed readers are now installed with independently checked archive
   equivalence, as recorded in the launch contract above.
2. **Complete audit-event stream:** preserve every occurrence and original order
   of all records listed above, plus simulator error/fatal/termination evidence.
   Measured parser-only size extrapolates to about0.75 GB. This is semantically
   selective logging, not lossless full-log retention. Before adopting it, compare
   complete auditor outputs and ordered record hashes on immutable original and
   selected streams, including fence association, AXI AW/W pairing, complete
   command lifecycle and negative cases. No filtering helper is implemented here.

Neither post-generation compression nor filtering is shown to reduce simulator
execution CPU: the RTL still formats every trace line. Streaming compression
can solve storage pressure, but cannot make the estimated multi-day full64 run
fit the current two-hour launch allowance. A full simulation would need a
separately chosen finite allowance and validated storage path, with all64 records
intact. Existing-record edge simulations remain supplemental, and complete64
hardware correctness remains required regardless of the chosen VCS strategy.
