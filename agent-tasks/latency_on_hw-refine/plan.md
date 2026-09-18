# Refresh FPGA selection and generated workload storage

Date: 2026-09-17 (KST)
Status: implementation and focused verification complete; full measurement campaign running as Slurm job 4935. See [verification.md](verification.md).

Pipeline follow-up: see [pipeline-resume-plan.md](pipeline-resume-plan.md) for the
requested run/refine/compose/prepare/plot orchestration and restart investigation.
That extension is not implemented yet.

## Objective and scope

Make repeated Llama2-7B and Llama3-8B latency/power measurements use a local C1–C4 FPGA selection file. Preserve existing kernel routing and measurement reuse unless explicitly changed, record the hardware actually used, and replace large generated workload YAML files with PKL files.

This document was initially a plan-only deliverable. The user subsequently requested execution of the plan. Implementation, workload generation, and hardware smoke verification have completed; the full campaign is in progress. Existing results and historical aliases remain intact.

## Requested selection

Add `analysis_workspace/latency_on_hw/candidate_fpga_bins.yaml` during implementation:

```yaml
schema_version: 1
candidates:
  C1: tcu_th16_c1_v2
  C2: naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr
  C3: naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr
  C4: improve_th16_tcol16_m16_t8_bigmem_all_bram_spread
```

Resolve these names through `ci/fpga_bin_alias_map.yaml`; do not copy physical bin/config paths into the editable candidate file or repoint global aliases C1–C4.

The existing `resolve_fpga_bin_artifacts(..., require_alias=True)` helper successfully validated all four aliases, config files, manifests, and xclbins during this investigation. The currently resolved image directory identifiers are:

| Candidate | Image directory suffix | Config filename |
| --- | --- | --- |
| C1 | `296f1c41bb` | `tcu_th16_c1.sh` |
| C2 | `3051772acc` | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh` |
| C3 | `c26f196986` | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh` |
| C4 | `051cabe511` | `improve_th16_tcol16_m16_t8_bigmem_all_bram.sh` |

These suffixes describe today's files, not durable hardware identity. Compute and retain full xclbin SHA-256 values when creating a new experiment snapshot. File existence was checked; kernel compatibility and successful execution on these images have not been verified.

## Current behavior and evidence

### Generation, execution, and analysis

1. `make_case.sh` chooses the model/shape matrices and invokes `make_cases.sh`. Its current default remapping is `C4=C4_v3,C3=C3`.
2. `make_cases.sh` expands C1, C2, C3, and C4_fused for prefill and generation, writes per-app/per-bin YAML, and merges by execution bin. C4_alone generation is currently disabled and remains disabled in this scope.
3. `generate_suites.py` uses `resolve_case_fpga_bin()` and existing remapping options. `merge_suites.py` preserves logical cases and groups execution work; `runner.py` deduplicates actual executions.
4. `_run.sh` currently selects `C1 C3 C4_v3`, uses the `C3_C4_v3` suite/output naming convention, and enables latency and power through `run_hw.sh` → `run_fpga_bin.sh` → `tools.latency_bench run`.
5. `run_compose.py` reads generated candidate indexes and raw DBs. Its raw DB subdirectory defaults, and those in `prepare.py`, assume C1/C3/C4. Example wrappers point at several different historical experiment roots.

The existing `_run.sh`-referenced `outputs_llama{2,3}_main.C3_C4_v3.run2` directories contain C1/C3/C4_v3 raw DBs and no C2 raw DB. Representative rows identify the previous images ending in `94c5b39919`, `9600db3a37`, and `64300e5119` respectively.

### Routing is distinct from the candidate name

`suite.py:resolve_case_fpga_bin()` applies this precedence:

`case.fpga_bin` → `by_app` → `by_backend` → `by_kind` → suite default.

The Llama2/Llama3 source suites route ordinary vector kernels to C4. C2 currently combines `sgemm_tcu` measurements from C1, `fpint_gemm_ffn_hw_naive` measurements from C3, and vector measurements from C4. In particular, its `by_app` naive-GEMM entry wins over its `by_backend` entry. Simply mapping the name C2 to a new alias would not schedule work on that image.

**Confirmed user decision:** retain all existing C2 reuse and only register the new C2 mapping. C2 continues to use C1 for TCU GEMM, C3 for naive GEMM, and C4 for vector kernels. Do not change the C2 source-suite routing or schedule separate C2 measurements. Its registered image is available for future use, but must not be represented as the image actually measured for this campaign.

### Hardware provenance exists but is incomplete

- `raw_db.py:RAW_DB_COLUMNS` already includes `fpga_bin_label`, `fpga_bin_dir`, `xclbin_sha256`, run ID, timestamp, Git metadata, latency, and power fields.
- There is no separate `fpga_bin_alias` column in the inspected raw DBs. The CLI currently uses the same string both to resolve the bin and to label the result.
- Runner artifacts include `manifest.json`, suite snapshots, and `fpga_identity.env/json`. Extend these existing artifacts rather than creating a second overlapping stamp system.
- Execution keys and the default skip-existing policy already include xclbin SHA-256. Preserve this protection. The later pipeline audit found that default skip checks do not enforce requested latency/power completeness; see the follow-up design for that gap.
- Composition retains source labels and SHA values, but the normal matching/deduplication columns are app, normalized arguments, and expected bin label. A global optional SHA filter exists; it does not express four distinct candidate identities. A fixed C1–C4 label can therefore select a different image's latest row when multiple revisions are supplied.
- `energy_per_token.py:PowerResolver` matches exact power by label/app/args and can fall back to same-FPGA/app or same-app estimates. New experiment selection must restrict its eligible sources by the recorded hardware identity and distinguish estimates from actual measurements.
- `fpga_clock.py` can use recorded frequency/period fields, then xclbin info files, then a 100 MHz default. Capture the resolved clock and its source for new experiments so later alias edits do not change historical cycle-to-time conversion.

### YAML volume and existing optimization

| Generated tree | YAML files | Total YAML size | Largest merged generation YAML |
| --- | ---: | ---: | ---: |
| `llama2_7b_main_full_v2.C3_C4_v3` | 102 | 560.9 MiB | 205.6 MiB |
| `llama3_8b_main_full_v2.C3_C4_v3` | 102 | 564.5 MiB | 206.0 MiB |

`yaml_io.py` already uses `CSafeLoader`/`CSafeDumper`. The earlier performance investigation in `tools/latency_bench/docs/performance_parallelization_analysis.md` documents that optimization. The remaining format change must cover generation, merge, reload, and runner snapshots; changing only one writer would leave large YAML work elsewhere.

No new runtime benchmark was performed for this plan. PKL speed and size improvements must be measured rather than assumed. `make_cases.sh` also unconditionally dumps model structures to JSON/layout/text, so measure their contribution separately.

## Implementation plan

### 1. Separate routing labels from selected images

Add a small candidate-map loader next to the existing FPGA resolver helpers. Reuse `resolve_fpga_bin_artifacts()` for actual alias/config/manifest/xclbin resolution. Validate schema version, required C1–C4 entries, nonempty alias names, and missing artifacts early.

Preserve logical routing labels C1–C4 in generated suites, filenames, and result subdirectories. Resolve the execution label through the local candidate map only after `resolve_case_fpga_bin()` chooses the source of a measurement. This preserves C4 sharing without confusing the consuming candidate with the FPGA that ran the kernel.

Expose a common `--candidate-map` option for the generation/run entry points that need it; the latency_on_hw wrappers default to the local file. Generic tools without this option retain existing alias/path behavior. Reuse current per-app/backend override facilities, but reject conflicting image remaps in mapped runs rather than stacking the old `C4_v3` remap over the new selection.

At generation time, create a compact resolved experiment snapshot containing the selected aliases, absolute paths, xclbin SHA-256 values, config identity, and selection digest. Carry the snapshot reference/identity through generated indexes and suite metadata. Keep per-case data compact: do not repeat the full four-bin map in every case.

At run time, check the selected image against that snapshot. If the live candidate map, alias resolution, or image contents changed, report the mismatch before measurement; create/regenerate a new experiment instead of silently rebinding an old suite. Historical composition reads the saved snapshot, never today's candidate map. A selection digest identifies configuration, while run ID identifies a measurement attempt; neither replaces xclbin identity.

### 2. Add actual-image provenance to existing results

Retain `fpga_bin_label` as the execution source label for mapped runs, and add the resolved alias separately. For example, a C1 vector contribution should identify consumer C1 in its logical/composed context, execution source C4, and C4's actual alias/path/SHA in measurement provenance.

| Artifact | Information to retain/add |
| --- | --- |
| Generated `index.yaml` / resolved snapshot | Candidate selection, digest, source inputs/overrides, per-source alias/config/bin/xclbin identity, serialization format/version |
| Run `manifest.json` | Execution label, resolved alias, bin/xclbin/config paths, xclbin/config digests, selection digest, clock value/source, existing run/device metadata |
| `raw_db.csv` | Existing label/bin/SHA fields plus `fpga_bin_alias`, selection digest, and recorded clock/provenance fields needed for standalone interpretation |
| Composed and prepared CSVs | Consumer candidate, actual source label/alias/path/SHA, selected run, and measured/reused/interpolated/imputed status |

Use the existing raw DB schema-upgrade mechanism for additive columns. Extend both incremental raw writes and final reporting so retries/live updates retain the same metadata. Historical rows remain readable with unknown alias metadata; never backfill a historical alias by resolving a label against today's map.

Before composition deduplicates or chooses the latest measurement, filter by the expected per-execution-source xclbin identity from the saved snapshot. Apply the same identity boundary to power resolution, interpolation inputs, and related source selection. Preserve reuse/estimation algorithms within the selected experiment; do not allow old revisions into fallback pools. Keep the source identity of an imputed power value explicit.

### 3. Replace large generated artifacts with PKL

Introduce a shared suite payload I/O helper and retain existing suite parsing/validation, canonicalization, matrix override, and case reconstruction logic.

- Keep human-authored suite/config YAML and small `index.yaml` metadata.
- Default latency_on_hw generated and merged workloads to `.pkl`; retain YAML read support for historical artifacts and explicit YAML export for inspection.
- Serialize a versioned envelope containing the existing plain-data expanded-suite payload and metadata. Avoid pickling live `BenchSuite` class instances, which bind stored data to Python module/class layout.
- Dispatch readers by declared format/suffix, open PKL in binary mode, and validate envelope/schema after loading. Use PKL only for locally generated trusted artifacts. Fail clearly on unsupported/corrupt payloads; do not regenerate or reinterpret them silently.
- Write using a temporary sibling file and atomic replacement. Keep the old valid file available if generation fails.
- Route `generate_suites.py`, `merge_suites.py`, and `suite.py` through this helper. Add an explicit output-format option; latency_on_hw wrappers select PKL without forcing every unrelated consumer to change defaults.
- Update `runner.py:write_suite_snapshots()` and snapshot publication lists. PKL runs produce PKL expanded snapshots, including effective warmup/iteration overrides and filtered cases, without converting back to large YAML. Existing YAML streaming-copy behavior remains available for legacy input.
- Prefer index-driven discovery in `make_cases.sh`, `run_hw.sh`, `run_fpga_bin.sh`, and `prepare.py`. `run_compose.py` already discovers suite paths through indexes; update schema/metadata handling while preserving relocated-index behavior.
- Make cleanup/overwrite aware of both formats and of exactly which artifacts the index owns. Mixed stale YAML/PKL files must not cause duplicate execution or accidental selection of old suites.
- Keep optional interpolation probe YAML and other small diagnostic files unless they participate in a large serialization path. Inspect affected consumers before widening the conversion.

### 4. Connect the Llama wrappers and analysis

Update `make_case.sh` and `_run.sh` to use the new candidate map and one explicit experiment root/tag rather than hand-edited version labels spread across scripts. Preserve current full/quick shape settings, decode sampling, C4_fused selection, power duration/idle policy, retries, and stage filters.

Discover execution bins from the generated merged index. Under the confirmed reuse policy, those remain C1/C3/C4 despite all four mappings being registered. Make raw-DB discovery in composition reflect those generated execution sources; do not require a C2 raw DB.

Update the supported README and generation/run/compose/prepare examples together. The separate legacy `run_power.sh`/`measure_power.py` path should either receive the same map option when used for this campaign or be clearly documented as a separate legacy flow; do not accidentally run its old hard-coded aliases. Keep unrelated historical wrapper scripts intact.

Use new generated/output/composed roots for the first campaign. Existing roots remain reproducible and must not be relabeled or overwritten to appear to use new hardware.

### 5. Verify before a full measurement campaign

Extend existing focused tests rather than building a parallel test framework:

1. **Mapping/routing:** verify all requested aliases resolve correctly, precedence is unchanged, ordinary vector cases still execute on C4, and C2 continues to reuse C1/C3/C4 with no C2 execution group. Compare logical case IDs, arguments, shapes, multiplicity, and decode reuse anchors before/after format conversion.
2. **Identity isolation:** use fixtures with identical labels/app/args and different SHA values. Verify run resume, latency composition, power selection, and interpolation cannot reuse the wrong revision. Test same-alias replacement, map edits after generation, legacy rows, and an older experiment composed after the live map changes.
3. **PKL parity:** generate/load/merge equivalent YAML and PKL suites, compare reconstructed cases/defaults/metadata, and verify overrides, filters, execution counts, snapshot contents, schema failures, and index relocation. Include both prefill and sampled generation.
4. **Wrapper dry run:** generate a bounded Llama2/Llama3 matrix and inspect selected labels, aliases, config paths, per-bin output directories, planned commands, and provenance. No board programming in this step.
5. **Performance:** benchmark current C-YAML versus PKL on the same quick input and a representative full generation workload. Record expansion, serialization, merge read/write, snapshot time, peak memory, file sizes, and case/execution counts separately. Require identical semantics and a measured reduction in serialization/load cost; report remaining model-structure dump costs.
6. **Hardware smoke test, in the later implementation/measurement phase:** configure a build directory with `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`; use the resolved alias config and the project's `ci/run_black.sh hw --fpga-bin ALIAS`/Slurm flow through the existing harness. Use `run-bb-common` when executing. Add no extra compile defines unless requested. Exercise TCU GEMM, naive GEMM, improve GEMM, and reused/fused vector cases on their selected images. Check compile-profile compatibility for the new thread/tile/memory configurations, correctness status, cycle/clock availability, and valid latency/power samples.
7. After smoke checks, run the intended Llama2/Llama3 prefill/generation matrices in fresh roots, compose results using the captured experiment snapshot, and check missing measurements, completeness, actual source identities, and energy provenance before plotting.

Relevant existing tests include `test_fpga_bin_aliases.py`, `test_generate_suites.py`, `test_merge_suites.py`, `test_suite_snapshots.py`, `test_cli_run.py`, `test_raw_db.py`, `test_compose.py`, `test_interpolation.py`, and the latency_on_hw composed-pipeline/energy tests.

## Acceptance criteria

- Editing one local C1–C4 mapping file is sufficient to select the next FPGA set through the supported workflow.
- C2 is registered but continues to reuse C1/C3/C4 measurements; C4 vector reuse and existing workload semantics are preserved.
- Every new measurement and composed contribution can be traced to its actual alias, image path, xclbin SHA, and experiment snapshot.
- Old/new revisions cannot silently mix in skip-existing, composition, or power estimation, even when labels or alias names are reused.
- Large generated/merged/run snapshot payloads use PKL end to end; legacy YAML inputs remain readable.
- Format conversion preserves cases, execution deduplication, sampling/reuse, and effective run options, with measured performance evidence.
- Existing measurement archives are unchanged. Hardware measurements are launched only in the later execution phase, not as part of writing this plan.

## Main code references

- [Candidate routing example](../../analysis_workspace/latency_on_hw/suites/llama2_7b/llama2_7b_prefill_C2.yaml)
- [FPGA resolution helpers](../../tools/latency_bench/fpga_bins.py)
- [Shared suite loader and routing](../../tools/latency_bench/suite.py)
- [Generation](../../tools/latency_bench/generate_suites.py) and [merge](../../tools/latency_bench/merge_suites.py)
- [Runner and snapshots](../../tools/latency_bench/runner.py), [raw DB](../../tools/latency_bench/raw_db.py), [composition](../../tools/latency_bench/compose.py)
- [Power resolution](../../analysis_workspace/latency_on_hw/energy_per_token.py)
- [Prior serialization performance investigation](../../tools/latency_bench/docs/performance_parallelization_analysis.md)
