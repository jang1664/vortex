# Naive 256-byte DMA response buffering experiment

Status and final measurements are tracked in `STATUS.yaml` and `results.md`.

## Configuration and routing

The original `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram.sh` is unchanged.
Its L32 copy changes only LMEM ports/banks from 16/16 to 32/32. The D256 copy
additionally selects four DMA cache ports, four L1 memory ports, and opt-in
response reordering. All three retain TH16, 64-bit XLEN, MXU16x16, 32 KiB D-cache,
four D-cache banks, eight platform memory ports, and the existing BRAM choices.

The DMA already supports aggregate widths derived from port counts. D256 uses
4 x 64-byte cache lanes and 32 x 8-byte LMEM lanes. Cache lane `i` still connects
to D-cache request port `i`, with the existing per-port CPU/DMA 2:1 arbitration
where applicable. No DMA routing crossbar is added. Cache-internal bank routing
and the existing HBM adapter are unchanged. L1_MEM_PORTS changes the cache miss
path capacity as well, so this experiment measures the combined configuration,
not an isolated effect of the DMA width alone.

## Why depth alone failed

The original splitter takes the oldest available response from each active lane.
That requires every lane to preserve request order. D-cache can return a later
request first, for example when its hit/miss timing differs from an older request.
Increasing FIFO depth cannot correct this association error.

In the frozen D8/R32 depth-only M4 run, the cache splitter assembled 2,240 wide
responses and consumed 34 lane responses with tags different from their queued
context. At cycle 10,305 context tag 0 consumed lane 0 tag 1; at cycle 10,307
context tag 1 consumed lane 0 tag 0. The local splitter had no mismatched tags.
The application reported 1,937 numerical errors. D16/R32 and D32/R32 also failed.
These runs remain under `runs/d*_r32/m4` for diagnosis and are excluded from
performance selection. `check_response_order.py` reproduces the tag comparison.

## Reorder implementation

`DMA_SPLIT_RSP_DEPTH` controls both external DMA splitters' response storage and
context capacity. Its default is 8. `DMA_SPLIT_RSP_REORDER` defaults to 0 and is
enabled in the D256 configuration. Both defines and parameter overrides are
naive-specific; other splitter users retain their original defaults.

With reordering enabled, each accepted aggregate read allocates a private slot
tag. The context FIFO retains the upstream tag and active-lane mask. Every lane
writes its returned payload into its own `VX_dp_ram`, using the echoed slot tag
as the write address, independently of other lanes' return order. Completion
bits record which lanes have arrived. Only the oldest complete context advances.

The RAM settings follow the existing DMA response-store implementation in
`hw/rtl/core/VX_dma_unit_misal.sv`: `OUT_REG=1`, `LUTRAM=0`, `RDW_MODE="R"`, and
`RADDR_REG=1`. Reading the oldest slot captures payloads in synchronous output
registers together with the restored original tag/mask. The output holds under
backpressure. A new completed context can advance every cycle. A slot is freed
when captured in these output registers, which avoids same-address RAM read/write
dependence and adds one output holding stage beyond the context slots.

Inactive lanes are not issued, need no responses, and produce zero output data.
Writes keep their original tags and do not allocate read contexts. Partial
request acceptance retains the same private tag until all active lanes accept.
Assertions detect unsolicited or duplicate lane responses and read/write
collisions. Request-to-cache lane wiring remains fixed.

The existing transport tag width is preserved. Therefore effective reorder
capacity is `2**min(clog2(DMA_SPLIT_RSP_DEPTH), TAG_WIDTH)`, rather than silently
widening cache interfaces. With R32 in the measured NDEBUG builds, the cache splitter's 6-bit tag caps requested
D128 at 64 slots; DMA itself has only 32 outstanding slots in that configuration.
Tests explicitly exercise a requested depth larger than the tag namespace.
Depth must be a power of two and at least 2. BRAM mapping/resource estimation and
synthesis are outside this simulation experiment.

## Reproduction and evidence

`configs/` here contains frozen, full configuration copies for the experiment.
The seven valid D256 variants are `d8_r32_ordered`, `d16_r32_ordered`,
`d32_r32_ordered`, `d64_r32_ordered`, `d128_r32_ordered`, `d128_r64_ordered`, and
`d128_r128_ordered`. Tests use M=4 and 256, K=N=512, quantization group 32,
direction 0, transpose 0, repeat 1. The naive variants use identical HBM model
geometry, routing, timing inputs, and backend hashes (`hbm_model_identity.json`):
HBM2_2Gbps, 32 pseudo-channels, eight 64-byte kernel ports, 100 MHz logic clock,
and a 300 MHz HBM AXI model input. These are simulation settings, not measured
FPGA clocks or calibrated hardware bandwidth.

From the repository root:

```sh
python3 agent-tasks/naive-dma256-depth/test_split.py
python3 agent-tasks/naive-dma256-depth/run.py d16_r32_ordered
python3 agent-tasks/naive-dma256-depth/collect.py
python3 agent-tasks/naive-dma256-depth/prefetch.py agent-tasks/naive-dma256-depth/runs/d16_r32_ordered/m4
python3 agent-tasks/naive-dma256-depth/check_identity.py
```

The runners configure isolated build directories, source the corresponding
config, and run the project `ci/run_black.sh xrt-vcs-sim` wrapper. Existing
finished evidence is not overwritten by `run.py`; use a new variant/output name
for a new source revision. Per-run manifests contain exact flags, commands,
software/RTL hashes, logs, and FSDB paths. `prefetch.py` batches read-only FSDB
extraction and `analyze.py` samples signals immediately before rising edges.

The standalone splitter suite covers legacy FIFO mode and reordered mode at
depths 8/16/32/64/128 for both 4x64-byte and 32x8-byte geometries. It checks payload,
original tag, mask, lane address, request/response counts, context saturation,
slot wraparound, independently stalled lanes, consumer backpressure, and at
least 16 consecutive output cycles. Additional unmasked and limited-tag-width
cases bring the depth suite to 26. Two non-naive legacy cases and one full-UUID
debug/trace case bring the final suite to 29. Reordered cases assert that reordering was actually
injected, rather than merely enabling the option.

The existing generalized DMA suite separately passes 2,126 functional cases.
Its no-backpressure throughput mode verifies 256 bytes/cycle for 16 consecutive
beats in each direction. See `dma_functional.log` and `dma_throughput.log`.

## Measurement interpretation

Application numerical PASS is required before considering cycle counts.
Selection uses M256 core cycles: choose the smallest response depth within 1%
of the best valid result, then the smallest DMA outstanding-slot count. M4 is
reported separately to expose setup and small-transfer effects.

Aggregate DMA `perf.rd_bytes` increments by the full configured bus width per
response. With lane masking this is not useful payload or physical D-cache
traffic. The analysis also counts byte-enabled request bytes, actual narrow-lane
response bytes, and bus peaks/averages. HBM counters include all clients; they
must not be described as DMA-only. DMA-active and complete GEMM-window rates use
different denominators and are named explicitly.

## Improve preservation

The 570 selected/preprocessed RTL comparisons (debug and NDEBUG) are identical
against the pre-edit snapshot, with only line-derived private instance names
canonicalized. The generic splitter source is excluded because it changes, but
it is uninstantiated in this improve configuration: the core external DMA is
naive-only and `DMA_DCACHE_PORTS=1` selects the direct cache branch. The improve
M4 FSDB hierarchy confirms no external DMA or splitter instances; see
`identity/improve_hierarchy.json`. Parsed inactive-generate references in
`identity/instantiation_check.json` are not elaborated instances.

Prior baseline manifests were checked against the exact pre-edit RTL/software
hashes (`baseline_attestation.json`). Fresh improve M4 and M256 runs match prior
GEMM/core cycles exactly: 6,431/12,205 and 272,856/278,622 respectively.

L16 and improve M256 had already compiled and launched when the user authorized
reordering. Their executables, loaded simulation libraries, runtime, kernel, and
host application were hashed before the source replacement. Their manifests
therefore record subsequent source edits; `collect.py` additionally requires all
captured runtime artifacts and flags to remain identical, and exact prior cycle
identity. This exception is visible in each result's provenance fields. Ordered
D256 runs use frozen source throughout. No improve synthesis is performed.

After all sweeps finished, the helper definition and instantiation were guarded
with `GEMM_NAIVE`, formatting was cleaned up, and an optional `DBG_TRACE_MEM`
trace with an `INSTANCE_ID` label was added. `check_guard_identity.py` compares
the final source with `ordered_measured/VX_mem_bus_split.sv`: the selected logic
tokens are identical after excluding only the unused debug label parameter.
The final source SHA matches the source exercised by all 29 final unit tests.
The delivered D256 config has exactly the flags of the measured selected case.
See `final_application.json`; improve preprocessing was rechecked after this
final application and all 570 comparisons remained identical.
