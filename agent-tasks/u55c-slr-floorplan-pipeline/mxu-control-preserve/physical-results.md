# Fresh TH32 physical verification: separate MXU control FFs

Status: both source builds are terminal. TH32/t4 completed successfully;
TH32/t8 failed due to routing congestion. Both fresh builds were launched at
2026-09-07 10:53:15 KST after the complete simulation preflight passed.

## Fixed experiment

- Exact configs: `configs/improve_th32_tcol32_m32_t4_bigmem.sh` and
  `configs/improve_th32_tcol32_m32_t8_bigmem.sh`; MXU32x32, WLOAD_NUM=4.
- Fresh configured source builds, including synthesis, with postfix `slr_v2`.
- U55C platform uses its absolute installed `.xpfm` path (avoids ambiguous
  short-name platform lookup); Vivado/Vitis 2025.1.
- 100 MHz, `GEMM_SLR_FLOORPLAN=1`, `Explore` placement,
  `AlternateCLBRouting` routing, `IMPL_ULTRATHREADS=0`,
  `CONGESTION_FAIL_FAST=0`. No DCP retry or directive search.
- Preserve historical `slr_v1` PnR output and robust-hook DCP experiments.

The task-local launcher checks both simulation profile/config hashes and the
exact current RTL file set plus hashes. It refuses stale or incomplete evidence,
existing build/evidence directories, and changes during configure. Launch records
include the simulation gate copy, source/config hashes, logs, command, PIDs and a
durable terminal state. Configure and make source the matching config separately.

## Commands and artifact locations

From the repository root, after preflight:

```sh
python3 agent-tasks/u55c-slr-floorplan-pipeline/mxu-control-preserve/run_physical.py --count 4 --postfix slr_v2
python3 agent-tasks/u55c-slr-floorplan-pipeline/mxu-control-preserve/run_physical.py --count 8 --postfix slr_v2
```

For each `N=4,8`:

- Build: `build_mxu_control_pnr_th32_tN_slr_v2/`
- Evidence: `build/pnr/build_mxu_control_pnr_artifacts/th32_tN_slr_v2/`
- Terminal state: evidence `state.json`; main output: `build.log`.
- Xclbin (only on successful completion): build
  `hw/syn/xilinx/xrt/improve_th32_tcol32_m32_tN_bigmem_slr_v2_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin`.

## Preparation evidence

At 2026-09-07 10:45 KST, required Vivado/Vitis binaries and installed U55C platform
were present. The filesystem had about 332 GiB free and host memory had about
433 GiB available. An unrelated user's implementation was active; it was not
modified or interrupted. Neither new physical build was launched at this point.

## Results

### Launch and configure

Both configured successfully from their exact source config. TH32/t4 entered
make at 10:53:36 KST (runner PID 2047462, make PID 2052892), and TH32/t8 at
10:53:35 KST (runner PID 2047478, make PID 2052489). Both start with fresh source
packaging and synthesis; neither uses a historical implementation DCP.

The exact simulation gate SHA-256 is
`92e6225e4c2f3fa569b0ac9734067576d097e39dcc7350f57b477a01c510ebe2`:
14/14 xrt-vcs-sim cases plus 4/4 directed SLR/non-SLR checks, with 330 RTL files
matched to the current tree. Full source manifests and a copy of that gate are
stored in each evidence directory. Terminal `state.json` is authoritative for
completion; the PIDs above are launch identity, not proof of ongoing execution.

At 11:18 KST the user requested approximately ten-minute status checks. The
45-second read-only monitor was stopped after verifying its exact process
identity (PID 2107276, started 10:57:36); neither build/Vivado process was
interrupted. Subsequent state/log/checkpoint reads are scheduled at ten-minute
intervals, using interruptible waits. Natural completion/error messages may be
reported when delivered without extra polling.

### Targeted preservation check

The task-local `check-preserved-mxu-dcp.tcl` is a read-only checker for a newly
generated source checkpoint. It requires exactly 160 distinct unmarked,
preserved local FFs, 160 marked/preserved TX block-index FFs and 160 marked RX
block-index FFs. It checks local fanout remains in SLR1, each TX Q has exactly
one RX D load, and ownership is SLR1 to SLR2. Its placed mode additionally checks
actual SLRs and records Laguna site/BEL mapping for every pair. It never writes
a checkpoint or invokes optimization/implementation.

### Physical result

Both full synthesis flows passed: TH32/t4 at 12:11:02 KST and TH32/t8 at
12:16:44 KST. Both then entered implementation initialization.

TH32/t4's targeted synthesized-DCP inspection passed and exited zero at
12:19:12 KST: 160 separate local FFs and all 160 exclusive marked TX-to-RX
block-index links survive synthesis. Per-FF evidence is under
`build/pnr/build_mxu_control_pnr_artifacts/th32_t4_slr_v2/synth-dcp-check/`.
This confirms the intended logical/physical register identities before placement,
not actual SLR or Laguna placement. The analogous TH32/t8 inspection also passed
and exited zero at 12:30:00 KST, with its per-FF evidence in the corresponding
`th32_t8_slr_v2/synth-dcp-check/` directory. Thus both new source checkpoints
prove the local/TX register separation and exclusive block-index TX fanout.

Each `preserved_mxu_local.tsv` and `preserved_mxu_links.tsv` has exactly 160
data rows. Inspected source checkpoint SHA-256 identities:

- TH32/t4: `8c1bd669570946e53f460812a35b02b875601f20fa2801152d43dc64088de83d`.
- TH32/t8: `e682f9cdbebca708685440f9d6fb91daa412712cd21c32328035fd46a10d3d28`.

At the 12:48 KST scheduled check, both designs had passed real post-init
full-SLR pblock application, marked-group validation and exact FF-pair validation
(27 crossing groups per config). Both unclassified-leaf reports contained only
their header, both boundary-net reports contained only their header, and the
post-init links reports had zero `# ERROR` rows. The designs progressed to
pre-opt QoR assessment. The earlier `[Ip 78-110] Invalid part string Project`
message was present in both logs but was not terminal: subsequent strict checks
completed and implementation continued.

Pre-opt required resources reported by Vivado were LUT/FF/BRAM/DSP
661204/516156/557.5/2261 for t4 and 720035/564880/589.5/2325 for t8. These are
absolute pre-opt counts, not a controlled delta measurement against `slr_v1`.

At 13:22 KST both custom post-opt ownership/marked-group/direct-pair checks had
passed and placement had started. Post-opt links reports contain 5408 valid pairs
for t4 and 5409 for t8, with zero `# ERROR` rows and all 160 MXU block-index
pairs present in each. Thus the targeted links survive both synthesis and
optimization. The t4 placer was at phase 1.3 and t8 at phase 1.1 at that check.

At 15:14 KST TH32/t4's real post-place hook passed exact leaf/pblock/actual-SLR
checks and direct FF-pair validation. Its report has 5408 pairs in 27 crossing
groups, with 5340 Laguna pairs. Crucially, **all 160 MXU block-index TX/RX pairs
are Laguna pairs from SLR1 to SLR2**. TH32/t8 also finished `place_design` and was
entering its post-place reporting/checks. Neither source build was terminal.

At 15:26 KST TH32/t8's post-place strict checks also passed. It has 5409 direct
pairs, 3792 Laguna pairs and **160/160 target block-index Laguna pairs from SLR1
to SLR2**. Both configs passed all 27 group checks. TH32/t4 had entered routing;
TH32/t8 was saving its placed checkpoint. A read-only targeted check of t4's
completed placed checkpoint was launched to additionally inspect every preserved
local FF's actual SLR and exclusive TX fanout after placement.

TH32/t4's targeted placed-DCP inspection passed and exited zero at 15:35:25 KST:
all 160 local FFs are physically in SLR1 and unmarked; all 160 dedicated TX FFs
have exactly one RX D load, and all 160 TX/RX pairs occupy Laguna sites in
SLR1/SLR2. The corresponding TH32/t8 placed-DCP inspection also passed and exited
zero at 15:47:28 KST. Both completed placed checkpoints therefore verify the exact
local/TX separation, exclusive TX fanout and all 160 target Laguna pairs. Reports
are in each evidence directory's `placed-dcp-check/` subdirectory. Both source
builds were still routing at the 15:49 scheduled check.
TH32/t4's early router estimated global/short congestion level 5 and timing
congestion level 7; these are warnings, not a terminal routing result.

### TH32/t4 terminal result

The complete source build exited **0** at **20:32:45 KST**. Bitgen and the final
DRC succeeded (0 DRC errors). The xclbin is **79,989,273 bytes**:

`build/pnr/build_mxu_control_pnr_th32_t4_slr_v2/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_t4_bigmem_slr_v2_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin`

However, **100 MHz timing closure did not pass**. `vortex_afu.xclbin.info:59`
records 100 MHz requested and **92.2 MHz achieved** (DATA clock metadata rounded
to 92 MHz). The final post-route-physopt timing summary, line 166, reports
WNS **-0.838 ns**, TNS **-1833.435 ns** (7762 failing setup endpoints), WHS
**+0.003 ns** and THS **0 ns**. Build/bitstream success must not be presented as
meeting the requested 100 MHz clock.

Reports relative to the t4 output directory:

- `_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt:166`
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_route_status.rpt:11`:
  1,365,341 fully routed nets, 0 nets with routing errors.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/full_util_routed.rpt`: routed full-device
  snapshot (including platform) has 753877 LUTs, 634771 CLB registers, 751.5 BRAM
  tiles, 124 URAM and 2265 DSPs. It precedes optional post-route physopt and is not
  a controlled RTL resource delta.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/slr_util_routed.rpt`: SLR0/1/2 LUT use
  is 135030/288863/329984 (30.71%/66.87%/76.39%).

The Make report-copy step could not find two legacy-named kernel utilization
reports; those copy errors were explicitly ignored, and the durable final
return code is zero. The full-device reports above are present.

### TH32/t8 terminal routing failure

The failure is **routing congestion, not floorplan hook matching or the preserved
MXU registers**. The `impl_1/runme.log` under the t8 output directory reports:

- Line 2980: `[Route 35-162]` — **7180 signals failed to route due to congestion**.
- Line 3078: `[Route 35-2]` — **4772 node overlaps**, design not legally routed.
- Line 3089: `[Constraints 18-1000]` — partially conflicted nets include HMSS
  `path_13/.../triple_slr.fwd.slr_middle/common.ready_d[3]` and dcache bypass
  response arbitration. These examples are not an exhaustive bottleneck audit.

The historical `[Ip 78-110] Invalid part string Project` diagnostic is not this
failure's cause: the flow passed synthesis, post-init, post-opt and post-place
before the router failed. Post-failure DRC reported 0 DRC errors, which does not
override the explicit illegal-route result. No retries or source/options changes
were made. The source-build wrapper exited **2** at **20:46:10 KST**, after
Vivado exited at 20:45:26 KST. The durable state is `failed` and
`xclbin_exists=false`. The Vitis linker ended with `impl_1` / `route_design`
failure, not a successful timing result. There is no final valid routed timing
signoff for this failed implementation.

## Final verification verdict

| Check | TH32/t4 | TH32/t8 |
| --- | --- | --- |
| Fresh configure and synthesis | PASS | PASS |
| Post-init / post-opt strict floorplan hooks | PASS | PASS |
| Post-place actual SLR / crossing-group checks | PASS | PASS |
| Distinct local and TX block-index FFs in source and placed DCPs | 160 + 160, PASS | 160 + 160, PASS |
| Target MXU block-index Laguna TX/RX pairs | 160/160, SLR1 to SLR2 | 160/160, SLR1 to SLR2 |
| Routing and bitstream | PASS, xclbin generated | FAIL, congestion; no xclbin |
| Requested 100 MHz | FAIL; achieved 92.2 MHz | No valid routed signoff |
| Terminal exit and time | 0, 20:32:45 KST | 2, 20:46:10 KST |

Both terminal states were confirmed at the scheduled **20:52:49 KST** check on
2026-09-07; monitoring then stopped. The requested register-separation change and
strict floorplan behavior are proven in both physical placements. Remaining
100 MHz timing closure (t4) and routing congestion (t8) are separate unresolved
implementation outcomes; this experiment did not modify RTL/options to address
them or retry either build.
