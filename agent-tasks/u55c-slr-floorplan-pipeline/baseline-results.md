# Frozen merged W4 simulation baseline

Measured on 2026-09-05. All 12 accepted primary-profile runs passed numerical
reference checking, exited successfully, and had no fatal/assertion-failure
marker in their RTL traces. This is simulation evidence, not timing or routing
sign-off.

## Source and build isolation

- Revision: `5d8fc73fbaae62cb5cebbd3320b5e8dc5ef0836e`.
- Immutable source export: `/tmp/vortex-slr-baseline-5d8fc73f.4w9kmJ`.
  Created using `git archive HEAD` before concurrent RTL implementation began.
  Initialized AXI/component_database/cvfpu/hardfloat/ramulator/softfloat
  submodules were independently archived at their checked-out revisions.
  Required initialized AXI common_cells and Ramulator headers were copied;
  no dependency symlink points back to mutable project RTL.
- Accepted fresh build: `/tmp/vortex-slr-baseline-5d8fc73f.4w9kmJ/build_w4`.
- Configuration: `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`
  from the frozen source: TH16, MXU32, W4, eight response slots, RAM payloads,
  **without** the newly introduced `GEMM_SLR_PIPELINE` define.
- Config SHA256: `19b77a3f71962d2de4de1ac15395e5d153825b3b23f62aaa1e0fb3030754efcb`.
- Configure command, run after sourcing that config from the fresh build:
  `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`.
- VCS: `W-2024.09-SP1`; vendor IP generated with installed Vivado `2025.1`.
  Precompiled vendor-only simulation libraries are read from
  `/home/jaeyongjang/project.local/vortex_fpint/build/vcs_simlib` through
  `SIMLIB_DIR`; all RTL, generated floating-point IP and work libraries are
  compiled independently in the frozen build. No synthesis was performed.
- Existing unrelated simulation processes/builds were not stopped or cleaned.

## Image identity

| Artifact | SHA256 |
|---|---|
| Accepted `sim/xrtsim_vcs/simv`, identical across all 12 runs | `8e48b4f307ad9d469d4e45bceee55094af1a08e99b539cd634654e80a35e92de` |
| Compiled RTL code `simv.daidir/_864640_archive_1.so` | `816751eb973e791516fcbadfc3cb320e35810b89a5b9c50304919eb3b0e4f5e4` |
| `tests/regression/fpint_gemm_ffn_hw/kernel.vxbin` | `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177` |
| `tests/regression/fpint_gemm_ffn_hw/fpint_gemm_ffn_hw` | `054ce8f1bf7c66f99ef12088e34d8fcc89144b2949c124571120170b5fbf91d8` |
| Copied vendor-independent Ramulator shared library | `8ebfe0d7ec93f72a5b79c8a9f1a51002f33a3933b93f4490101f972e76a05986` |
| Copied SoftFloat archive | `f16bec3e8a32ab256cc3a5706c1f52b497d31ba7f7d0a59ad31b846adc66eb34` |

## Reproduction and retained evidence

The checked-in `measure_gemm.py` runs each case through `ci/run_black.sh
xrt-vcs-sim --app fpint_gemm_ffn_hw --debug 3` from the configured build,
explicitly sources that build's source configuration, and uses system host
compilers. It imports `tools/verify_rtl.py` pass/failure helpers and rejects
nonzero wrapper exits or explicit trace failures. All required
`DBG_TRACE_PIPELINE/MEM/CACHE/AFU/SCOPE/GBAR/TCU/GEMM` traces are enabled.
`DISABLE_FSDB` suppresses unnecessary waveform generation; no functional
assertion switch is disabled by this measurement script.

```bash
SIMLIB_DIR=/home/jaeyongjang/project.local/vortex_fpint/build/vcs_simlib \
python3 agent-tasks/u55c-slr-floorplan-pipeline/measure_gemm.py \
  --build /tmp/vortex-slr-baseline-5d8fc73f.4w9kmJ/build_w4 \
  --out /tmp/vortex-slr-baseline-5d8fc73f.4w9kmJ/results-w4-new \
  --repeat 3 --timeout 1800
```

Accepted original evidence is in `results-w4/summary.json` and per-run
`.wrapper.log`, `.app.log`, `.simv.log.gz` files under the source export.
The script requires a new output directory to avoid overwriting evidence.

## Primary measurements

All cases use `-q 32 -r 1`. Each row contains three independent launches.

| Case | Shape and mode arguments | Host PERF cycles | Median |
|---|---|---|---:|
| Smoke QCOL | `-m 2 -n 32 -k 128 -t 0 -d 0` | 5799, 5800, 5799 | 5799 |
| Overlap QCOL | `-m 4 -n 256 -k 256 -t 0 -d 0` | 6475, 6473, 6474 | 6474 |
| QROW | `-m 31 -n 64 -k 96 -t 1 -d 1` | 6175, 6179, 6176 | 6176 |
| Odd-tail QCOL | `-m 3 -n 33 -k 33 -t 0 -d 0` | 5873, 5875, 5872 | 5873 |

Internal spans are last-event minus first-event, not inclusive cycle counts.
The testbench has a 10 ns period and trace `%t` timestamps are in ps.

| Case | Input-admission span | Compute-fire span | First DMA accept to last logical complete | Final consecutive output-store accepts |
|---|---:|---:|---:|---:|
| Smoke QCOL | 19 | 25 | 120–121 | 0 (one store) |
| Overlap QCOL | 565–570 | 563–568 | 766–774 | 84 (four stores) |
| QROW | 221 | 216 | 483–487 | 88 (two stores) |
| Odd-tail QCOL | 27 | 26 | 149–156 | 26 (two stores) |

Input-admission comes from `GEMM_V2_OWNERSHIP accept=1`; compute-fire from
`GEMM_V2_COMPUTE_FIRE`; DMA timing from `TMEM_DMA_CMD_ACCEPT` and
`TMEM_DMA_LOGICAL_COMPLETE`. Only the final consecutive `OP_DMA_ST=0x2`
command group is used for serialized store-tail timing. Host transport adds
run-to-run variation, so compare medians and retained internal event spans.

## Rejected preliminary attempts and limitations

1. Initial vendor-library regeneration was stopped explicitly after roughly
   three minutes. Its partial `build/vcs_simlib` cache is not used; the
   accepted build uses the complete precompiled vendor-only library above.
2. An optional `DBG_TRACE_GEMM_CMD_PERF` experiment compiled image
   `4cf02fd56672728459a8b1928606cb46106c1266bec887b2fde347c6f93ba70e`
   but failed on the **unmodified baseline** before compute started:
   `hw/rtl/core/gemm/VX_gemm_ctrl.sv:1881`,
   `dbg_command_lifecycle_ledger`, at `50525000 ps`:
   `non-DMA child 0 has two active UIDs` (offending expression
   `!dbg_active_uid_valid[child]`). The optional ledger assumes one active
   non-DMA command and does not model the merged overlapping child queues.
   This is not an SLR RTL regression. Evidence remains in `results/` and
   `build/`; it is excluded from accepted measurements. Both baseline and
   candidate comparisons omit this optional ledger, retaining ordinary GEMM
   traces and functional assertions.
3. A parser initially matched hierarchy array indices such as `g_clusters[0]`
   instead of the trace timestamp. The accepted parser explicitly matches
   `: [timestamp] |`; all accepted measurements above use the corrected rule.
4. Existing normal traces expose input/weight source and destination events,
   but not response RAM allocation, response acceptance, exact slot release,
   peak occupancy, or slot-full stall cycles. These metrics are not claimed
   by this baseline. They need dedicated instrumentation or focused waveforms.
5. The verification agent reference paths `harness/rules/testbench.md`,
   `harness/skills/run-test/SKILL.md`, and
   `harness/skills/add-test-case/SKILL.md` do not exist. Available
   project-context, run-bb-common, debug-xrt-vcs and sim-common instructions
   were used instead.

The accepted functional baseline is complete. MXU16 compatibility and
candidate performance/timing acceptance are separate results.
