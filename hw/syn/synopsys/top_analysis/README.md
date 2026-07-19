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

The default candidate set selects `VX_stream_xbar` only. Analyze internal
switches or arbiters in a separate candidate run with the containing xbar
disabled, because selected occurrence paths must remain non-overlapping.
`candidates.small_smoke.yaml` selects one local-memory request xbar from
`small_for_test.sh` and limits PnR to two attempts for framework validation.
