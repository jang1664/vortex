# Selective-PnR Top Analysis

This flow combines one `Vortex_axi` DC topographical synthesis with ICC2 PnR
of selected interconnect-heavy elaborated designs. The result is explicitly a
**selective-PnR estimate**, not a final silicon-area result.

Run from the Vortex repository root after sourcing the desired configuration:

```bash
source configs/small_for_test.sh
PYTHONPATH=third_party/hwexplorer \
  python hw/syn/synopsys/top_analysis/run.py \
    --config configs/small_for_test.sh \
    --run-dir build/hw/syn/synopsys/top_analysis/Vortex_axi_small_for_test \
    --stages top,blocks,pnr,report
```

`--config` accepts either a repository-relative or absolute config script
path. Its filename stem becomes the default run tag, so different config files
produce separate directories under `build/hw/syn/synopsys/top_analysis/`.

The two TH16/TCOL32 analyses can be launched independently as follows:

```bash
source configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh
PYTHONPATH=third_party/hwexplorer \
  python hw/syn/synopsys/top_analysis/run.py \
    --config configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh

source configs/improve_th16_tcol32_hwexp_dcache.sh
PYTHONPATH=third_party/hwexplorer \
  python hw/syn/synopsys/top_analysis/run.py \
    --config configs/improve_th16_tcol32_hwexp_dcache.sh
```

Their default run directories are respectively:

```text
build/hw/syn/synopsys/top_analysis/Vortex_axi_naive_gemm_th16_tcol32_hwexp_dcache_hbw
build/hw/syn/synopsys/top_analysis/Vortex_axi_improve_th16_tcol32_hwexp_dcache
```

For the bounded one-xbar framework smoke, add:

```bash
--candidate-config hw/syn/synopsys/top_analysis/candidates.small_smoke.yaml
```

The top stage emits a reusable design catalog and elaborated DDC. The blocks
stage reuses both artifacts, deduplicates equal parameter specializations, and
records represented instance multiplicity. The PnR stage brackets the
clean/failing area boundary by halving or doubling the DC-derived core area,
then bisects that bracket until its relative width reaches the configured
tolerance. Tool/setup/report failures stop the search.

Every attempt has a unique directory and `pnr_result.json`. Aggregate JSON,
CSV, and Markdown reports are written under `RUN_DIR/reports/`. Only DRC-clean,
fully parsed PnR results contribute to the central correction. Failed blocks
remain visible as DC-only/unmodeled contributions.

Use `--resume` to keep completed stages and attempts, `--reuse-top PATH` to use
an existing compatible top run, and `--pnr-job-id ID` to limit a smoke run to
one block specialization. Candidate and search policies live in
`candidates.yaml`; CLI search arguments override that file and are recorded in
`resolved_config.json`.

`target_utilization: from_report` and `aspect_ratio: from_report` use the
worker DC topographical area report as the starting floorplan policy. An area
scale of `0.5` halves core area while preserving aspect ratio, so each core
dimension changes by `sqrt(0.5)`, not by `0.5`. For example, an ICC2 die of
`141.4 x 141.7 um` has an area of about `20,036 um^2`.

The default `bracket_bisection` policy starts at scale `1.0`. A clean result
probes `1/2`, `1/4`, and so on until a failure is found; a failed result probes
`2`, `4`, and so on until a clean result is found. It then uses the midpoint of
the largest failed and smallest clean scales. The smallest known clean result
is selected for aggregation.

The report can be regenerated without launching DC or ICC2:

```bash
PYTHONPATH=third_party/hwexplorer \
  python hw/syn/synopsys/top_analysis/run.py \
    --config configs/small_for_test.sh \
    --run-dir build/hw/syn/synopsys/top_analysis/Vortex_axi_small_for_test \
    --report-only
```

The default candidate set selects coarse-grained xbar, memory arbiter,
switch, AXI mux/demux designs, and `VX_gemm_tree_v1`. It intentionally omits
their internal `VX_stream_arb`, `VX_demux`, and primitive arbiter designs so
selected occurrence paths remain non-overlapping and the flow does not spend
PnR time on small implementation details. `VX_stream_xbar` and
`VX_gemm_tree_v1` are required matches; the remaining types are optional
because their presence depends on the RTL configuration.
`candidates.small_smoke.yaml` selects one local-memory request xbar from
`small_for_test.sh` and limits PnR to two attempts for framework validation.
See `CANDIDATE_HIERARCHY.md` for observed instance paths, specialization
counts, parameter deduplication examples, and the expected naive/improve GEMM
hierarchy difference.

## Fast subdesign synthesis and PnR

`run_subdesign_pnr.py` is the fast path for experiments that do not need a new
top-level synthesis. It reuses a completed top run's
`results/design_catalog.tsv` and `results/Vortex_axi.elab.ddc`, resolves the
C3/C4 hierarchy rules in `subdesign_candidates.yaml`, synthesizes every
selected subdesign, and only then starts the PnR searches.

If `--seed-run-dir` is omitted, the driver creates `RUN_DIR/top` and runs the
catalog-only DC mode once. That mode elaborates the top and emits the catalog
and elaborated DDC while intentionally skipping `compile_ultra`; the generated
artifacts are then used by the subdesign workers in `RUN_DIR/blocks`.

For example, after sourcing the matching configuration:

```bash
source configs/improve_th16_tcol32_hwexp_dcache.sh
PYTHONPATH=third_party/hwexplorer \
  python hw/syn/synopsys/top_analysis/run_subdesign_pnr.py \
    --alias C4 \
    --seed-run-dir build/hw/syn/synopsys/top_analysis/Vortex_axi_improve_th16_tcol32_hwexp_dcache/top
```

Use `--config PATH` instead of `--alias` when an alias is unavailable. Use
`--dry-run` with an existing seed to inspect the resolved selectors without
invoking EDA tools, or
`--stages pnr` to resume PnR from an already completed subdesign synthesis.
The target file keeps C3 and C4 rules independent so C1/C2 can be added as new
family entries without changing the driver.

Block-specific synthesis constraints are configured with `block_constraints`
in the candidate YAML. The default configuration uses this to map
`VX_gemm_tree_v1` to `clk_i/resetn_i` and the selected AXI blocks to
`clk_i/rst_ni`, instead of inheriting the `Vortex_axi` top-level `clk/reset`
names. A block with no physical clock or reset port should use an empty clock
name (and clear `switching_activity`); the synthesis constraint template then
creates a virtual clock for its input/output timing constraints.

Whether a parameter specialization needs CTS is decided from the mapped
implementation, not from RTL syntax. Each synthesis worker writes
`results/<design>.clock_characterization.tsv` and records the result in
`hierarchical_manifest.json`:

- `clocked`: at least one physical clock sink exists; run the normal CTS flow.
- `clockless`: there are no mapped sequential cells and no physical clock
  sinks; preserve the timing period with a virtual PnR clock and route directly
  from `place_opt`, bypassing CTS.
- `invalid`: mapped sequential cells exist but no physical clock sinks are
  constrained; stop before PnR so a missing or incorrect block constraint is
  fixed instead of silently treating the block as combinational.

This classification is per deduplicated, parameter-resolved synthesis job, so
different specializations of the same RTL module may select different PnR
paths. Older synthesis directories without the characterization file are
handled conservatively from the mapped area report and generated PnR SDC.
