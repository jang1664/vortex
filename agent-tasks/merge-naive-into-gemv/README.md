# Merge naive into gemv

Integrate `origin/feat/naive` at `77b38ac1dc57d5d09e18b9654f8c47766b98efad`
into `feat/gemv` at `b04c54c00f9f1b7b3b483b50335e43c3c7a3dab4`.
The automatic merge tree is `d668f60241873caa8490d935845e62f91a4d28f8`.
Only `hw/rtl/core/VX_dma_node.sv` was changed on both branches, in separate
hunks. No conflict resolution or manual product-code edits were needed.
If Git later prunes the temporary automatic merge tree, recreate it with
`git merge-tree --write-tree b04c54c00 77b38ac1d` before regenerating the report.

The incoming branch retains its complete history and experiment records.
L16 SLR defaults, L32/D256 defaults, and opt-in ACC selection are preserved.
Verification-only combinations do not change shipped configurations.

## Verification

`results.md` and `results.json` are the compact receipt. `report.py` requires
all 30 blackbox cases, eight required unit runs, 29 splitter cases, selected
improve RTL identity, VCS hierarchy identity, matching improve cycles and HBM
model hashes, and no product changes beyond the automatic merge.

The earlier D256 DMA unit with its default one-cache-lane fixture is retained
under `execution/unit_dma_d256_on_lmem`. The required replacement explicitly
sets `TB_DCACHE_NUM_LANES=4`, so its SLR completion test uses the full 256-byte
global interface and 32 local lanes.

Every blackbox profile has a separate configured build. The wrapper is
`ci/run_black.sh xrt-vcs-sim`, with performance counters and the GEMM latency
observer enabled. `DISABLE_FSDB` avoids storing full waveforms; it does not
disable assertions or alter the design. Numerical pass markers, fatal/error
scanning, return codes, observer counts, and unchanged source hashes are all
required. No synthesis, P&R, hardware run, or push is part of this merge.

## Reproduction

The pre-merge source was frozen with `git archive` of the baseline commit's
`hw`, `sim`, `runtime`, `kernel`, `tests`, `ci`, `configs`, `configure`,
`config.mk.in`, and `Makefile.in` into `build_merge_naive_baseline_source`.
Its `third_party` and `tools` links refer to the shared unchanged inputs;
`build/vcs_simlib` links to the existing compiled vendor library.
Per-run source hashes record the actual RTL, configuration, simulator, and
application inputs. The candidate builds use the merged source tree.

From the repository root, with that frozen baseline prepared:

```sh
python3 agent-tasks/merge-naive-into-gemv/verify.py blackbox --jobs 4 --only baseline_improve_off baseline_improve_on candidate_improve_off candidate_improve_on
python3 agent-tasks/merge-naive-into-gemv/verify.py blackbox --jobs 7 --only candidate_l16_off candidate_l16_on candidate_l32_off candidate_d256_off_lmem candidate_d256_off_acc candidate_d256_on_lmem candidate_d256_on_acc --output-root agent-tasks/merge-naive-into-gemv/execution/naive
python3 agent-tasks/merge-naive-into-gemv/verify.py unit --jobs 3
python3 agent-tasks/merge-naive-into-gemv/splitter.py
python3 agent-tasks/merge-naive-into-gemv/identity.py
python3 agent-tasks/merge-naive-into-gemv/hierarchy.py
python3 agent-tasks/merge-naive-into-gemv/report.py
```

The runners configure the builds, source the profile before RTL execution,
and use `/usr/bin/gcc` and `/usr/bin/g++`. Blackbox builds reuse the generated IP at
`build_naive_slr_candidate_source/build_improve_on/sim/xrtsim_vcs/xilinx_ip`
and compiled libraries at `build/vcs_simlib`; these are simulation inputs,
not the old task's RTL or pass results. All commands and effective defines
are captured in the new task's manifests. Existing build/run directories
are not silently overwritten by `verify.py` or `hierarchy.py`; preserve them
under another name before a complete rerun. `--only` selects individual
blackbox profile labels or unit names. `hierarchy.py --summarize` recomputes
the comparison from existing captured hierarchy evidence.

The initial scheduler used a 1,800-second timeout. Historical naive M256
evidence showed 35-38 minute runs, so its seven queued naive profiles were
moved to an independent 7,200-second scheduler before they started. The
original queued output directories contain reservation markers: the
original runner's refusal to overwrite those directories prevented duplicate
launches. No simulation result is taken from those reserved directories.
The initial improve M256 cases reached that original 1,800-second limit
without compile errors, runtime fatal errors, or completed latency markers.
They are retained as failed timeout attempts, not counted as passing tests.
M4 passed and is not rerun. The four M256 cases are rerun from the same
configured builds with the unchanged CONFIGS and a 7,200-second limit:

```sh
python3 agent-tasks/merge-naive-into-gemv/verify.py blackbox --jobs 4 --only baseline_improve_off baseline_improve_on candidate_improve_off candidate_improve_on --cases m256 --reuse-build --output-root agent-tasks/merge-naive-into-gemv/execution/improve_retry
```

`report.py` uses these explicitly identified retry manifests for improve M256.
The original manifests remain under `execution/{baseline,candidate}_improve_*`.
During the initial runs, the seven owned naive simulators were temporarily
paused to prioritize improve; a watchdog verified PID identity before resuming
all seven at 00:55 on 2026-09-15. Although simulator state was preserved,
the live host socket deadline expired while simv was paused. This was an
agent execution-management error: all seven naive M256 runs failed with
`register_read: recv failed` and wrapper exit code 2. They are retained as
failures, not counted as passing tests. Do not suspend simv independently
of the host in this co-simulation flow. The affected M256 and unrun tagged
cases are rerun without suspension:

```sh
python3 agent-tasks/merge-naive-into-gemv/verify.py blackbox --jobs 7 --only candidate_l16_off candidate_l16_on candidate_l32_off candidate_d256_off_lmem candidate_d256_off_acc candidate_d256_on_lmem candidate_d256_on_acc --cases m256 tag_w0_d0 tag_w0_d1 tag_w1_d0 tag_w1_d1 --reuse-build --output-root agent-tasks/merge-naive-into-gemv/execution/naive_retry
```

The report explicitly selects `execution/naive_retry` for these cases, keeps
the original passing M4 results, and lists every superseded failed attempt.

## Improve preservation evidence

`identity.py` compares 286 RTL translation units across SLR OFF/ON and
debug/NDEBUG, using separate complete header trees. It normalizes whitespace,
preprocessor line directives, and bijective line-derived private names only.
The generic splitter is deliberately excluded from this text comparison:
its incoming parameterization changes its source, but the actual improve
VCS binaries contain no instance of the splitter, its reorder helper,
the external DMA node, or the naive DMA SLR bridge.

`hierarchy.py` searches the exact elaborated VCS binaries at time zero.
SLR OFF/ON have 6,415/6,459 instance paths respectively. Five private macro
instance names shift with source line numbers (eight paths including child
instances). Raw evidence is retained; per-scope, per-kind ordinal
canonicalization preserves distinct instances and produces identical
hierarchies. The selected RTL comparison separately proves the bodies and
references of those macros unchanged. This establishes unchanged improve
selected logic, widths, capacities, and pipeline/handshake implementation
without synthesis resource comparisons.
