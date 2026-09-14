# Four-profile xrt-vcs-sim preflight results

Completed 2026-09-07 01:00 KST. **28/28 functional runs and 2/2 directed
physical-TMEM-array depth runs PASS.** No RTL changes were required.

## Tested source and setup

- Source branch: `feat/gemv`; RTL sorted-file SHA-256 manifest:
  `2f54f404a8aac5bd2117c167c89878f312a555d82394fac7be7a7387fae5acdd`
  across 334 files. This matches the previously verified merged RTL.
- Configs: `configs/improve_th{16,32}_tcol32_m32_t{4,8}_bigmem.sh`.
  Every profile retains MXU32x32, W4, RAM8, SLR transports and 512KiB TMEM.
- Four separate `build/experiment-archive/build_four_config_th16_t4`, `build/experiment-archive/build_four_config_th16_t8`,
  `build/experiment-archive/build_four_config_th32_t4`, `build/experiment-archive/build_four_config_th32_t8` directories were
  configured with `../configure --xlen=64 --tooldir=/opt/vortex
  --prefix="$HOME/tools/vortex"`, sourcing the associated config first.
- Each blackbox run sources its exact profile and uses
  `ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --debug 3`.
  Host compilers: `/usr/bin/gcc`, `/usr/bin/g++`; `PATH=/usr/bin:$PATH`.
  VCS: W-2024.09-SP1; vendor library: `build/vcs_simlib`.
- Reused `../measure_gemm.py` without changing its verification semantics.
  `measure_overlap.py` imports it and replaces only the case list.
  Debug traces include pipeline/memory/cache/AFU/scope/GBAR/TCU/GEMM;
  FSDB is disabled. Initial timeout300s sufficed for every simulation;
  first compile-plus-smoke took 94-101s. At most two profiles compiled
  concurrently; runtimes, sockets, application binaries and logs were isolated.
- Numerical PASS, zero strict trace/assertion failures, and balanced Weight
  response-slot allocation/response/release counts were required for every run.
  Slot occupancy reaches eight; overlap runs record full-slot stalls and
  response bypass releases, so RAM-slot backpressure is exercised.

The machine-readable [simulation-manifest.json](simulation-manifest.json)
records current config hashes, the exact base and effective CONFIGS strings,
per-suite config-start hashes, simulator hashes, cycles and evidence paths.
Raw summaries additionally retain application/shared-library hashes, internal
DMA intervals, slot metrics and compressed traces. Physical-flag-only edits to
the t4 config occurred during testing: initial config-file hashes can differ
from final hashes, but RTL compile defines did not change.

## Functional cases and host cycle samples

All rows below passed on all four profiles. Each result is **one sample**, not
a median or a regression comparison against a new baseline.

| Case | M / N / K | QDIR / transpose | TH16/t4 | TH16/t8 | TH32/t4 | TH32/t8 |
|---|---|---|---:|---:|---:|---:|
| Smoke | 2 / 32 / 128 | 0 / 0 | 5878 | 5874 | 6502 | 6427 |
| Overlap | 4 / 256 / 256 | 0 / 0 | 6626 | 6623 | 7254 | 7251 |
| QROW partial M/K | 31 / 64 / 96 | 1 / 1 | 6252 | 6249 | 6878 | 6803 |
| Odd N/K tails | 3 / 33 / 33 | 0 / 0 | 5875 | 5874 | 6500 | 6500 |
| Overlap transpose | 4 / 256 / 256 | 0 / 1 | 6624 | 6632 | 7253 | 7254 |
| Overlap QROW | 4 / 256 / 256 | 1 / 0 | 6624 | 6626 | 7253 | 7253 |
| Overlap QROW transpose | 4 / 256 / 256 | 1 / 1 | 6624 | 6627 | 7253 | 7252 |

All use QBLK32 and one repetition (`-q 32 -r 1`). Host cycle differences
between profiles do not isolate RTL delay: thread count, channel geometry and
host/device polling phases differ. No 2% performance gate is claimed here.

Canonical raw evidence is in each build's `evidence/summary.json`, except
TH16/t8 uses `evidence-retry/summary.json`. Supplemental three-layout overlap
evidence is in each build's `overlap-evidence/summary.json`.

Reproduction from the source root after configure:

```bash
SIMLIB_DIR="$PWD/build/vcs_simlib" CC=/usr/bin/gcc CXX=/usr/bin/g++ \
python3 agent-tasks/u55c-slr-floorplan-pipeline/measure_gemm.py \
  --build build/experiment-archive/build_four_config_th32_t4 \
  --out build/experiment-archive/build_four_config_th32_t4/new-evidence \
  --config configs/improve_th32_tcol32_m32_t4_bigmem.sh \
  --repeat 1 --timeout 300
```

For the complementary overlap layouts substitute
`agent-tasks/u55c-slr-floorplan-pipeline/four-config-pnr/measure_overlap.py`
and a distinct output path. Repeat with each corresponding profile/build.
Never reuse an existing evidence directory or run two cases within one build
simultaneously.

## t4 upper-half physical-array depth checks

The production app fixes DMA MT/NT/KT=128
(`tests/regression/fpint_gemm_ffn_hw/common.h:10`) and computes a fixed
double-buffered layout (`main.cpp:584`). The QBLK32-only check at
`main.cpp:641` prevents changing quantization granularity to enlarge it.
Larger M/N/K arguments alone cannot reach aggregate TMEM address0x40000,
which selects the extra upper-half address bit for a four-array geometry.

The existing `tensor_mem_bank` unittest fixes 1024-byte storage and 8-byte
words as localparams. Therefore the scoped [tb_tmem_depth.sv](tb_tmem_depth.sv)
instantiates the **actual** `VX_tensor_mem_bank` with the sourced production
`TMEM_BANK_SIZE=131072` and 64-byte words. Both TH16/t4 and TH32/t4 pass:

- Distinct patterns at word0 / word1024 and word1023 / word2047 prove the
  extra word-address bit10 does not alias either half onto the other.
- Physical byte addresses checked:0x00000,0x0ffc0,0x10000,0x1ffc0.
- Alternating-byte overwrite at word1024 preserves all disabled bytes and
  leaves the paired lower-half word unchanged.
- Read responses are held for3-5 cycles and write acknowledgement for2 cycles;
  valid, tag and payload are checked throughout the hold.
- Twelve transactions per run; behavioral simulation finishes at570ns with
  assertions enabled. Both logs end in explicit `PASSED`.

This proves **physical-array depth/addressing**, not end-to-end high-address
DMA/SLR routing. Canonical tests cover upstream routing at lower addresses.
An end-to-end relocated-layout test remains additional coverage, not evidence
silently inferred from these checks.

Logs: `build_four_config_th{16,32}_t4/hw/unittest/tmem_depth/logs/{compile,sim}.log`.
The local build Makefiles include the task's [tmem-depth.mk](tmem-depth.mk).
Reproduce after sourcing the matching t4 profile:

```bash
source configs/improve_th32_tcol32_m32_t4_bigmem.sh
PATH="/usr/bin:$PATH" python3 tools/verify_rtl.py unittest \
  --path build/experiment-archive/build_four_config_th32_t4/hw/unittest/tmem_depth \
  --sim vcs --timeout 300
```

## Failed attempts and limitations

- Initial TH16/t8 wrapper attempt ran before its configure-generated app
  directory had finished copying. It failed immediately with
  `Application folder not found: fpint_gemm_ffn_hw`; no RTL simulation ran.
  Evidence remains at `build/experiment-archive/build_four_config_th16_t8/evidence/`. Retrying after
  configure completed passed all four cases. This setup failure is not counted
  as a functional run or hidden in the successful suite.
- Referenced legacy verification-agent instructions `harness/rules/testbench.md`
  and `harness/skills/{run-test,add-test-case}/SKILL.md` do not exist. Existing
  project-context/run-bb-common/debug-xrt-vcs instructions and the deterministic
  verification runner were followed instead.
- No OOC/synthesis/P&R was launched by this verification worker. Floorplan
  hook fixtures and actual physical implementation remain separately reported
  parent-task responsibilities; these passes do not establish timing closure.
