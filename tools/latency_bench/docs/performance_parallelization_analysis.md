# Latency Bench Performance and Parallelization Analysis

Date: 2026-07-29

Implementation update: the P0 centralized C-safe YAML I/O change described below was implemented and verified on 2026-07-29. Post-implementation benchmarks measured 2.033 seconds for the representative generation run, 15.822 seconds for the representative merge, and 9.618 seconds for the representative compose load/compute/write path.

## Executive summary

There is no parallel implementation in the current `tools/latency_bench` code or in its reachable Git history. Searches for `ThreadPoolExecutor`, `ProcessPoolExecutor`, `multiprocessing`, `concurrent.futures`, `joblib`, and pool-style execution found no latency-bench implementation or removed parallel implementation.

The primary bottleneck is not the case-generation arithmetic. It is the repeated parsing and serialization of large expanded suites with PyYAML's pure-Python `SafeLoader` and `SafeDumper`:

- Loading one 12.67 MB, 10,240-case suite took 31.11 seconds with `SafeLoader` and 6.27 seconds with `CSafeLoader` (4.96x faster).
- Dumping the same suite took 16.68 seconds with `SafeDumper` and 5.00 seconds with `CSafeDumper` (3.34x faster).
- A representative `generate-suites` run fell from 7.58 seconds to 1.55 seconds (4.88x faster) when only the dumper was changed.
- A representative 43-input `merge-suites` run fell from 66.40 seconds to 15.33 seconds (4.33x faster) when only the loader and dumper were changed.

The recommended order is therefore:

1. Require LibYAML `CSafeLoader` and `CSafeDumper`.
2. Stop materializing and reparsing very large expanded YAML where possible; introduce a sharded manifest or a faster cache format.
3. Vectorize the remaining row-wise compose resolution.
4. Add bounded process parallelism only at natural file/shard boundaries.

Parallelism can help `generate-suites` and `merge-suites`, but adding it before the first two changes would multiply peak memory while leaving the main format problem intact.

## Scope and repository state

The analysis covered:

- `generate-suites`
- `merge-suites`
- `compose`
- interpolation evaluation and refinement
- the shared suite loader and expanded-suite writer
- estimation and plotting paths related to composition
- Git history for `tools/latency_bench`

The worktree already contained unrelated, uncommitted changes in `compose.py`, `interpolation.py`, and `test_compose.py`. They were inspected but not modified. Those changes concern missing reuse anchors and interpolation measurement overrides; they do not introduce parallelism or materially change the performance conclusions here.

The measurements used Python 3.10.0, pandas 2.3.3, and PyYAML 6.0.3 from the `vortex` conda environment. Temporary output directories were used for write benchmarks.

## Why the workload became large

The generation suites can expand one logical workload into one case per output-token step and kernel. The existing artifacts show the scale difference clearly:

| Artifact set | Generation cases | Expanded YAML bytes |
| --- | ---: | ---: |
| `llama2_7b_main` C1/C2/C3/C4-fused inputs | 13,696 | 16,647,664 |
| `llama2_7b_main_full` C1/C2/C3/C4-fused inputs | 246,528 | 300,109,046 |

The full set is about 18x larger in both cases and bytes. Its C1 generation directory alone contains 76,032 cases and 92.0 MB of YAML. This linear case expansion is expected for exact decode measurement with a large output-token count, but it makes expanded YAML an expensive intermediate representation.

The relevant history is:

- `5798c072` (2026-06-08), `perf(latency): cache composition and estimation work`, replaced per-case raw DataFrame scans with a key merge and cached estimator fits. This is a serial algorithmic optimization, not parallelization.
- `8fa5026b` (2026-07-28) added output-token-aware canonicalization and decode measurement support.
- `2d8e5218` (2026-07-28) added interpolation evaluation and refinement.
- `6aac6a22` (2026-07-28) added decode reuse/interpolation resolution and related composition metadata.

The July features increased the number of logical rows and the amount of per-row post-processing. However, the measurements below show that YAML parsing and writing still dominate wall time.

## Measurements

### YAML loader and dumper

Input: `generated_suites/llama2_7b_main/generation_merged/generation_merged_C4.yaml`, 12,668,772 bytes and 10,240 cases.

| Operation | Pure-Python safe implementation | LibYAML C safe implementation | Speedup |
| --- | ---: | ---: | ---: |
| Load | 31.107 s | 6.270 s | 4.96x |
| Dump | 16.681 s | 4.995 s | 3.34x |

PyYAML 6.0.3 in the active environment provides both `CSafeLoader` and `CSafeDumper`. The dumped representative document had the same byte length. A production change should still run semantic round-trip and snapshot tests rather than require byte-for-byte formatting identity.

The `vortex` conda environment currently contains `pyyaml 6.0.3` and the defaults-channel LibYAML package `yaml 0.2.5`; `yaml.__with_libyaml__` is true. Reinstall the required packages with:

```bash
conda install -n vortex pyyaml yaml
```

A cProfile run on a larger 30,448,956-byte, 20,736-case suite attributed 155.4 of 164.5 profiled seconds to YAML node composition. Profiling substantially increased absolute time, but the 94% share identifies the bottleneck unambiguously.

### `generate-suites`

Representative input: Llama2-7B C1 generation, batch 1, KV length 1024, 128 output tokens, model-structure dumps enabled. Output: 11 suites, 4,224 cases, 5,023,534 bytes.

| Configuration | Wall time |
| --- | ---: |
| Current `yaml.safe_dump` | 7.580 s |
| `yaml.dump(..., Dumper=yaml.CSafeDumper)` | 1.553 s |

Speedup: 4.88x. No generation logic or output schema was changed in this experiment.

The serial dump loop is at `generate_suites.py:150-167`. Each `(app, fpga_bin)` output is independent and is a valid later process-parallel boundary, but C dumping already removes most of the observed cost for this input.

### `merge-suites`

Representative input: 43 generated Llama2-7B generation YAMLs from C1, C2, C3, and C4-fused; output: 13,696 cases in three FPGA-bin suites.

| Configuration | Wall time |
| --- | ---: |
| Current safe loader/dumper | 66.402 s |
| C safe loader/dumper only | 15.327 s |

Speedup: 4.33x.

The current implementation loads every input serially at `merge_suites.py:123`, constructs a JSON logical key for every case at `merge_suites.py:73-79`, and writes FPGA-bin outputs serially at `merge_suites.py:177-211`.

For the 300 MB full generation input, a merge also retains all parsed suites, the deduplication-key set, grouped case references, and output cases concurrently. Parallel input parsing would further increase this already high peak memory.

### `compose`

Representative input: the 12.67 MB, 10,240-case C4 merged suite and three Llama2 raw databases.

- Current suite load: 32.059 seconds.
- Profiled `compose_latency` after loading: 4.961 seconds.
- Within the profiled compose phase, `_resolve_decode_reuse` consumed 2.528 seconds and `_compose_rows_from_merge` consumed 1.189 seconds.
- With `CSafeLoader`, a non-profiled end-to-end split was 6.981 seconds load, 2.425 seconds compose, and 0.240 seconds CSV output, for 9.645 seconds total.

The baseline end-to-end time is approximately 34.7 seconds when the separately measured non-profiled compose and CSV times are added to the current 32.1-second load. On this input, changing only the loader therefore reduces the practical compose path by about 3.6x.

The June performance commit already removed the former repeated raw-DB scan. The remaining CPU hotspots are now Python/Pandas row iteration and scalar `.at` access:

- `compose.py:266-278` builds case rows in Python.
- `compose.py:379-490` reconstructs rows with `iterrows()` and dictionaries.
- `compose.py:493-577` resolves decode reuse with repeated scalar DataFrame reads and writes.
- `compose.py:580-732` resolves interpolation similarly.

These are better addressed with indexed arrays, precomputed position maps, and vectorized assignment than with threads. A single compose has dependent reuse/interpolation resolution within each logical group, while different groups are independent.

### Interpolation

On the same 10,240-case suite, measurement kinds were:

- 8,890 `invariant_reused`
- 952 `interpolated`
- 248 `bucket_reused`
- 150 `measured`

After a C-loader suite load of 7.148 seconds, finding 952 unresolved interpolation cases took 0.008 seconds and sampling 40 probes took 0.001 seconds. The local interpolation selection math is therefore not a useful parallelization target.

Interpolation refinement does repeat some avoidable work:

- `_raw_metric` rereads raw CSVs in unresolved checks and evaluation calls.
- `evaluate_cases` rebuilds interpolation groups on every invocation.
- `write_refinement_progress` and `write_current_cases` repeatedly recompute refined state and rewrite artifacts.

These should be cached within one command invocation. Ordinary interpolation, composition-time interpolation resolution, error calculation from an existing probe raw DB, and refinement from an existing probe raw DB are offline operations and do not use an FPGA.

Only `evaluate-interpolation` (the interpolation error-measure path) and `refine-interpolation` can launch new measurements, and only when `--measure-command` is supplied. Even then, `run_measurement_command` is a generic subprocess wrapper; FPGA use is determined by the command template. When that template launches a latency-bench FPGA run, measurements must remain serial on one allocated FPGA because programming, XRT context ownership, power collection, and raw DB publication are shared mutable resources. Parallel measurement is appropriate only when the scheduler allocates distinct FPGA devices and each worker has isolated output files, followed by a deterministic merge.

## Parallelization assessment

| Path | Parallel boundary | Recommendation | Main constraint |
| --- | --- | --- | --- |
| `generate-suites` | One output `(app, fpga_bin)` shard | Useful after C dumper; use a bounded process pool | Large `BenchSuite` transfer/copy and peak memory |
| `merge-suites` input | One input YAML file | Potentially useful after C loader | Parsed-object IPC and aggregate memory can dominate |
| `merge-suites` output | One FPGA-bin suite | Useful when there are several large bins | Each worker duplicates serialization state |
| Single `compose` | One interpolation/reuse group | Prefer vectorization; process parallelism is secondary | Group results must preserve row order and dependencies |
| Multi-suite compose | One suite | Good process-parallel boundary | Raw DBs are currently reread; cache/share them first |
| Estimation | One estimator group | Possible, but current caches already remove repeated fits | scikit-learn/BLAS oversubscription and small groups |
| Plotting | One independent figure | Process-only if needed | Matplotlib global state is not thread-safe |
| Offline interpolation analysis | One kernel group | Usually unnecessary; cache repeated inputs first | Analysis takes milliseconds after suite load |
| Error-measure/refine `--measure-command` | One allocated FPGA/device when the template invokes FPGA runs | Do not parallelize measurements on one FPGA | Device, power, and output-state races |

Threads are not recommended around the current pure-Python SafeLoader/SafeDumper because the work is GIL-bound. Processes avoid that limitation but cost substantial memory. The C implementations should be benchmarked first; only residual file-level work should be process-parallelized.

## Recommended changes

### P0: centralize fast safe YAML I/O

Status: implemented on 2026-07-29 in `yaml_io.py` and migrated across all production latency-bench YAML call sites.

Add a small YAML I/O helper and use it consistently from `suite.py`, `generate_suites.py`, `merge_suites.py`, `interpolation.py`, `runner.py`, `canonicalization.py`, and `fpga_bins.py`:

```python
from yaml import CSafeDumper, CSafeLoader, dump, load

def safe_load(stream):
    return load(stream, Loader=CSafeLoader)

def safe_dump(data, stream=None, **kwargs):
    return dump(data, stream=stream, Dumper=CSafeDumper, **kwargs)
```

The direct import intentionally raises `ImportError` when PyYAML was installed without its LibYAML extension. Validate all suite tests, snapshot tests, duplicate handling, scalar typing, aliases, and representative large-suite round trips.

The post-implementation measurements were:

| Path | Original | Implemented | Speedup |
| --- | ---: | ---: | ---: |
| Representative `generate-suites` | 7.580 s | 2.033 s | 3.73x |
| Representative `merge-suites` | 66.402 s | 15.822 s | 4.20x |
| Representative compose load/compute/write | approximately 34.7 s | 9.618 s | approximately 3.61x |

The implementation requires the LibYAML extension. Focused tests verify LibYAML selection, semantic round trips, unsafe Python object-tag rejection, generation, merge, snapshots, aliases, canonicalization, compose, and CLI run behavior.

### P1: avoid giant expanded YAML as the mandatory intermediate

The best structural fix is to preserve shards and merge their manifests logically instead of writing a second fully expanded merged YAML. Options, in descending compatibility order:

1. Add a manifest-backed suite type that references generated shard files and lets `run`/`compose` stream them.
2. Cache parsed expanded cases in Parquet or another typed columnar format keyed by source hashes and loader options, while retaining YAML as the source-of-truth interchange format.
3. Let compose consume the existing generated index files directly and concatenate case tables without a physical `merge-suites` artifact.

This removes both the read and write cost, lowers disk usage, and avoids retaining hundreds of megabytes of YAML object graphs. It also makes file-level parallelism safer because workers can operate on bounded shards.

### P1: reduce exact-decode expansion when exact rows are not required

For performance exploration, use sampled decode measurement and a suitable sample interval. The existing sampled/reuse/interpolation representation reduced the observed Llama2 generation set from 246,528 to 13,696 cases, about 18x. Exact mode should remain available for validation, but it should not be the default workflow for every iteration when interpolation is acceptable.

### P1: vectorize compose decode resolution

Replace DataFrame scalar `.at` loops with a compact case-position table and vectorized copies:

- Precompute group IDs, output-token positions, representative positions, and interpolation lower/upper positions once.
- Store source and power columns in NumPy arrays or use DataFrame joins keyed by representative case ID.
- Compute interpolation ratios and weighted latency in vectorized columns.
- Convert to the final DataFrame once.

This targets the measured residual compose hotspot without adding scheduling overhead or nondeterministic ordering.

### P2: cache immutable command inputs

Within one command invocation:

- Read and normalize each raw DB once.
- Cache canonicalization policies once.
- Cache interpolation groups and raw metric dictionaries.
- In multi-suite compose, pass the prepared raw table to each suite rather than calling `_read_raw_dbs` repeatedly.

This is particularly relevant to `analysis_workspace/latency_on_hw/run_compose.py`, which composes many generated suite files against the same raw DB set.

### P2: add bounded process parallelism

After P0/P1, add an explicit `--jobs` option with a conservative default of 1 and a bounded automatic value. Recommended initial targets:

- `generate-suites`: process independent output shards.
- `merge-suites`: process independent final FPGA-bin writes; consider input parsing only if memory measurements permit it.
- multi-suite compose: process independent suite files after avoiding repeated raw-DB parsing.

Requirements:

- Preserve sorted input and output ordering.
- Write each output to a temporary sibling and atomically replace it on success.
- Aggregate worker errors with the source path included.
- Bound jobs by both CPU and an estimated memory budget, not CPU count alone.
- Set BLAS/OpenMP thread counts to one inside estimation workers to avoid nested oversubscription.
- Add deterministic equivalence tests for `--jobs 1` and `--jobs N`.

## Suggested implementation sequence and acceptance criteria

1. Implement the central C-safe YAML helper and update callers.
   - All latency-bench tests pass.
   - Representative output round-trips are semantically identical.
   - The 43-input merge completes in at most 25 seconds on the measured host.
2. Cache raw DB normalization and interpolation state.
   - Multi-suite compose reads each raw DB once.
   - Interpolation refinement does not rebuild unchanged groups or reread unchanged CSVs per iteration.
3. Vectorize decode reuse/interpolation resolution.
   - The 10,240-row `compose_latency` phase falls below 1 second on the measured host.
   - Existing reuse, interpolation, missing-policy, and power-copy tests remain unchanged.
4. Introduce manifest-backed or cached parsed suites.
   - Full generation merge no longer needs to create another approximately 300 MB expanded YAML artifact.
5. Add opt-in bounded process parallelism and benchmark `--jobs 1`, `2`, and `4`.
   - Parallel output is deterministic and semantically identical.
   - Peak RSS is recorded and stays within a documented limit.
   - Parallel mode is retained only where it improves wall time after P0-P1.

## Conclusion

A parallelization change is possible, but it is not the highest-value first change. The current code has no latent or removed parallel path to re-enable. The measured bottleneck is pure-Python YAML processing amplified by exact-decode suite expansion. Switching to C-safe YAML immediately provides roughly 3-5x improvement with a narrow change. Avoiding giant expanded YAML and vectorizing compose should follow. Bounded process parallelism should then be applied only to independent suite shards and files. Offline interpolation remains CPU/file work; only error-measure or refinement commands whose `--measure-command` template launches an FPGA run are subject to the single-FPGA serialization constraint.
