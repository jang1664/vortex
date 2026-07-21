# Selective-PnR Top Analysis Implementation Plan

## 1. Objective

Build a Vortex top-analysis flow that estimates routing-aware top-level area
without running full-chip place and route for a large `Vortex_axi`
configuration.

The flow will:

1. Run one Design Compiler topographical synthesis of `Vortex_axi` and retain
   the top reports, hierarchy catalog, elaborated DDC, and mapped DDC.
2. Synthesize and place-and-route selected interconnect-heavy subdesigns such
   as xbars, switches, muxes, and demuxes.
3. Combine the top DC report with the successfully routed block results to
   produce a selective-PnR-adjusted area estimate.
4. Report the modeled coverage and all failed or unmodeled blocks explicitly.

The result is an estimate, not a replacement for full-top PnR. Output reports
must use the term `selective-PnR estimate` and must not label the result as
final silicon area.

## 2. Scope and Non-Goals

### In scope

- A reusable stage-based driver under `hw/syn/synopsys/top_analysis/`.
- A small synthesis-only Vortex configuration at
  `configs/small_for_test.sh` for initial framework validation.
- Reuse of the existing Vortex RTL/configuration/SRAM setup.
- Module, elaborated-design, and instance-based candidate selection.
- Parameter-specialization deduplication and instance multiplicity.
- Bounded PnR retries with progressively larger floorplans.
- Structured DC and ICC2 report parsing.
- Logical-cell, physical-cell, and hybrid-core area estimates.
- Machine-readable provenance and per-block status.

### Out of scope for the first implementation

- Vortex functionality simulation for `small_for_test.sh`.
- Root-causing or fixing xbar routing DRC failures.
- Proving that an nt1 or nt2 configuration is functionally valid.
- Full-top ICC2 PnR for a large Vortex configuration.
- Signoff-quality area correlation.
- Automatic pin placement inferred from parent-level physical connectivity.
- Direct extraction of mapped child designs from the final top mapped DDC.

DRC investigation is intentionally deferred to a separate task. This
framework must preserve enough attempt-level reports to support that future
debugging task.

## 3. Key Design Decisions

### 3.1 Start with a synthesis-only small configuration

Initial EDA validation will use `configs/small_for_test.sh`, not nt1 or nt2.
The configuration will be derived conservatively from `configs/base_t8.sh`:

- one cluster;
- one core;
- a small, legal thread count;
- data cache disabled;
- a minimal memory-bank configuration that still elaborates interconnect
  structures;
- optional accelerator features disabled unless required to elaborate
  `Vortex_axi`;
- memory depths selected only from supported compiled-SRAM choices.

The exact defines will be checked during implementation against RTL parameter
constraints and the compiled SRAM inventory. The initial acceptance criterion
is DC synthesis completion and valid output reports. No blackbox or functional
simulation is required for this configuration.

Before every synthesis run, the driver must source the selected file under
`configs/` and use its `CONFIGS` value as the source of truth.

### 3.2 Bound PnR area search attempts

Each physical specialization starts from the DC report-derived area and uses
bounded bracketing plus bisection to find the minimum clean area:

```text
strategy: bracket_bisection
max_attempts: 10
initial_area_scale: 1.0
bracket_factor: 2.0
relative_area_tolerance: 0.02
min_area_scale: 0.25
max_area_scale: 4.0
```

For a clean initial result followed by a failing half-area result, attempts
begin as follows:

```text
1.0 (clean), 0.5 (failed), 0.75, 0.625, ...
```

The search keeps the largest failed and smallest clean scales and stops when
`(clean - failed) / clean` reaches `relative_area_tolerance`. The exact attempt
sequence and termination reason are recorded. The driver rejects invalid
bounds, tolerance, bracket factor, and `max_attempts < 1`.

Retry behavior is per synthesis specialization:

1. Generate a new `PhysicalVariant` and unique run directory for the attempt.
2. Use DC report-derived utilization and aspect ratio, changing core area
   while preserving aspect ratio.
3. Run PnR and parse the final result.
4. Halve or double area until clean and failed results bracket the boundary.
5. Bisect the bracket until the relative area tolerance is met.
6. Stop after `max_attempts`, even if the boundary has not converged.

Default success policy:

- ICC2 route and write-data stages completed;
- final result reports exist and parse successfully;
- final signal-routing DRC count is zero.

A routing-DRC failure is retryable. Missing inputs, invalid configuration,
tool startup failure, or malformed reports are infrastructure failures and do
not become larger-area retries by default.

If no attempt succeeds:

- mark the specialization `drc_failed`;
- retain every attempt directory and report path;
- continue with other independent specializations;
- exclude it from the trusted central area correction;
- list its DC-only contribution and failed-attempt observations separately in
  the final report.

The framework will not diagnose why a DRC persists. That work is explicitly a
future task.

### 3.3 Prevent nested area double counting

Selected occurrence paths must form a non-overlapping hierarchy set. A parent
block and one of its descendants cannot both contribute to the aggregate.

For example, selecting a `VX_stream_xbar` occurrence excludes an internal
`VX_stream_arb` occurrence from independent aggregation. The planning stage
must fail before EDA execution when selected paths have an ancestor/descendant
relationship, unless one path is explicitly marked diagnostic-only.

### 3.4 Keep area metrics separate

The flow must not directly add a PnR die rectangle to DC logical cell area.
Reports will distinguish:

- DC logical total cell area;
- DC physical cell area;
- DC topographical core area and utilization;
- final ICC2 cell area;
- final ICC2 core and die area;
- PnR-adjusted logical and physical cell estimates;
- hybrid physical/core estimate.

## 4. Proposed User Interface

### 4.1 Driver

```bash
python hw/syn/synopsys/top_analysis/run.py \
    --config configs/small_for_test.sh \
    --stages top,blocks,pnr,report
```

Expected operational options:

```text
--alias NAME
--config PATH
--run-dir PATH
--stages top,blocks,pnr,report
--resume
--reuse-top PATH
--candidate-config PATH
--max-pnr-attempts N
--initial-area-scale FLOAT
--bracket-factor FLOAT
--relative-area-tolerance FLOAT
--min-area-scale FLOAT
--max-area-scale FLOAT
--pnr-job-id ID
--report-only
```

`--alias` and `--config` are mutually exclusive. CLI retry options override
the candidate configuration and are saved in the resolved run configuration.

### 4.2 Candidate configuration

Proposed file:

```text
hw/syn/synopsys/top_analysis/candidates.yaml
```

Example:

```yaml
include:
  modules:
    - pattern: VX_stream_xbar
      required: true
    - pattern: VX_mem_arb
    - pattern: VX_lsu_mem_arb
    - pattern: VX_mem_switch
    - pattern: VX_lmem_switch
    - pattern: VX_tmem_switch
    - pattern: axi_mux
    - pattern: axi_demux
    - pattern: VX_gemm_tree_v1
      required: true

exclude:
  instances: []

minimum_total_area_um2: 1000.0
allow_nested: false

pnr:
  strategy: bracket_bisection
  max_attempts: 10
  initial_area_scale: 1.0
  bracket_factor: 2.0
  relative_area_tolerance: 0.02
  min_area_scale: 0.25
  max_area_scale: 4.0
  target_utilization: from_report
  aspect_ratio: from_report
  boundary_margin: 1.0
  width_grid: 0.1
  height_grid: 0.1
  max_routing_drc_errors: 0
```

Patterns that match no catalog design are recorded as unmatched candidates but
do not fail a run unless marked `required`. The default list names
coarse-grained parent modules instead of wildcard-matching internal stream
arbiters, demuxes, and primitive arbiters; this avoids nested hierarchy area
double counting and low-value PnR jobs.

## 5. Stage Architecture

### 5.1 Top stage

Refactor the reusable Vortex setup from
`hw/syn/synopsys/run_syn_vortex_axi.py` into a common module rather than
duplicating source enumeration, define replacement, and SRAM selection.

The top configuration will use:

```python
synthesis_mode="top"
generate_design_catalog=True
```

Required artifacts:

```text
top/flow.json
top/results/design_catalog.tsv
top/results/Vortex_axi.elab.ddc
top/results/Vortex_axi.mapped.ddc
top/reports/14_Vortex_axi.mapped.area.rpt
top/reports/12_Vortex_axi.mapped.timing.rpt
top/reports/18_Vortex_axi.mapped.power.rpt
```

The stage is complete only when the mapped DDC, area report, and design
catalog are non-empty and parse successfully.

### 5.2 Block planning and synthesis stage

1. Read the top catalog.
2. Resolve optional module/design/instance candidate patterns.
3. Compute total occurrence area from the top hierarchy report.
4. Remove candidates below `minimum_total_area_um2`.
5. Validate non-overlapping occurrence paths.
6. Deduplicate identical template/parameter/constraint contexts.
7. Reuse the top elaborated DDC and existing catalog.
8. Synthesize only the selected specializations with ICC2 handoff enabled.

The first implementation will use the existing elaborated-DDC worker compile
flow. Direct mapped-top child extraction is a later optimization because its
constraint and design-object behavior requires EDA validation.

### 5.3 PnR stage

For each synthesis specialization:

1. Read its DC physical cell area, topographical utilization, and aspect ratio.
2. Generate an attempt-specific `AreaUtilizationPolicy`.
3. Run ICC2 through route optimization and write data.
4. Generate and parse final QoR, utilization, design/floorplan, congestion,
   timing, and routing-DRC reports.
5. Apply the bounded retry policy from Section 3.2.
6. Write a specialization result after every attempt so interruption is
   resumable.

Attempts for different specializations may be executed independently in a
future parallel mode. The first implementation will default to sequential
execution to simplify license and failure handling.

### 5.4 Report stage

The report stage consumes artifacts only and must not launch EDA tools. It can
be rerun after parser or aggregation changes.

Expected outputs:

```text
report/resolved_config.json
report/top_summary.json
report/block_results.json
report/block_results.csv
report/selective_pnr_summary.json
report/selective_pnr_summary.md
```

## 6. Area Aggregation Model

The first implementation uses ratios from each standalone worker to correct
the occurrence area observed in the top synthesis context.

For specialization `i`:

```text
Dlog_i  = worker DC logical cell area
Dphys_i = worker DC physical cell area
Pcell_i = successful final ICC2 cell area
Pcore_i = successful final ICC2 core area
growth_i = Pcell_i / Dphys_i
```

For occurrence `j` of specialization `i`:

```text
Hlog_j = logical global cell area from the top hierarchy report
Hphys_j_est = Hlog_j * Dphys_i / Dlog_i
```

PnR-adjusted logical cell area:

```text
AdjustedLogicalCellArea =
    TopLogicalCellArea
  + sum(Hlog_j * (growth_i - 1))
```

PnR-adjusted physical cell area:

```text
AdjustedPhysicalCellArea =
    TopPhysicalCellArea
  + sum(Hphys_j_est * (growth_i - 1))
```

Hybrid core estimate:

```text
ScaledPnRCore_j = Pcore_i * Hphys_j_est / Dphys_i

HybridCoreArea =
    TopDCCoreArea
  - sum(Hphys_j_est / TopDCUtilization)
  + sum(ScaledPnRCore_j)
```

Only `success` PnR results contribute to the central adjusted estimates.
Failed results are reported diagnostically and remain DC-only in the central
estimate.

The report must include:

```text
modeled_physical_area_coverage =
    sum(Hphys_j_est for successful occurrences) / TopPhysicalCellArea
```

Low coverage is not an error, but it limits the interpretation of the hybrid
estimate and must be prominent in the Markdown summary.

## 7. Required hwexplorer Extensions

### 7.1 Reuse an existing hierarchy catalog

Current hierarchical orchestration always launches a catalog run. Add a
validated input path that allows the block flow to consume an existing catalog
and elaborated DDC from the top stage without repeating analysis/elaboration.

Proposed behavior:

- both catalog and elaborated DDC must exist;
- catalog header and rows must validate;
- the configured top name must match the catalog/top DDC context;
- the manifest records the reused absolute paths;
- absence of this option preserves current behavior.

### 7.2 Extend DC area metadata

Extend `SynopsysDCAreaDB` to parse:

```text
Total moveable cell area
Total fixed cell area
Total physical cell area
Physical core boundary, when present
```

Keep the existing hierarchy table and logical-area metadata compatible.

### 7.3 Generate final ICC2 result reports

The PnR template must write stable, stage-specific files from the final routed
block before abstract/frame generation changes the reporting context:

```text
rpts_icc2/route_opt.report_qor
rpts_icc2/route_opt.report_utilization
rpts_icc2/route_opt.report_design
rpts_icc2/route_opt.report_congestion
rpts_icc2/route_opt.report_timing.max
rpts_icc2/route_opt.report_timing.min
rpts_icc2/write_data0.drc.rpt
```

Do not depend on incidental informational lines in `logs_icc2/*.log` for final
area calculation.

### 7.4 Add a typed PnR result parser

Proposed model:

```python
class PnRResult(BaseModel):
    job_id: str
    attempt: int
    status: Literal[
        "success",
        "drc_failed",
        "tool_failed",
        "report_incomplete",
    ]
    cell_area: float | None
    core_area: float | None
    die_area: float | None
    utilization: float | None
    setup_wns: float | None
    hold_wns: float | None
    routing_drc_errors: int | None
    congestion_peak: float | None
    report_paths: dict[str, str]
```

Parsing and result serialization belong in hwexplorer because they are
Synopsys-flow functionality, not Vortex-specific policy.

### 7.5 Preserve existing APIs

The following existing behavior must remain compatible:

- top-only synthesis;
- catalog-driven submodule synthesis;
- module/design/instance selectors;
- parameter and constraint deduplication;
- static physical variants;
- `from_report` utilization policy;
- manifest-driven PnR;
- routing DRC validation.

## 8. Vortex-Specific Implementation

### New files

```text
configs/small_for_test.sh
hw/syn/synopsys/vortex_axi_common.py
hw/syn/synopsys/top_analysis/__init__.py
hw/syn/synopsys/top_analysis/config.py
hw/syn/synopsys/top_analysis/candidates.yaml
hw/syn/synopsys/top_analysis/run.py
hw/syn/synopsys/top_analysis/aggregate.py
hw/syn/synopsys/top_analysis/report.py
hw/syn/synopsys/top_analysis/README.md
hw/syn/synopsys/top_analysis/tests/
```

### Modified Vortex files

```text
hw/syn/synopsys/run_syn_vortex_axi.py
```

The existing runner will import the common configuration builder and retain
its current CLI and top-only behavior.

## 9. Test Plan

### 9.1 Tests without EDA tools

- Parse DC reports containing logical and physical area sections.
- Parse ICC2 final utilization, design, timing, congestion, and DRC fixtures.
- Validate halving/doubling bracketing, midpoint generation, relative
  tolerance, and `max_pnr_attempts` limits.
- Verify that DRC failures define the infeasible bracket and infrastructure
  failures stop the search.
- Verify first-success selection and all-attempts-failed status.
- Verify that failed PnR results do not enter the trusted central estimate.
- Verify hierarchy ancestor/descendant collision detection.
- Verify parameter deduplication and instance multiplicity.
- Verify logical, physical, and hybrid aggregation formulas.
- Verify missing/unmatched optional candidate handling.
- Exercise all stages with mocked synthesis and PnR runners.
- Confirm that report-only mode never launches an external process.
- Preserve the existing `run_syn_vortex_axi.py` and hwexplorer test suites.

### 9.2 Synthesis-only EDA validation

Create and source `configs/small_for_test.sh`, then run top DC synthesis.

Required checks:

- source/config parsing succeeds;
- RTL analyze, elaborate, link, and compile complete;
- no fatal or unresolved-reference errors in the DC log;
- mapped DDC exists and is non-empty;
- top area report parses;
- hierarchy catalog exists and contains at least one selectable interconnect
  design;
- elaborated DDC can be reused for one block synthesis worker;
- the worker emits ICC2 handoff files.

No simulation or functional application run is required.

### 9.3 Limited PnR smoke test

After synthesis-only validation:

1. Select one small xbar specialization from the generated catalog.
2. Run at most the configured `max_pnr_attempts`.
3. Verify report generation, search accounting, resume behavior, and final
   status.

A DRC-clean result is desirable but is not required to validate the framework.
If all attempts fail DRC, the smoke test passes only when the framework records
`drc_failed`, stops at the configured limit, preserves the reports, and
produces an incomplete/diagnostic final summary without using that block in
the central correction.

### 9.4 Known-configuration validation

Once the framework passes with `small_for_test.sh`, run it with a known
configuration such as C4 or an existing nt16 top result. Start with one
specialization before enabling the complete candidate list.

## 10. Implementation Phases

### Phase 1: Contracts and fixtures

- Define configuration, attempt, PnR result, and aggregate result models.
- Add representative DC and ICC2 report fixtures.
- Implement formula and area-search policy unit tests first.

### Phase 2: hwexplorer report support

- Add physical fields to the DC parser.
- Enable final route-opt reports.
- Add the typed ICC2 parser and result serialization.
- Add existing-catalog reuse.
- Run the complete hwexplorer automation test suite.

### Phase 3: Vortex configuration reuse

- Extract common Vortex_axi configuration construction.
- Keep the current top runner behavior unchanged.
- Add `configs/small_for_test.sh` and config parsing tests.

### Phase 4: Top-analysis orchestration

- Implement stage selection, artifact validation, resume, and provenance.
- Implement candidate resolution and nested-selection rejection.
- Implement block synthesis and bounded bracket-bisection PnR.

### Phase 5: Aggregation and reporting

- Implement logical, physical, and hybrid models.
- Add modeled-coverage and failure reporting.
- Write JSON, CSV, and Markdown outputs.

### Phase 6: EDA smoke validation

- Source `configs/small_for_test.sh`.
- Run synthesis-only validation.
- Run one bounded xbar area-search PnR smoke test.
- Record all observed tool/report compatibility issues.

### Phase 7: Follow-up optimization

Evaluate direct extraction of mapped subdesigns from the top mapped DDC. Adopt
it only after comparing design identity, constraints, area, and ICC2 handoff
against the standalone worker flow.

## 11. Acceptance Criteria

The first framework implementation is complete when:

1. `small_for_test.sh` completes top DC synthesis and produces valid required
   artifacts.
2. A top catalog can be reused without repeating RTL analysis/elaboration.
3. At least one selected specialization completes block synthesis and ICC2
   handoff generation.
4. PnR retries stop exactly at `max_pnr_attempts`.
5. Persistent DRC failure is represented as `drc_failed` without aborting all
   independent jobs or contaminating the trusted aggregate.
6. Final routed reports are written to stable files and parse into a typed
   result.
7. Nested selected occurrences cannot be double counted.
8. The final JSON, CSV, and Markdown reports reconcile numerically.
9. The summary prominently reports modeled coverage and incomplete blocks.
10. Existing top-only and hierarchical hwexplorer tests remain passing.

## 12. Deferred Questions

The following questions do not block framework implementation:

- Why some xbar specializations remain DRC-dirty as area increases.
- Whether pin placement, routing layers, constraints, or the PnR template cause
  those persistent violations.
- Whether a very small Vortex configuration is functionally meaningful.
- Whether mapped-top child extraction can replace standalone worker synthesis.
- How accurately the hybrid estimate correlates with a future full-top PnR.

Each PnR attempt must preserve the reports needed to answer the first two
questions in a separate debugging task.
