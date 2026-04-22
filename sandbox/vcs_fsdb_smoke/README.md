# Tier 1 — Standalone VCS/Verdi FSDB Smoke Test

Isolated sanity check for the `bind vortex_afu + $fsdbDump*` pattern that the
Vitis hw_emu FSDB work depends on. Runs without Vitis, without XRT, without
a platform — just vlogan + vcs + simv on three SV files.

## Purpose

Decides which layer of the problem is broken:

| This test | If it passes | If it fails |
|---|---|---|
| Standalone VCS FSDB smoke | VCS/Verdi mechanics are OK. Issue is in the Vitis packaging pipeline (`ipx::package_project` drop at kernel-IP time). Proceed to Tier 2. | Issue is in `vcs_fsdb_init.sv` itself, or in the bind scope argument, or in the Verdi PLI environment. Fix here before touching Vitis. |

## Files

- `tiny_dut.sv` — minimal module named `vortex_afu` (so `bind vortex_afu ...` resolves).
- `tiny_tb.sv` — top-level testbench that instantiates `vortex_afu` and runs ~500 ns.
- `vcs_fsdb_init.sv` — symlink to the real `runtime/xrt/vcs_fsdb_init.sv` (so any edit to the real file is reflected here automatically).
- `run.sh` — vlogan → vcs → simv → verdict.

## Run

```
./run.sh
```

Expected output on success:

```
PASS: vortex.fsdb generated (NNNN bytes)
```

## Debugging hints

- No FSDB, but simv ran:
  - Check `simulate.log` for `Undefined system task $fsdbDumpfile` — means PLI was not linked. Re-check `VERDI_HOME` and `LD_LIBRARY_PATH`.
  - Check `elaborate.log` for `bind` — no mention means VCS did not resolve the bind. Compare module names between `tiny_dut.sv` and `vcs_fsdb_init.sv`.
- simv segfaults on start:
  - Usually Verdi PLI ABI mismatch. Try a different Verdi version (`ls /tool/Program/synopsys/verdi/`) and re-export `VERDI_HOME`.
- FSDB generated but almost empty (< ~500 bytes):
  - `$fsdbDumpvars(0)` from inside a bound module dumps the bind module's own scope (empty). Change the call to `$fsdbDumpvars(0, vortex_afu)` in `runtime/xrt/vcs_fsdb_init.sv` and rerun.

## What this does NOT test

- `ipx::package_project` dropping simulation-only files (Vitis Phase 2 관문 4).
- v++ link extracting XO into `ipshared/` and regenerating compile.sh (Phase 3).
- Vitis emulation launcher wrapping simv with `-do pfm_top_wrapper_simulate.do`.

Those belong to Tier 2 (minimal Vitis hw_emu kernel).
