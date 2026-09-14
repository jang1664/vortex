# TH32 source-based physical runs

Both builds launched on 2026-09-07 at 01:05:15 KST after all four simulation
profiles and hook/connectivity preflight passed. **Both failed in post-init:**
TH32/t4 ended02:44:35 and TH32/t8 ended02:53:11 KST. Neither reached placement
or generated an xclbin. TH16/t4 and TH16/t8 were not launched.

The common failure is an unclassified DMA command receiver descendant using
`g_slr.u_link/u_rx` instead of the fixture's `g_slr/u_link/u_rx` spelling.
The follow-up [robust-hook task](../robust-hook/robust-hook-spec.md) tests a
shared matcher against these existing DCPs; it does not retry P&R.

## Common settings

- Vivado/Vitis2025.1, XCU55C-fsvh2892-2L-e, 100MHz.
- Source builds, no DCP retry; configure rerun immediately before each make.
- SLR pipeline and full-SLR constraints on; post-init/post-opt/post-place and
  route hooks retained. Congestion fail-fast off.
- Place Explore; route AlternateCLBRouting; ultrathreads off.
- DEBUG/PERF/PROFILE/SCOPE explicitly empty for physical builds.
- Separate build directories and source snapshots; no shared generated outputs.
- The absolute U55C xpfm avoids the current duplicate short-name platform lookup.

## State and output paths

All paths below are relative to the repository root. Each JSON state is updated
automatically by the live runner when make exits; it records timestamps, PIDs,
command, return code and xclbin presence. Consult it for status newer than this
document. The launch-time source/config hashes are in sibling `sources.json`.

| Profile | State file | Full log |
|---|---|---|
| TH32/t4 | `build/pnr/build_four_config_pnr_artifacts/th32_t4_slr_v1/state.json` | `build/pnr/build_four_config_pnr_artifacts/th32_t4_slr_v1/build.log` |
| TH32/t8 | `build/pnr/build_four_config_pnr_artifacts/th32_t8_slr_v1/state.json` | `build/pnr/build_four_config_pnr_artifacts/th32_t8_slr_v1/build.log` |

TH32/t4 expected xclbin (not yet produced at launch):

```text
build/pnr/build_four_config_pnr_th32_t4/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_t4_bigmem_slr_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin
```

TH32/t8 expected xclbin (not yet produced at launch):

```text
build/pnr/build_four_config_pnr_th32_t8/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_t8_bigmem_slr_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin
```

Physical reports will appear under each output's
`_x/link/vivado/vpl/prj/prj.runs/impl_1/` when that run is created.

## Reproduction

After verifying the preflight gates, invoke the source launcher once per
profile with a **new postfix**. It refuses existing evidence/build directories
and failed/stale config gates. The currently running commands were:

```bash
python3 agent-tasks/u55c-slr-floorplan-pipeline/four-config-pnr/run_physical.py --count 4 --postfix slr_v1
python3 agent-tasks/u55c-slr-floorplan-pipeline/four-config-pnr/run_physical.py --count 8 --postfix slr_v1
```

These attempts have ended; preserve their evidence. The runner uses
normal make with the source config, not checkpoint implementation. Inspect
its recorded command for the equivalent direct invocation.

## Remaining physical gates

Actual synthesis/IP packaging, synthesized ownership and direct crossings,
post-opt/post-place hooks, Laguna placement, routing DRC, resource/congestion,
and 100MHz setup/hold timing remain pending. Simulation and mock Tcl passes
do not substitute for these physical results.
