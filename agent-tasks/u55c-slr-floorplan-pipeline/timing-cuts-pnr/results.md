# Full-SLR source PnR results — 2026-09-08

All three requested runs have terminated. Hourly monitoring ended at 14:20 KST.
No automatic retry, DCP-based implementation restart, or RTL changes were performed.

## Configuration

- Launch source commit: `6ba2e16ae1d1069f3bd18523808aa7f9b23a2316`.
- U55C, Vivado/Vitis 2025.1, requested clock 100 MHz.
- `GEMM_TIMING_CUTS=1`, WLOAD 4, full-SLR RTL pipeline and floorplan enabled.
- Placement `Explore`, routing `AlternateCLBRouting`, ultrathreads disabled.
- Each run sourced its exact config, completed a fresh configure, and ran source synthesis with postfix `slr_v3` and `--no-early-fail`.
- Added the matching full-SLR settings to `configs/improve_th32_tcol32_m32_bigmem_hbm4_tmem8.sh` with explicit user approval; the original two runs were not restarted.

## Terminal outcomes

| Config | Finished (KST) | Result | Clock / routing evidence |
| --- | --- | --- | --- |
| `improve_th32_tcol32_m32_t4_bigmem.sh` | 06:54:11 | Success, xclbin generated | 100 MHz achieved; WNS +0.003 ns, TNS 0; WHS +0.004 ns, THS 0; routing errors 0 |
| `improve_th32_tcol32_m32_t8_bigmem.sh` | 10:21:46 | Failure, no xclbin | 4,408 node overlaps; routing verification failed |
| `improve_th32_tcol32_m32_bigmem_hbm4_tmem8.sh` | 13:46:12 | Failure, no xclbin | 1 node overlap; routing verification failed |

The failed runs reached routing, so neither failed at the floorplan hook. This is not a complete audit of final physical SLR ownership. Routing failure also prevents claiming a valid 100 MHz implementation for either failed run.

TH32/t4 had an ignored warning while copying an optional kernel-utilization report; its build return code was 0 and the final artifact/frequency/timing/routing reports were verified.

## Routing failures

Both failed runs report `VPL 35-2` (not legally routed) and `VPL 18-1000` (partially-conflicted nets). The later `Invalid part string Project` and link errors do not replace the preceding concrete routing failure.

For TH32/t8, the first ten example conflicts reported by the tool are in the D-cache bypass request arbiter, under:

```text
dcache/g_cache_wrap[0].cache_wrap/g_bypass.cache_bypass/mem_bus_out_arb/req_arb
```

These examples are not a complete congestion diagnosis or proof that this hierarchy alone caused the failure.

For TH32/HBM4/TMEM8, the reported conflicted nets are:

```text
level0_i/ulp/hmss_0/inst/path_12/slice0_12/inst/w15.w_multi/triple_slr.fwd.slr_middle/Q[122]
level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/gemm_node/u_tmem_subsystem/u_input_req_reservation/u_slr/u_response/g_slr.u_link/u_tx/D[243]
```

This identifies a remaining routing-resource conflict involving an HMSS middle-SLR net and the GEMM input-response SLR-link transmitter net. One overlap still invalidates the implementation; its small count does not establish timing closure or guarantee that a retry will succeed.

## Evidence locations

All paths below are relative to the repository root.

Successful TH32/t4 artifact:

```text
build_timing_cuts_pnr_th32_t4_slr_v3/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_t4_bigmem_slr_v3_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin
```

Under that same output root:

- `bin/vortex_afu.xclbin.info`: requested and achieved frequency.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt`: final setup/hold summary.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_route_status.rpt`: routing errors 0.

Each evidence directory contains `build.log`, terminal `state.json`, and source hashes in `sources.json`:

```text
build_timing_cuts_pnr_artifacts/th32_t4_slr_v3/
build_timing_cuts_pnr_artifacts/th32_t8_slr_v3/
build_timing_cuts_pnr_artifacts/th32_tcol32_m32_bigmem_hbm4_tmem8_slr_v3/
```

No new exact-config simulation pass is claimed by this physical run task. All outputs were preserved for subsequent analysis.
