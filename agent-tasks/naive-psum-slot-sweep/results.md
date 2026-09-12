# PSUM slot sweep evidence

The fixed reference is commit `24b83bf2`: mandatory prefetch reservation at
Input admission, 16 tagged adapter read/data slots, 16 physical response
assembly slots, and a two-entry response transport FIFO.

## Method

Only `VX_gemm_node_naive.sv` has changed: two naive-only compile settings
replace the hard-coded capacities, both defaulting to 16. The sweeps set
both capacities to 32 or both to 64. All other pipeline, DMA, and memory
settings stay fixed. The source is stable across both independent builds.

`run.py --slots 32` and `run.py --slots 64` invoke the established ordinary
xrt-vcs-sim runner in separately configured build directories. Each runs
M4 followed by M256, K=N512, QBLK32, QCOL, WT0. The first case rebuilds the
simulator, and the second reuses it. Waveforms are disabled. The runner
records exit codes, source hashes, observer/core cycles, and deterministic
`tools/verify_rtl.py` pass/failure checks.

The actual vlogan command at line 231 in each M4 wrapper log contains both
requested slot defines. This confirms the larger settings reached RTL
compilation, independently of the recorded manifest.

## Default and improve preservation

`check-defaults.py` compares HEAD/current preprocessing for naive default16
and improve, each with PERF off/on. All four comparisons pass; improve
preprocesses the changed module to empty. Other tracked RTL is unchanged.
Normalization removes blank/source-location lines and the existing helper
names generated from source line numbers only. No synthesis was performed.
This permits reusing the previous passing 16-slot measurements as reference.

## Capacity bounds

For this no-SLR TH16/MXU16 configuration, the common core's
`PIPELINE_OWNERSHIP_BOUND` evaluates to 19:
`1 + 1 + 3 + 6 + 4 + 4`. The core asserts its accepted-but-not-retired
transaction count stays within that bound. This is a conservative RTL bound,
not a measured occupancy. The adapter's transaction table remains 64 entries.
Both slot counts must be powers of two. The existing minimum base tag width
under NDEBUG is six bits, which accommodates 64 slots without changing shared
interface widths.

## Results

All four new runs pass with zero wrapper/runner exit codes, no strict failure
markers, and no source changes. Every source hash was checked against the
final worktree. The 32/64 runs have identical source snapshots and app
arguments; their only config differences are the two slot overrides.

| Adapter read/data slots | Physical response slots | M4 GEMM | M4 core | M256 GEMM | M256 core |
|---:|---:|---:|---:|---:|---:|
| 16 (previous reference) | 16 | 19,981 | 26,529 | 676,378 | 682,929 |
| 32 | 32 | 19,981 | 26,529 | 675,484 | 682,029 |
| 64 | 64 | 19,981 | 26,529 | 675,484 | 682,029 |

M4 has an exact observed plateau across 16/32/64. For M256, increasing from
16 to 32 saves 894 GEMM cycles (0.1322 percent) and 900 core cycles
(0.1318 percent). Increasing from 32 to 64 saves zero cycles in either metric.
Thus 32 is the first tested power-of-two size at the exact M256 plateau,
while 16 is already practically saturated under the predeclared 1 percent
criterion. This does not establish the minimum capacity between 16 and 32.

32 also exceeds the conservative core ownership bound of 19 for this
configuration. The observed plateau and fixed upstream bound give no reason
to extend this experiment to 128 or to widen shared tag interfaces. Keep the
production default at 16; the new naive-only compile settings allow future
experiments. No shared/improve RTL was changed.

Cycle-only table:
`docs/hw_analysis/improve_vs_naive/fpint_gemm_psum_slot_sweep.md`.

This is a paired-capacity experiment: it does not isolate the individual
contribution of adapter slots from physical response assembly slots. Any
plateau conclusion applies to these workloads and the unchanged pipeline.
Raw evidence is retained under the ignored `runs/` directory.
