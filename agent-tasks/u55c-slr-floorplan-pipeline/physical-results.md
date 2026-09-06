# U55C full implementation results

Status: **fifth normal source run started 2026-09-06 01:26 KST**, after fixing
the fourth run's post-opt API failure and passing actual full-hook/idempotence
preflight. The fourth run stopped at 00:13; the third stopped during placement
feasibility at 2026-09-05 22:00.
Final RTL passes functional and primary host-cycle gates. In slr_v3, synthesis,
actual post-init constraints and post-opt direct-pair/boundary/receiver-enable
checks pass. A place-created ACC reset LUT is outside its partner FF's hard
SLR1 pblock, causing a placement-shape ownership conflict. The flow correction
is implemented and its regression tests pass; actual placement, routing and
timing closure remain unverified. The sections below preserve run history.

## Reproduction

This is a normal source-based build in a freshly configured directory, not a
checkpoint retry. The primary config selects TH16, MXU32 and WLOAD4.

```sh
source configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh
cd build_slr_hw
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
cd hw/syn/xilinx/xrt
make \
  PLATFORM=/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm \
  PREFIX=improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v1 \
  TARGET=hw CLOCK_FREQ_HZ=100 \
  CONGESTION_FAIL_FAST=0 GEMM_SLR_FLOORPLAN=1 DMA_CHANNEL_FLOORPLAN=0 \
  DEBUG= PERF=
```

- Tools: Vivado/Vitis 2025.1.
- Placement: Explore. Routing: AlternateCLBRouting. Ultrathreads disabled.
- Full log: `build_slr_hw/full-implementation-slr-v1.log`.
- Output root, relative to `build_slr_hw/hw/syn/xilinx/xrt`:
  `improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`.
- Run reports reside below `_x/link/vivado/vpl/prj/prj.runs/impl_1` in that
  output root.
- Congestion fail-fast is disabled, but the independent SLR ownership and
  crossing checks remain enabled.

## First-run physical evidence (historical slr_v1)

| Gate | Current result |
|---|---|
| Kernel RTL synthesis | PASS: 0 errors, 0 critical warnings |
| Retained boundary FF groups and ownership | Corrected checker passes read-only synthesized inspection; 9,474 marked FFs |
| Three legal full-SLR user pblocks and required hierarchy ownership | Pending |
| Direct adjacent-SLR TX Q to RX D connections | FAIL: 512 Weight payload TX FFs absorbed into BRAM; narrow preservation fix in progress |
| Actual per-group Laguna TX/RX placement | Pending |
| No unregistered functional partition-boundary bypasses | Pending |
| Legal routing: no failed/unrouted/overlapping nets | Pending |
| Setup WNS >= 0 ns and hold WHS >= 0 ns at 100 MHz | Pending |
| No fatal DRC, RP/clock-column or placement conflicts | Pending |
| Per-SLR resources, SLL headroom and top setup-path review | Pending |

Post-init and post-place reports are described in `floorplan-flow.md`.
Source-level/Tcl fixture checks do not substitute for these physical gates.

## Kernel synthesis resources

`ulp_vortex_afu_1_0_utilization_synth.rpt`, generated 17:13 KST in the
`ulp_vortex_afu_1_0_synth_1` run, reports:

| Resource | Used |
|---|---:|
| CLB LUT | 447,090 |
| FF (no latches) | 309,789 |
| BRAM tiles | 403.5 (379 RAMB36 + 49 RAMB18) |
| URAM | 156 |
| DSP | 2,273 |

These are kernel-only, pre-implementation counts. They exclude the platform
and do not measure SLR headroom, placement packing or an incremental delta
against the merged baseline. The report itself notes that LUT counts may
decrease after optimization/implementation.

## Progress

- 16:18: sourced config and configured the build immediately before launch.
- 16:23: VPL started RTL synthesis after platform/IP generation.
- 16:25: RTL optimization phase 1 completed; no synthesis error reported.
- 16:46: 122/156 block synthesis jobs complete. Kernel cross-boundary and
  area optimization remains active; no synthesis error observed. RAM pipeline
  inference warnings are not new to this experiment (the same message exists
  in historical opt_v6), but their current timing impact remains unmeasured.
- 16:57: kernel cross-boundary/area optimization completed.
- 17:00: kernel technology mapping started; 155/156 block jobs complete.
  `Synth 8-7052` reports URAMs without merged optional output registers.
  Check actual memory-to-response-TX paths after placement; this advisory
  alone does not identify a timing failure or justify a latency change.
- 17:12: `synth_design completed successfully`, elapsed 48:46. Reported
  optimization diagnostics: 0 errors, 0 critical warnings, 2,657 warnings.
- 17:13: synthesis checkpoint and kernel utilization report generated.
- 17:17: all 156 block jobs and top-level synthesis completed; VPL entered
  implementation. Platform/netlist stitching is running as of 17:20.
- 17:37: post-init stopped with `SLR floorplan missing required group: DMA
  idle SLR0`. The controller does not consume `gemm_ctrl_if.dma_flag.idle`:
  its DMA child idle flag uses `cmd_ready` (`VX_gemm_ctrl.sv:1265`), although
  the node connects the bridge idle output (`VX_gemm_node.sv:1232`). This
  permits the complete idle transport cone to optimize away. Confirm the
  synthesized structure and permit only complete removal, not an unpaired
  surviving crossing. Preserve this failed run; do not restart implementation
  from its checkpoint.

Two unrelated implementation warnings also reproduce historical opt_v6:
generated `dont_partition.xdc:1` sets a property on an empty `SDX_KERNEL`
query, and the CPU memory coalescer uses the existing asynchronous BRAM-patch
fallback. Neither is the fatal SLR-group validation failure above.

## Read-only synthesized inspection and physical correction

The failed run's kernel checkpoint was opened only for cell/connectivity
queries, without pblock creation, optimization, placement or routing. Diagnostic
logs are `build_slr_hw/slr_synth_preflight*.log`; interrupted slow-checker
versions remain preserved. The current completed inspection is version 4,
with `slr_synth_preflight_v4_links.tsv`:

- All DMA idle endpoint cells are absent, consistent with the unused output.
  Permit complete cone removal only; a surviving half still requires its
  matching marked endpoint.
- Hierarchy/profile checks pass. Logical ownership counts (not placed usage)
  are SLR0 125,814, SLR1 229,683, SLR2 143,164 primitive cells.
- All required marked groups pass: 9,474 marked primitive FFs survive.
- Exact-pair validation finds 515 failures: three response-tag RX bits tied
  directly to GND, plus all 512 Weight response data bits driven by RAMB
  DOUT/DOUTP pins instead of dedicated TX FFs. No other failure category was
  reported. Constant ties require explicit reporting; they do not represent
  an inter-SLR functional connection.
- The 512 RAMB-driven crossings are **not** exempted. Preserve only the Weight
  response transport's TX payload as standalone FFs, preventing output-register
  absorption. This maintains logical latency but requires new synthesis to
  establish the intended physical endpoint structure.

The checker itself also needed a runtime fix: repeated large dictionary
updates/lookups are costly inside Vivado Tcl. Local array accumulation and
lookup snapshots preserve the same ownership/duplicate/pair checks. A 100k
synthetic inventory completed in 7.34 seconds after this change; 1,000 lookups
in a 100k-entry map measured about 1.5 seconds with a dictionary versus
0.0016 seconds with an array. No replica coverage or physical check was dropped.

### Complete boundary-net scan

The separate read-only `slr_synth_boundary_preflight.tsv` checks all logical
partition-boundary nets, including paths whose entire marked data pipeline
was absorbed and therefore cannot appear in a surviving-FF-only inventory.
It reports 31,236 illegal cross-owner **pin connections**, classified exactly:

| Connections | Cause | Correction |
|---:|---|---|
| 30,720 | SLR1 prealigner Q pins directly drive SLR2 MXU DSP inputs; input data TX/RX stages were absorbed into DSP registers | Preserve both MXU input **data** FF banks as standalone TX/RX; leave constant/control fields optimizable |
| 512 | Weight response BRAM outputs directly drive SLR1 RX | Preserve Weight response TX **data bits only**, deriving the tag/data boundary from the interface |
| 4 | Two command-RX pointer LUTs are lifted to node-level `u_commands/u_rx`, outside the original bridge path and incorrectly classified as default SLR1 | Assign this known lifted RX helper family to SLR0 with its pointer FFs |

The 30,720 MXU connections originate at 2,304 distinct synthesized/replicated
prealigner source pins; this is **not** a count of additional pipeline FFs.
No other illegal connection family was found in this scan. These corrections
still require new current-source simulation and full source synthesis/physical
validation. Do not waive DSP/RAMB-driven crossings merely because the logical
pipeline latency is correct.

The preservation scope is deliberately narrow: primary MXU input data is
`32 * SEL_BLOCK_WIDTH = 32 * 12 = 384` bits per TX/RX bank, or 768 RTL FF bits
across both stages. The Weight response TX data contributes another 512 bits.
These are existing logical pipeline stages now forced to remain standalone,
not additional latency stages. They do not predict the final net FF delta:
hard-IP register settings, replication, and other optimization can also change.
Measure the new synthesized and placed resource reports before claiming a delta.

## Second normal source build: slr_v2

Started 2026-09-05 18:46 KST, after final MXU32/MXU16 unit suites and all twelve
primary W4 host-cycle comparisons passed. The same full source command above
uses `PREFIX=improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v2` and log
`build_slr_hw/full-implementation-slr-v2.log`; config and configure were refreshed
immediately before launch. No prior checkpoint is used for implementation.
The post-init hook now also produces `post_init_slr_boundary_nets.tsv` and fails
on unregistered cross-owner connections before placement. Results are pending.

### slr_v2 synthesis result

All 156 block synthesis jobs and top-level synthesis completed. Normal
implementation started at 19:43:31 KST. Kernel synthesis reports zero errors,
zero critical warnings, and 2,654 warnings. This is not a placement/timing pass.

| Kernel resource | slr_v1 (failed post-init) | slr_v2 | Difference |
|---|---:|---:|---:|
| LUT | 447,090 | 447,647 | +557 |
| FF | 309,789 | 309,020 | -769 |
| BRAM tiles | 403.5 | 403.5 | 0 |
| URAM | 156 | 156 | 0 |
| DSP | 2,273 | 2,273 | 0 |

Source: each run's `ulp_vortex_afu_1_0_utilization_synth.rpt`. Both columns are
kernel synthesis, excluding platform resources; this compares endpoint-preservation
revisions, **not** the complete SLR change against the pre-change RTL baseline.
Do not infer placed occupancy or congestion from these netlist totals.

### slr_v2 read-only structural preflight

At 19:48 KST, required ownership/profile groups and 10,754 marked FFs passed.
The complete partition-boundary scan passed, resolving the prior hard-IP data
absorption and lifted-pointer connection failures. Logical leaf ownership is
126,328 / 229,261 / 143,552 for SLR0 / SLR1 / SLR2, respectively (not placement).
MXU input now has 577 direct pairs, including the 384 data bits; Weight response
has 517 payload pairs including its 512 data bits.

However, strict pair validation reports two errors for one remaining connection:
`g_slr_mxu_weight_rx.payload_q_reg[valid]` has a LUT on D rather than a direct
marked TX Q; its corresponding TX valid is therefore unmatched. The LUT is
`g_slr_mxu_weight_rx.payload_q[valid]_i_1`. This is not waived as a data-path pass.
Read-only `build_slr_hw/slr_v2_valid_diagnose.log` confirms LUT2 `INIT=4'h2`,
I0 from TX valid Q, and I1 from the core reset relay: `TX_valid && !reset`.
The RX primitive is FDRE with R tied GND and CE tied VCC. A narrow
`EXTRACT_RESET="yes"` attribute is now applied to existing synchronous-reset
boundary declarations only; every sequential equation and cycle is unchanged.
Current-source simulation and a new full source run must verify the correction.

Evidence: `build_slr_hw/slr_v2_preflight_pairs.{log,tsv}` (exit 1) and
`build_slr_hw/slr_v2_preflight_boundaries.{log,tsv}` (exit 0). Both only read the
new kernel checkpoint; normal source implementation continues separately.

Normal `slr_v2` implementation subsequently reproduced exactly these two pair
errors in `impl_1/post_init_slr_links.tsv` and exited at 20:05:15 KST. No
placement or routing ran. All three full-SLR pblocks were created before the
pair check, with 126,376 / 229,283 / 143,552 assigned leaves after platform
linking and normal asynchronous-memory patching. Vivado reported nested-region
clipping and automatic pblock-property adjustments; the next source flow will
reapply and assert intended properties after cell assignment, logging the
actual effective ranges. Do not treat creation alone as physical legality.

The reset-extraction revision passes all five focused suites and all twelve
primary W4 host-cycle measurements; every sample is within 2 percent of the
frozen baseline. Its internal overlap compute median remains 630 versus 566
cycles and final store span 108 versus 84. New physical validation remains
necessary despite unchanged RTL equations.

## Third normal source build: slr_v3

Started 2026-09-05 20:08 KST, after iteration 7's five focused suites and twelve
primary W4 measurements passed. Same explicit U55C platform, 100 MHz clock,
Explore/AlternateCLBRouting, and normal source flow; fresh source config and
configure immediately precede make. Prefix is
`improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v3`; log is
`build_slr_hw/full-implementation-slr-v3.log`.

The flow now reapplies and verifies the three intended pblock properties
after adding cells, and reports `SNAPPING_MODE`, `GRID_RANGES`, and
`DERIVED_RANGES`. Fixtures verify recovery from automatic property changes and
failure if the requested property cannot be restored. No RTL/SLR assignment
or requested full-SLR range changes accompany this flow hardening.

Physical results are pending; neither prior attempt reached placement.

### slr_v3 kernel synthesis

Kernel `synth_design` passes with zero errors/critical warnings. Its completed
checkpoint was generated by 21:02 KST; read-only pair and full-boundary checks
then started independently of the continuing normal source implementation.
Kernel utilization: 447,646 LUT, 309,020 FF, 403.5 BRAM tiles, 156 URAM, and
2,273 DSP. Compared with `slr_v2`, this is exactly one fewer LUT and no change
to FF or hard-memory/DSP counts. It does not establish placement or timing.

### slr_v3 structural preflight: PASS

By 21:06 KST, both independent read-only checks exited 0:

- `build_slr_hw/slr_v3_preflight_pairs.{log,tsv}`: required hierarchy/profile
  and marked groups pass; all direct FF-pair checks pass across 10,754 marked
  boundary FFs. The formerly failing Weight RX valid connection is now direct.
- `build_slr_hw/slr_v3_preflight_boundaries.{log,tsv}`: complete logical
  partition-boundary scan passes, including hard-IP absorption and helper logic.
- Logical owner leaves: SLR0 126,328; SLR1 229,261; SLR2 143,551.

Normal source implementation started at 21:05:13 KST. These are **synthesized
structure checks, not placed SLR/Laguna utilization or routed timing results**.
Actual pblock properties/ranges, FF placement, and routing remain pending.

### slr_v3 actual post-init floorplan gates: PASS

By 21:29 KST, the normal full-platform implementation passed all SLR init
gates after its standard asynchronous-memory patching:

- Three nonempty pblocks, each with `IS_SOFT=0`, `CONTAIN_ROUTING=0`, and
  `EXCLUDE_PLACEMENT=0` verified **after** cell assignment.
- Requested `GRID_RANGES` remain SLR0/SLR1/SLR2. Vivado's `SNAPPING_MODE=NESTED`
  clips effective `DERIVED_RANGES` to the platform dynamic region; all actual
  ranges are logged in `impl_1/runme.log`, not assumed from the requested SLR.
- Required profile/ownership and marked groups pass.
- `impl_1/post_init_slr_links.tsv` passes exact FF pairs; the full design has
  13,502 marked FFs globally, of which 10,754 belong to the GEMM SLR partition.
- `impl_1/post_init_slr_boundary_nets.tsv` passes the complete partition scan.

The flow proceeded to init methodology reports. This is the first candidate
to pass actual platform post-init. Actual SLR/Laguna placement, legal routing,
congestion, WNS and WHS remain unverified until their later reports complete.

The pre-placement `post_init_timing_summary.rpt` reports WNS -1.107 ns at one
setup endpoint and WHS -0.606 ns. The sole setup failure (line 8988) is platform
`ulp_ucs/...clock_throttling_aclk_kernel_01/U0/Gate_Fast_d1_reg` to
`GC.FCLK/CE`, under the **500 MHz / 2 ns** secondary platform clock, with zero
logic levels and -2.634 ns clock skew. It is not a GEMM 100 MHz setup failure.
Both kernel clock configuration (10 ns for clock 00) and all relevant final
clock groups must still be checked after placement/routing; no exception or
clock change is made to hide this initial estimate. Unrouted hold estimates
are likewise not a final routed-hold result.

`opt_design` completed successfully in 4:25 elapsed, followed by successful
post-opt QoR assessment (6:51 elapsed). The standard optimized checkpoint is
being written as of 21:52 KST. The cumulative log retains the platform
`Ip 78-110 Invalid part string Project` diagnostic from the generated init
hook, but it did not abort `opt_design`; distinguish it from a new SLR gate
failure. A read-only post-opt pair/receiver-enable audit is queued to check
that implementation optimizations preserve the intended boundary structure.

### slr_v3 post-opt audit: PASS; placement feasibility: FAIL

The standard optimized checkpoint was written before placement. Independent
read-only inspection reports 10,751 owned marked FFs and 5,408 valid direct
TX/RX pairs. The full logical boundary-net scan passes. All 5,408 checked RX
CE pins are driven by literal constants; no remote CE fanin was introduced.
Evidence: `build_slr_hw/slr_v3_post_opt_audit.log` and the accompanying
`slr_v3_post_opt_{pairs,boundaries,rx_ce}.tsv` files. This audit did not run
optimization or placement and is not a checkpoint implementation retry.

At 22:00, normal `place_design -directive Explore -retiming` stopped during
Phase 1.2 with `Place 30-642`. In `impl_1/runme.log:1877`, the two cells in
one placement shape have different pblocks:

- `.../u_compute_core/gen_accumulator[0].u_accumulator/g_latency1.xil_f32add_inst/U0/i_synth/HAS_ARESETN.sclr_i_reg_xlnx_opt`
  (LUT1): ROOT.
- The associated `.../HAS_ARESETN.sclr_i_reg` (FDRE): `pblock_gemm_slr1`.

This is a generated-cell membership conflict, **not evidence of routing
congestion or SLR resource exhaustion**. Post-init assigned existing leaves;
optimization subsequently introduced a LUT that was not covered by that
leaf list. Logical name-based ownership validation alone does not prove actual
pblock membership. The corrective flow must refresh known logical owners
after optimization and before placement, check actual membership, and keep
the existing hard full-SLR assignment. It must not weaken pblocks or exempt
the failing shape. Independent checkpoint inspection is checking the exact
generated-cell properties while regression fixtures are added.

The completed post-opt membership inspection refines the lifecycle diagnosis:
the failing `_xlnx_opt` reset LUT does **not** exist in the standard opt DCP.
It is created inside placement, so refreshing post-opt leaves alone is
insufficient. Separately, 512 existing ACC LUT2 leaves have only
`pblock_dynamic_region` membership instead of SLR1 (496,045 owned leaves
already match). These are `ADDSUB/LOGIC_LOW_LAT.OP/EXP/LUT_NI[*].LUT_AMB`
and `LUT_BMA` primitives. Both cases require attention: refresh existing leaf
membership and anchor only validated homogeneous floating-point IP hierarchies
so later local helpers inherit the same owner. All 96 matching original reset
FFs are SLR1-owned; the affected IP families also include output multiplication.
Evidence: `build_slr_hw/slr_v3_post_opt_membership.{log,tsv}`. No RTL latency or
logical SLR assignment changes are necessary for this correction.

No post-place Laguna results, routed-net legality, or final WNS/WHS exist for
this attempt. The failed build and its reports are retained unchanged.

## Fourth normal source build: slr_v4

Started 2026-09-05 22:24 KST, after fresh primary W4 config/configure and the
ownership-lifecycle flow correction. RTL is unchanged from iteration 7's
passing simulation. New post-opt fixture: 47 checks PASS; existing SLR
fixture PASS; congestion fixture: 24 PASS; INI/Makefile: 10 PASS, including
the generated hook and actual source snapshot. No OOC or checkpoint
implementation retry is used.

The same source-build command uses prefix
`improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v4` and log
`build_slr_hw/full-implementation-slr-v4.log`. The new OPT_DESIGN post-hook
refreshes existing leaf membership and anchors all three local FP IP families
(FP16 input scaling, FP32 accumulation/output scaling) after proving every
nonconstant descendant belongs to SLR1. No mixed-owner parent is attached.
Actual placement inheritance and routed timing remain pending.

### slr_v4 kernel synthesis: PASS

By 23:21 KST, `synth_design` and checkpoint writing completed successfully:
0 errors, 0 critical warnings, 2,654 warnings. Kernel resource counts are
447,646 LUT, 309,020 FF, 403.5 BRAM tiles, 156 URAM, and 2,273 DSP: exactly
the same as `slr_v3`. This confirms no synthesized resource delta for the
Tcl-only lifecycle correction; it does not compare the complete RTL change
against the merged functional baseline or establish physical timing closure.

All 156 block jobs completed by 23:23 KST; top-level synthesis passed and
normal implementation started at 23:25:11. Actual post-init/post-opt
membership and place-created helper inheritance are the next physical gates.

### slr_v4 actual post-init gates: PASS

By 23:50 KST, all three user pblocks pass post-assignment
`IS_SOFT=0`, `CONTAIN_ROUTING=0`, `EXCLUDE_PLACEMENT=0` checks. Required
marked groups and direct pairs pass with 10,754 owned marked FFs (13,502
platform-wide). The full boundary scan completes and execution proceeds to
init methodology reports. This repeats the previously passing post-init
contract; the new post-opt lifecycle correction and actual placement remain
to be demonstrated.

### slr_v4 opt_design: PASS; post-opt hook: FAIL

`opt_design` completed successfully (5:00 elapsed) and the standard Vitis
post-opt QoR assessment completed (7:29 elapsed). The custom hook ran after
the Vitis and platform post-opt hooks, as verified in generated
`scripts/impl_1/_full_opt_post.tcl`. Its inventory passed with logical-owner
counts 125,747 / 227,259 / 143,551, then failed at 00:13:08 with bare
`VPL_TCL 101-2 __DUMMY_KEY__`, before an anchor or refresh success message.
Placement did not start; no physical closure is claimed.

At the 00:45 continuation, source comparison identifies a relevant API
difference: the previous successful membership audit first resolves canonical
names with `get_cells`, then queries `PBLOCK` on the returned object collection;
the new checker queries the relationship property directly on strings.
This is a **hypothesis pending actual Vivado reproduction**, not yet a proven
root cause. An independent one-open checkpoint diagnostic will capture full
Tcl error stacks for both forms. No optimization, placement, routing or
checkpoint implementation retry is part of that API diagnosis.

### Actual API reproduction and correction

The one-open Vivado 2025.1 probe reproduces the invalid query form even with
one canonical cell-name string: `get_property PBLOCK $names` fails with
`Common 17-161 Invalid option value`. Resolving the same names with
`get_cells -quiet $names` and querying that object collection succeeds,
including all 125,747 SLR0 leaves. The bare VPL `__DUMMY_KEY__` wrapper symptom
is not separately reproduced; do not claim its internal formatting mechanism
is known.

The corrected `cell_properties` helper explicitly resolves objects, verifies
exact name/count/uniqueness coverage, and remaps values to the requested name
order. PBLOCK, PARENT and IS_PRIMITIVE calls use it. The post-opt hook remains
enabled and now emits stage-specific context plus Tcl error stacks. New
lifecycle/API fixture: 53 PASS; existing SLR fixture, congestion24 and
INI/Makefile10 also PASS. The candidate full-SLR0 membership check passes
in actual Vivado (4.085 seconds). Remaining groups and the complete hook
are being tested in the same diagnostic process before another source build.

The complete-hook preflight may alter constraint membership **only in the
temporary in-memory diagnostic design**. It must not call opt/place/route,
write a checkpoint, save a project, or modify the retained failed build.
This is an API/constraint test, not a DCP implementation retry. The subsequent
physical result must still come from the normal source flow.

### First complete in-memory corrected hook: PASS

`build_slr_hw/slr_v4_capped_preflight.log` confirms the complete current-source
hook passes in actual Vivado (246.763 seconds). All 96 homogeneous FP
`i_synth` parents were attached to SLR1, the 512 missing SLR1 leaves were
recovered, and all hard-pblock properties, direct FF pairs and full boundary
checks passed. Independent strict after-checks find zero missing members
in all three groups and verify exactly 96 correctly assigned parents.
An idempotence rerun and a bounded post-place API audit remain in progress.

The original uncapped comparison was terminated only after validating its
exact diagnostic PID/cwd/arguments: huge invalid-name-list error output was
dominating runtime. Its logs are preserved. The replacement preflight uses
capped errors and file-backed console output; no source hardware job or
unrelated process was stopped.

### Corrected hook idempotence and API audit: PASS

The second actual hook execution also passes. The capped preflight reports
`total_failures=0`: all 496,557 owned leaf memberships and exactly 96 FP
parent memberships match, all properties pass, and direct pairs/full boundary
checks pass on both runs. The second run starts with zero missing members in
every group, establishing idempotent ownership refresh on this netlist.

The additional `get_slrs` audit accepts both a single raw name and a resolved
object, as well as resolved complete groups. Empty results are expected from
this **unplaced** checkpoint and do not prove SLR/Laguna placement. Unlike
`get_property`, this is not a demonstrated second API defect; no speculative
query change was made. The diagnostic design is closed without saving.

Evidence: `slr_v4_capped_preflight.log:1424` (zero accumulated hook/strict
failures), `:1429` (complete preflight PASS), `:1470` (get_slrs API checks
PASS), under `build_slr_hw`. Post-opt hook remains enabled as requested.

## Fifth normal source build: slr_v5

Started 2026-09-06 01:26 KST after sourcing the primary TH16/MXU32/W4 config
and reconfiguring `build_slr_hw`. Same explicit U55C platform,100MHz,
Explore/AlternateCLBRouting and normal source make; post-opt hook remains
enabled. Prefix is `improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v5`,
log `build_slr_hw/full-implementation-slr-v5.log`.

RTL is unchanged from simulation iteration7. The change relative to slr_v4
is explicit cell-object resolution for property queries and contextual hook
error reporting. All actual API/full-hook checks pass before launch; actual
VPL execution and placed/routed results still require this new run. No OOC or
checkpoint implementation retry is used. The diagnostic exited0 without
saving at01:25:03 and its evidence remains available.

At02:21 KST, kernel synthesis passes with0 errors,0 critical warnings and2654
warnings. The synthesis utilization report exactly matches slr_v3/v4:
LUT447646,FF309020,BRAM403.5 tiles,URAM156,DSP2273. The hook-only correction
does not change kernel synthesis resource use. Source and build-snapshot
SHA256 hashes match for the post-opt hook, floorplan and SLR report scripts;
the generated INI retains `OPT_DESIGN.TCL.POST`.

All156 block jobs and top synthesis complete; VPL implementation starts
at02:25:22 KST. `link_design` completes with0 errors. Post-init SLR checks
pass: all9 hard-pblock property values remain0, marked-group/direct-pair
validation passes with10754 owned marked FFs, and the boundary scan returns
without an error. By02:54, pre-opt QoR assessment is running; the corrected
post-opt hook and placement still need confirmation in this normal run.
Previously documented platform warnings (`dont_partition.xdc:1` and
`Ip78-110`) recur without terminating this initialization sequence.

### Actual normal-run post-opt hook: PASS

By03:14 KST, `opt_design` has completed normally in4:43 and its post-opt QoR
report in6:59. The corrected user hook performs all three typed primitive
ownership queries without the earlier `__DUMMY_KEY__` failure. It anchors96
homogeneous FP parents in SLR1 and recovers exactly512 missing SLR1 leaves;
SLR0/SLR2 have no missing leaves. All9 hard-pblock property checks pass, as
do marked-group and direct-pair validation with10751 owned marked FFs.

Evidence in the slr_v5 `impl_1/runme.log`: ownership queries at1848-1850,
96 anchors at1853, and ownership refresh at1860/1868/1875. Reports are
`post_opt_slr_links.tsv` and `post_opt_slr_boundary_nets.tsv`. The normal
flow continues beyond the hook. This resolves the hook API failure;
actual place-created reset-helper inheritance and final routing/timing are
not yet established by this result.

### Placement: same lifecycle defect in TMEM arbiter

The normal run reaches `place_design` at03:17 and fails at03:23:27 KST;
session80692 exits2. The post-opt API correction remains verified. However,
the FP-only parent anchoring is insufficient: a **different** reset helper
now forms a shape whose members have different placement owners.

`impl_1/runme.log:1925` reports `Place30-642` for the following common path
under `gemm_node`:

```text
u_tmem_subsystem/u_switch_input/rsp_arb/
  g_input_select.g_arbiter.arbiter/g_round_robin.rr_arbiter/
  g_model1.reqs_mask_reg[0]           FDRE  pblock_gemm_slr0
  g_model1.reqs_mask_reg[0]_xlnx_opt LUT1  ROOT
```

The newly inserted helper and original FF must form one placement shape,
but leaf-only ownership constrains only the original FF. Anchoring96 FP
parents did not protect this independent TMEM arbiter hierarchy. This is
an implementation-feasibility failure **before legal placement/routing**;
it does not provide a new congestion or routed timing result.

Next correction: retain wholly single-SLR hierarchy islands, rejecting
mixed or unowned subtrees, while keeping strict leaf checks and explicit
transport endpoint ownership. Audit any owned FFs directly in mixed parents
before launching a new normal source run. This generalizes the ownership
contract rather than enumerating each failing reset-register name. RTL and
iteration7 simulation results remain unchanged.

### General hierarchy coverage preflight

The first independent read-only graph audit stops on an actual DSP primitive
container: `I_KT_STRIDE_FULL_q1/DSP_ALU_INST` has a primitive PARENT, absent
from an IS_PRIMITIVE0-only hierarchy inventory. The corrected algorithm
traverses these composite primitive nodes without selecting them as anchors;
all child ownership still contributes to the enclosing hierarchy decision.
The first diagnostic closes without any constraint mutation; its evidence is
retained in `build_slr_hw/slr_v5_hierarchy_audit.log`.

The corrected second audit (`slr_v5_hierarchy_audit_v2.log`) and exact candidate
selector independently agree on189 maximal islands: SLR0=27,SLR1=161,SLR2=1.
All96 FP reset FFs and all8 input-switch mask registers are covered. The failed
arbiter's highest uniform ancestor is `u_tmem_subsystem/u_switch_input`.

Both the failed arbiter FF and an ACC `sclr_i_reg` are already FDRE before
placement, with D driven by reset BUFGCE and R tied to GND. The arbiter has
INIT0 and local CE; ACC has CE tied to VCC. This disproves a specific
FDSE-to-FDRE conversion hypothesis; the precise internal reason for placer
LUT insertion is not established. Across the design, all100 owned FFs whose
D is directly BUFG-driven lie inside selected anchors; the uncovered count
for this observed failure pattern is0.

These100 endpoints split into96 FP reset FFs and4 TMEM round-robin FFs
(input,scale,zero-point,output switches). General anchoring covers the
three further arbiter cases as well as the one reported by the failed placer.

There are still39187 other owned FFs directly in mixed containers without a
homogeneous ancestor: FDCE33481,FDRE5702,FDPE4 (FDSE0). They retain explicit
per-leaf placement ownership; do not claim universal future-helper inheritance
for them. The exact current-source complete hook and idempotence preflight
are running. No placement/routing/save commands are used in this diagnostic.

The first complete generalized-hook attempt stops **before any anchor
application** on a second concrete API return-shape difference. SLR0's27
anchors and SLR1's161 anchors return complete PBLOCK lists, including empty
entries. SLR2 has just one `u_mxu` anchor; its unset PBLOCK returns a scalar
empty string, whose Tcl list length is0. This is not dropped elements in
multi-object queries. `cell_properties` now normalizes the singleton scalar
to one list element, retaining exact resolved-object/name/cardinality checks.
Actual-shaped fixtures59 plus hierarchy63 pass. The same open diagnostic
design is retained for the corrected full-hook/idempotence checks.

The corrected full hook's first actual execution passes in282.811 seconds,
with189 anchors attached, all hard properties and exact FF-pair/boundary
checks passing. All six independent after-checks also pass: complete owned
leaf membership and selected-anchor membership for each of SLR0/1/2. The
idempotence rerun is in progress in the same unsaved diagnostic design.

The second corrected hook also passes in281.960 seconds. All12 independent
after-run leaf/anchor checks pass across both runs. Final actual evidence:
`slr_v5_hierarchy_audit_v2.log:4283`,
`TOTAL_FAILURES=0 residual_global_D_uncovered=0`. The diagnostic closes
without saving and exits0 at04:05:06 KST. Source `floorplan.tcl` SHA256 is
`625af38e6716c5a0d16135a63aa12faf387a581efe4f5823ca591ea900102150`.

## Sixth normal source build: slr_v6

Started2026-09-06 04:05 KST after sourcing the primary TH16/MXU32/W4 config
and reconfiguring `build_slr_hw`. Same explicit U55C platform,100MHz,
Explore/AlternateCLBRouting and congestion fail-fast disabled; independent
SLR hooks, including post-opt, remain enabled. Prefix:
`improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v6`.
Log: `build_slr_hw/full-implementation-slr-v6.log`.

RTL remains the iteration7 simulation-verified source. The flow-only delta
from slr_v5 is general single-owner hierarchy anchoring, primitive-container
parent traversal and singleton property normalization. No OOC or DCP
implementation retry is used. Actual normal-run hook adoption, placement
feasibility, legal routing and final setup/hold still need this new run.

Kernel synthesis completes with0 errors,0 critical warnings and2654 warnings.
At04:58 its resource report exactly matches slr_v3/v4/v5: LUT447646,FF309020,
BRAM403.5,URAM156,DSP2273. All blocks and top synthesis pass; normal VPL
implementation starts05:01:54 KST. The generated build snapshot has the
same `floorplan.tcl` SHA256 as the successful actual preflight and retains
the post-opt hook. Physical placement/routing remains pending.

### Actual generalized post-opt hook: PASS

By05:50 KST the normal slr_v6 run passes `opt_design` and the generalized
post-opt hook. All189 retained anchors are adopted (27/161/1), all96 local FP
reset paths are covered, and512 missing SLR1 leaf memberships are recovered.
All9 hard-pblock properties remain0 and marked/direct-pair checks pass with
10751 owned marked FFs. Uncovered leaf/FF counts exactly match preflight.

Evidence: slr_v6 `impl_1/runme.log:1853` verifies FP96 coverage;1854-1856
record the three anchor counts;1857-1860 record uncovered leaves/FF types;
1867/1875 and the following SLR2 line record ownership refresh. Placement
has not yet established successful future-helper inheritance or legal routing.

### Previously failing placer feasibility phase: PASS

The normal source run completes placer Phase1.2 (IO/clock placement and device
construction) and enters Phase1.3 Build Placer Netlist Model. Phase1.2's
cumulative elapsed time is5:28. The previous `Place30-642` ROOT/user-pblock
reset-helper conflict does not recur. This establishes progress beyond both
earlier shape-feasibility failures, not completion of placement or routing.
Actual SLR/Laguna mapping and final physical timing remain pending.

### Normal place_design completes, physical acceptance still open

At07:25 KST, `place_design` completes successfully in1:33:06. The earlier
reset-helper shape conflict is eliminated in the actual normal source run.
However, the placer reports interim WNS=-0.445ns and `Place46-14` high
congestion. These are not a routing-failure result, but neither timing nor
routability acceptance is established. Detailed placed timing and actual
SLR/Laguna validation are the next checks; final routed setup/hold remains
required. The earlier `Place30-1021` additional legalization-search warning
did not prevent successful placement.

### Post-place lookup failure, not a proven placement mismatch

At07:31:43 KST the post-place hook stops with
`pblock_gemm_slr0 cells occupy unexpected SLR(s):` and an empty returned
SLR list. `slr_floorplan_report.tcl` passes canonical NAME strings to
`get_slrs -of_objects`; installed Vivado2025.1 help explicitly requires
objects from `get_cells` or another `get_*` command. The earlier preflight
compared empty raw/typed results on an unplaced design, which was not a
valid placed-cell lookup test. Typed resolution and known-placed-cell
runtime verification are required before the next normal source run.
Do not interpret an empty query result as evidence that the cells physically
occupy the wrong SLR, and do not disable the post-opt/post-place gates.

The main build exits2 before routing. The generated normal flow saves
`level0_wrapper_placed.dcp` only after the post-place hook, so this run retains
the optimized DCP but no standard placed DCP. No checkpoint implementation
retry is used.

### Final placed timing: 100MHz SLR1-local control bottleneck

Source: slr_v6 `impl_1/hw_bb_locked_timing_summary_placed.rpt:160` and254.
All467 setup-failing endpoints use the10ns/100MHz kernel00 clock:
WNS=-0.438ns,TNS=-69.984ns. Kernel01 at500MHz has WNS+0.365ns;
HBM at450MHz has WNS+0.120ns. These results supersede the intermediate
placer WNS=-0.445ns, and must not be confused with an earlier unplaced
platform clock-throttling path.

All five worst setup paths start at `u_VX_gemm_ctrl/sync_regs_q_reg[6][3]`
(Weight storage region1 load-progress bit3), and every listed data-path
cell belongs to `pblock_gemm_slr1`. Common hierarchy prefixes are omitted:

| Report line | Endpoint | Slack ns | Logic / net ns | Levels |
|---|---|---:|---:|---:|
|2129|Zero-point local DMA `cmd_valid_r_reg[1]/D`|-0.438|2.350 /7.539|28|
|2335|Child queue0 `ram_reg_2/ENARDEN`|-0.408|2.631 /6.962|32|
|2557|Scale response RAM `ram_reg_6/ENARDEN`|-0.404|2.834 /6.523|30|
|2771|Child queue0 `ram_reg_8/ENARDEN`|-0.392|2.631 /6.891|32|
|2993|Input local DMA `cmd_request_r_reg[0][22]/R`|-0.392|2.631 /7.082|32|

Functional RTL chain (paths relative to `hw/rtl/core/gemm/`):

1. `VX_gemm_ctrl.sv:650,667` exposes registered Weight load progress.
2. `VX_gemm_compute_core.sv:1710` compares the required Weight generation
   and forms `compute_ready`. Ready propagates backward through the
   prealigner/meta pipe and input scaler at1358,1377,1344,1322.
3. Input acceptance at1235,1270 generates the QROW Scale-consume event at
   657,670, connected as `gemm_sync_if[2].valid` in `VX_gemm_node.sv:1007`.
4. `VX_gemm_ctrl.sv:542,570,717` adds the **same-cycle** consume increment,
   selects effective synchronization state and compares dependencies.
5. Dependency release and child start at822,1229 reach local-DMA command
   acceptance and storage in `VX_gemm_stream_dma_queue.sv:359,549`.

The Scale-RAM endpoint branches from the same consume-next state through
the writer fence (`VX_gemm_ctrl.sv:659`, `VX_lmem_dma_misal.sv:1423`),
sink turnover/next-slot selection and RAM read enable
(`VX_gemm_stream_dma_queue.sv:315`). Thus these are manifestations of one
long readiness/consume/dependency chain, not five independent SLR-crossing
failures. Routing contributes69.7–76.2 percent of the reported data delay.
Do not infer repeated RAM accesses merely from synthesized intermediate
hierarchy names after logic sharing/movement.

The existing pre-opt0.300ns setup margin produces0.358ns total uncertainty.
Even arithmetically removing just that margin leaves -0.138ns for the worst
placed path; it is not solely a margin issue. Overall placed WHS is -0.370ns
with19257 failing hold endpoints (17522 on kernel00). These include estimated
delays before routing/hold repair. Legal routing and final setup/hold closure
are still required; no additional control-pipeline RTL change is claimed here.

### Placed device occupancy and SLL pressure

The full-design placed utilization report (not kernel-only synthesis),
`hw_bb_locked_utilization_placed.rpt:441,482`, provides these measurements:

| Metric | SLR0 | SLR1 | SLR2 |
|---|---:|---:|---:|
| Occupied CLBs |52357 (95.26%)|41017 (75.96%)|22884 (42.38%)|
| LUT utilization |61.93%|48.74%|26.56%|
| Register utilization |30.00%|21.77%|6.78%|
| Unique control sets |5938|4415|1401|
| URAM |96|60|0|
| DSP |128|449|1700|

SLR0 occupied CLBs exceed the plan's80-percent review threshold despite
only61.93-percent LUT utilization. This is a packing/placement pressure
warning, not evidence that95.26 percent of LUTs are consumed. Counts include
platform/HMSS and non-GEMM logic and cannot be attributed entirely to DMA.
SLR2 is used substantially more by the MXU/DSP placement, but SLR0 still
remains physically crowded. The high-congestion warning is therefore
consistent with measured occupancy; a causal per-region routing analysis
is still needed.

SLL usage is11675/23040 (50.67%) across SLR0/1 and7496/23040 (32.53%)
across SLR1/2, both below the65-percent review threshold. Global registered
TX/RX pairs exist (1348 across SLR0/1,2180 across SLR1/2), but these totals
include platform signals and do not prove each required GEMM link group
uses Laguna. The strict per-group post-place validation must still run.

### Timing contingency, not implemented in slr_v7

Keep the next flow-only run on the simulation-verified RTL so that post-place
validation and routed results can be observed without mixing another RTL
experiment. If the common local control path remains critical, prioritize:

1. Specialize local Input/Weight/Scale/Zero-point **issue** dependency checks
   to the actual T0/T1 producer contract. The FSM generates this restriction
   at `VX_gemm_fsm.sv:1883,1925,1960,2153`, and checks that consume waits
   remain writer metadata at2613. The generic synchronization selector in
   `VX_gemm_ctrl.sv:717` currently admits unsupported consume dependencies.
   An explicitly opted-in specialization, with generic fallback and protocol
   assertions, could remove those connections without FF/cycle changes.
   Use `sync_t0_next/sync_t1_next` to retain same-cycle tile completion.
2. For the real Scale writer fence, compare both registered-count candidates
   (current and32-bit current+1) against the target in parallel, then select
   with the late consume event. Preserve wrap semantics; a simple OR is not
   generally equivalent. This requires a local count/event interface split
   at `VX_gemm_ctrl.sv:659` / `VX_lmem_dma_misal.sv:1423` and may add LUT/CARRY
   resources, but does not inherently add a cycle.
3. Only if necessary, replace the existing prealigner final data **and**
   metadata stages (`VX_prealigner.sv:254`,
   `VX_gemm_compute_core.sv:1348`) with a coordinated two-entry registered-
   ready buffer. Replacement, not an appended stage, can preserve unstalled
   forward latency while breaking reverse ready. It adds one result plus
   metadata entry and needs additional stall/alignment/consume verification.

These are RTL design candidates, not timing exceptions or permission to delay
command done. No candidate above is part of the current implemented result.

### Actual placed-object lookup preflight: PASS

`build_slr_hw/slr_v6_placed_api_probe.log:1025` records32 physical SLICE
FF samples:32 pass,0 errors,32 raw-NAME queries empty. Typed-cell queries
and independently resolved typed-site queries agree on nonempty SLR1/SLR2.
The current source `cell_objects` helper passes single,32-cell and reversed
request tests at1034–1036. Three real placed FF Q-to-D pairs pass the same
LOC/BEL/SLR APIs used by link validation at1057. Exact full GEMM group
resolution also passes for125747/227259/143551 cells; those GEMM cells are
unplaced in this optimized checkpoint and are not counted as placement proof.

The first diagnostic sample was an IBUF composite selected only by nonempty
LOC and failed to map. That selection was not a valid physical-FF canary;
the failed attempt remains in the log. The corrected probe explicitly uses
FD* primitives with SLICE placement and matching cell/site SLRs. This
distinguishes the actual raw-name API defect from the initial weak probe.
No placement/routing/constraint mutation or checkpoint save is performed.

## Seventh normal source build: slr_v7

Started2026-09-06 07:48 KST after primary TH16/MXU32/W4 config and configure,
using the same explicit U55C platform,100MHz,Explore/AlternateCLBRouting,
congestion fail-fast disabled and independent SLR hooks enabled. Log:
`build_slr_hw/full-implementation-slr-v7.log`, main session79546. The actual
API diagnostic exits0 unsaved at07:47:49 before implementation begins.

The flow-only delta is strict typed-cell post-place SLR lookup plus a
failure-only, non-overwriting placed diagnostic snapshot. RTL remains the
iteration7 simulation-verified source. No OOC or DCP implementation retry.
Source SHA256 values:

- `floorplan.tcl`: `25de922453fa8ce5fe131ef37550ef79de09acaea81ca6ec6567ae453195595f`
- `slr_floorplan_report.tcl`: `af497a47c73176fa3ea4ebce00ace4e9705f7e40054a2ae42b4f6331a2b962e2`
- `post_place_hook.tcl`: `7272f6b8f8f1fd86eefdc5bf59f14f670473a3951bfcbae2ba90486ccef930cd`

Actual post-place SLR/Laguna validation, routing legality and100MHz final
setup/hold remain required. Prior placed timing and occupancy warnings are
not resolved merely by fixing the Tcl query.

At08:41 KST the kernel synthesis report has0 errors,0 critical warnings and
2654 warnings. Resources exactly match slr_v3/v4/v5/v6: LUT447646,FF309020,
BRAM403.5,URAM156,DSP2273. Thus the flow-only correction produces no
synthesized resource change. Top/link implementation and physical gates
are still pending at this point.

All156 blocks and top-level synthesis subsequently pass. Normal VPL
implementation starts08:44:05 KST; all SLR hooks remain enabled.

By09:06 KST, `link_design` and post-init gates pass: all9 hard-pblock
properties are0,10754 owned marked FFs pass exact Q/D pair validation, and
the full boundary scan returns successfully. Normal methodology reports
follow; post-opt, placement and routed acceptance remain pending.

By09:32 KST, `opt_design` and the actual generalized post-opt hook pass.
All189 hierarchy anchors are adopted (27/161/1),96 FP reset parents are
covered,512 missing SLR1 leaves are restored, and all9 hard properties
remain0. Exact pairs pass for10751 owned marked FFs; full boundary scan
also returns successfully. The hook remains enabled, with no recurrence
of the earlier query or post-opt ownership failures. Actual placement,
typed post-place SLR/Laguna validation and final routed acceptance remain.

At09:42 KST the normal placer passes Phase1.2 (cumulative5:28) and enters
Phase1.3. The earlier reset-helper ROOT/user-pblock shape conflict does not
recur. This is successful feasibility, not completed placement or routing.

At10:40 KST global placement completes (cumulative1:03:22) and Phase3
Detail Placement starts. No placement abort has occurred; final placed
and routed acceptance remain open.

At11:12 KST `place_design` completes successfully in1:36:18. The prior
reset-helper shape conflict does not recur. Intermediate post-replication
WNS=-0.445ns matches slr_v6. Detailed placed reports are generating; the
corrected typed post-place SLR query and actual per-group Laguna mapping
must still pass before normal routing. This is not timing closure.

Read-only v7/v6 report comparison at11:15 KST: the101679-line placed timing
report differs only in its date header. All paths, clocks, physical locations,
delays and setup/hold results are identical: WNS=-0.438ns,TNS=-69.984ns,
467 setup-failing endpoints; WHS=-0.370ns,THS=-1157.145ns,19257 hold-failing
endpoints. The five SLR1-local paths documented above are unchanged.
The531-line utilization report preserves every resource total, SLR occupied
CLB and SLL count; only one register-front LUT changes used/unused packing
classification (not LUT/FF totals). Thus SLR0 CLB95.26 percent and SLL
50.67/32.53 percent are unchanged. High-congestion warning `Place46-14`
also remains. The hook-only correction does not improve placement QoR;
its purpose is to permit correct validation and subsequent normal routing.

### Actual corrected post-place hook: PASS

By11:23 KST all three typed-cell actual-SLR queries pass in the normal
source implementation:125761 leaves in SLR0,227583 in SLR1,143558 in SLR2.
All9 hard-pblock properties,10747 owned marked FFs/direct Q-to-D pairs,
per-group nonzero Laguna TX/RX mapping and full boundary-net checks pass.
The hook prints `congestion fail-fast disabled; independent SLR checks
completed`; this disables only the explicitly selected congestion early
gate, not SLR verification. The former empty SLR0 lookup failure is fixed.

Actual mapping is **not all-bit Laguna coverage**. The existing acceptance
gate requires at least one real TX/RX pair per group; the TSV records the
complete counts. Selected large groups from `post_place_slr_links.tsv`:

| Link group | Direct FF pairs | Both endpoints in Laguna |
|---|---:|---:|
| MXU input |573|385|
| MXU Weight |549|514|
| MXU output |1281|1281|
| HBM DMA command payload |231|231|
| TMEM Input response payload |517|1|
| TMEM Scale response payload |517|1|
| TMEM Zero-point response payload |517|1|
| TMEM Weight response payload |517|515|
| TMEM output-write request payload |543|543|

Every one-bit credit group maps1/1. Do not infer that the three1/517
response groups have their wide data banks in Laguna merely because their
group-level gate passes. Exact ownership/direct-pair checks pass for their
remaining bits, but routability/timing still require the normal routed result.
No physical acceptance or timing closure is claimed from this hook alone.

Field-level TSV audit clarifies the partial mappings: for each Input/Scale/
Zero-point response, all512 data bits and four surviving tag bits have a
normal SLICE TX and Laguna RX; the valid bit alone maps to both Laguna
endpoints. Thus these are RX-only data mappings, not unregistered crossings
or missing RX pipelines. Response payload is `{data,tag}`; tag width7 means
data indices7–518, with constant tag bits4–6 removed. Weight's512 data bits
all map to both endpoints; its two RX-only exceptions are tag bits1 and3.
MXU input384 data pairs and MXU Weight512 data pairs also all map to both;
their partial mappings are metadata/replicas. No reported pair has neither
endpoint in Laguna. Only Weight currently enables response-TX payload
preservation in `VX_tmem_subsystem.sv:483`; this is an RTL difference, not
by itself proof of causation. A bounded read-only placed-netlist audit is
used to investigate the TX mapping without changing the ongoing run.

### Normal pre-route physical optimization

At11:36 KST `phys_opt_design` completes successfully in11:29 after the
post-place gates pass. Final estimated WNS=-0.327ns,TNS=-48.775ns improves
on placed timing but still fails setup before routing. The cumulative
error count includes the earlier platform `Ip78-110 Invalid part string
Project` at `impl_1/runme.log:1404`; the optimizer itself reports successful
completion. A normal physical-optimization checkpoint is saved next. Legal
routing, final setup/hold and final-state boundary verification remain open.

### Read-only diagnosis of response TX placement

`build_slr_hw/slr_v7_response_mapping_audit.log` and its companion TSVs
compare representative data bits100/300,tag0 and valid for all four read
streams in the actual placed checkpoint. The diagnostic closes unsaved
at11:39:12 KST with exit0, freeing its memory before routing. It performs
no opt/place/route, constraint mutation or checkpoint save.

Measured properties:

- Every sampled TX Q has exactly one remote RX D sink, no extra/local sink.
- Both endpoints retain `USER_SLL_REG=1`; `IS_LOC_FIXED` and `IS_BEL_FIXED`
  are0 for all samples.
- The data paths use the same clock; TX CE is a per-stream LUT4, TX reset
  is GND, RX CE is VCC and RX reset is GND. No obvious control-type
  incompatibility explains the mapping difference.
- Input/Scale/Zero-point data TX D is driven by MUXF7; driver and TX FF
  occupy the same SLICE (`F7MUX_CD` to `DFF`, or `F7MUX_GH` to `HFF`).
- Weight data TX D comes from RAMB36E2, with TX in Laguna. Weight data
  has `DONT_TOUCH=1`; the other data TXs have0.

Incoming mux/FF packing and preservation are concrete differences, but
neither is independently proven to force the mapping. No extra fanout or
fixed-LOC/BEL explanation was found. Do not claim that adding DONT_TOUCH
alone will force all data TXs into Laguna or improve timing/congestion.

AMD documents connectivity/shared-control conditions for automatic mapping
in [UG949](https://docs.amd.com/r/2021.2-English/ug949-vivado-design-methodology/Using-SLR-Crossing-Registers)
and [UG912 USER_SLL_REG](https://docs.amd.com/r/2022.1-English/ug912-vivado-properties/USER_SLL_REG).
[UG574](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Flip-flops) also notes
that potential hold violations can prevent use of both TX/RX registers.
Hold/placer-choice explanations were not experimentally established here.
The ongoing normal run remains unchanged.

At11:40 KST the normal source flow starts `route_design` and enters Phase1
Build RT Design. This is the first run to reach routing after the hook fixes;
no SLR hook was disabled and no checkpoint implementation retry was used.
Legal routing and final setup/hold are not yet established.

By11:52 KST the router finishes global clock routing and bus-skew timing
updates, entering Phase4.1 Initial Net Routing Pass. The intervening
clock-routed timing summary is WNS=-0.021ns,TNS=-0.173ns,WHS=-0.203ns,
THS=-519.230ns. This is an intermediate estimate before general signal
routing, not legal routing or timing closure.

At11:57 KST, `Route35-3387` warns of high bus-skew violations that can
degrade WNS and congestion. By12:04 KST, `Route35-447` additionally reports
that congestion prevents routing all nets at this stage; the router
prioritizes connectivity over timing and enters Phase4.3 Initial Net
Routing Pass. Neither warning alone establishes a terminal routing
failure. Timing/bus-skew constraints and all SLR hooks remain unchanged.

By12:05 KST, routing reaches Phase5 Rip-up And Reroute, Global Iteration0.
`Route35-448` estimates Global/Short congestion level6 (64x64), and
`Route35-581` estimates Timing congestion level7 (128x128). Representative
global regions include `INT_X18Y30->INT_X49Y125` (north) and
`INT_X15Y23->INT_X78Y118` (east); these are router tile coordinates, not
proof that one RTL hierarchy alone causes congestion. `Route35-580` lists
25 pins with tight setup/hold constraints. Its top-five examples include
CPU operand output registers and MXU weight memory registers; preserve
`impl_1/tight_setup_hold_pins.txt` for final-path follow-up. None of these
intermediate estimates substitutes for final routing legality/timing.

At12:27 KST, Phase5.2 Global Iteration1 reports937,753 nodes with
overlaps. This is an intermediate routing-resource collision count,
not a count of failed nets or a terminal failure. Routing continues;
the final acceptance still requires zero overlap/unrouted/failed nets.

At 12:58 KST the next intermediate overlap-node count is 374,753,
approximately 60.0% lower than 937,753. This confirms progress in the
same rerouting iteration, but does not yet establish legal routing.

At 13:23 KST the next count is 134,296, down approximately 64.2% from
374,753 and 85.7% from the first reported 937,753. Routing remains active;
nonzero collisions still fail the final legal-routing acceptance.

At 13:41 KST the count decreases to 46,607 (65.3% below the preceding
134,296, 95.0% below the first reported count). Routing is still active.

At 13:53 KST the count decreases further to 16,123. No terminal routing
or timing verdict has been produced at this point.

At 14:00 KST the intermediate overlap count is 6,071; routing continues.

Subsequent Phase 5.2 counts are 2,402 (14:04), 1,070 (14:07), and
1,380 (14:10). The latest count increases, so convergence is not monotonic.
There is still no terminal routing verdict.

Further overlap counts decrease to 404 (14:13), 223 (14:16), and
140 (14:19). At 14:21 KST the same routing attempt remains active.

Counts continue through 119, 74, 45, 39, 34, 27, 20, 10, 11, 4, 4,
and 3 by 14:38 KST. `Route 35-443` then reports highly utilized CLB
routing and writes `impl_1/iter_120_CongestedCLBsAndNets.txt` (530 bytes).
It lists three tiles (`CLEM_X135Y54`, `CLEL_R_X135Y54`, `CLEM_X45Y333`)
and two Zero-point local DMA nets:

`gemm_node/u_tmem_subsystem/u_ldma_zero_point/u_overlap/u_stream_queue/slot_owner_sequence_r_reg[6]_1438[4]`

`gemm_node/u_tmem_subsystem/u_ldma_zero_point/u_overlap/u_stream_queue/slot_owner_sequence_r_reg[6]_1438[5]`

RTL anchors: `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:115` declares
response-slot command-sequence ownership; line 533 assigns it at request
allocation, and line 147 is one consumer comparing it with command sequence.
These are metadata nets, not response payload RAM data. This intermediate
CLB congestion list identifies a residual hotspot; it does not establish
the sole cause of whole-design congestion or a final failure verdict.

By 14:44 KST the sequence is 3 -> 21 -> 20 -> 8 -> 1; then it returns
to 8 at 14:45. `iter_140_CongestedCLBsAndNets.txt` instead lists
`CLEM_X135Y53`, `CLEL_R_X135Y53`, and two CPU issue/dispatch buffer nets
ending in `g_stage_0.pipe[0][192]_i_19_n_0` and
`g_stage_0.pipe[0][155]_i_32_n_0`. Residual congestion is not confined
to the preceding Zero-point DMA metadata example. Routing remains active.

At 14:46 KST, further counts are 8 -> 1 -> 0. This is the first zero
overlap-node report, not yet proof that `route_design` finishes legally
or that final setup/hold constraints are met.

At 14:47 KST `Route 35-416` reports intermediate routed timing:
WNS -5.148 ns, TNS -39745.081 ns, WHS -0.219 ns, THS -418.933 ns.
This is substantially worse than the clock-routed estimate, consistent
with the earlier warning that connectivity takes precedence over timing.
It is not final post-route/post-physical-optimization timing.

At 14:50 KST Phase 5.2 completes (route cumulative elapsed 3:09:14),
and Phase 5.3 Global Iteration 2 starts with 10,466 overlap nodes. Thus
the earlier zero count was transient, not completed legal routing.
The preceding second intermediate timing update is WNS -5.148 ns,
TNS -39857.598 ns, WHS -0.358 ns, THS -74.129 ns.

By 15:21 KST Global Iteration 2 overlap counts are
10,466 -> 11,751 -> 7,547 -> 3,472 -> 1,558 -> 677 -> 340 -> 194
-> 107 -> 85 -> 56. No final route/timing verdict yet.

By 15:35 KST the second global iteration again reaches single-digit
residual overlaps (latest 2). At 15:28, `iter_100_CongestedCLBsAndNets.txt`
lists `CLEM_X135Y54` / `CLEL_R_X135Y54` but no named nets. At 15:33,
the router **reuses/overwrites** `iter_140_CongestedCLBsAndNets.txt`:
this version lists X137/Y52-Y53 CLEM/CLEL_R tiles and CPU dispatch
buffer nets ending `pipe[0][196]_i_16_n_0` and
`pipe[0][134]_i_19_n_0`. The earlier 14:44 X135/Y53 inventory above
is a separately observed earlier version, not the file's current contents.
The dispatch buffer instantiation is `hw/rtl/core/VX_dispatch.sv:40`.

At 15:36 KST Global Iteration 2 reaches zero overlaps. Intermediate
timing is WNS -4.542 ns, TNS -34589.355 ns; WHS/THS are N/A in this
particular update, not a hold pass. Setup improves from -5.148 ns but
still violates the target at this intermediate stage.

At 15:38 KST Phase 5.4 Global Iteration 3 begins. Its counts rise from
1,067 to 1,658, then decrease through 1,015, 572, 311, 157, 95, 55,
32, 15, 13, 8, 8, 6, 2, 2, 1, 1, 1, followed by 4 at 15:55.
CLB congestion warnings persist; no final route/timing verdict yet.

At 15:58 KST Global Iteration 3 reaches zero overlaps and intermediate
WNS -3.887 ns / TNS -33696.087 ns (hold N/A). At 16:06 KST Phase 5.5
Global Iteration 4 starts; counts 1,483 -> 1,901 -> 1,162 -> 612 -> 265
-> 113 -> 52 -> 24 -> 16 -> 8 -> 4 -> 4 -> 2 -> 0 reach zero at 16:16.
Final route/timing still pending.

## Final slr_v7 result (2026-09-06 17:58 KST)

After the 16:18 user instruction, only session completion was monitored;
no intermediate implementation results were inspected. Session 79546
finishes with exit code 0 at 17:53. The normal source flow creates the
76,108,544-byte xclbin, but **fails the requested 100 MHz timing target**.
Vitis automatically selects **78.4 MHz**, as recorded in
`bin/vortex_afu.xclbin.info:54-60`. This is build success, not target
frequency acceptance. No follow-up fix or implementation retry is started.

Final reports in `slr_v7/.../prj.runs/impl_1` show:

- `hw_bb_locked_route_status.rpt`: all 1,143,563 routable nets fully routed;
  zero routing errors. Router logs additionally show zero failed,
  unrouted, partially routed nets and final overlaps; `route_design`
  completes successfully after about 5 h 15 min.
- `hw_bb_locked_timing_summary_postroute_physopted.rpt:164`: WNS -2.749 ns,
  TNS -23791.311 ns, 30,749 setup-failing endpoints; WHS +0.006 ns,
  THS 0, zero hold-failing endpoints. All setup-failing endpoints are in
  the 100 MHz kernel clock group (line 256). The later physical optimization
  does not improve these final extrema.
- Timing coverage: zero unclocked register/latch pins and zero unconstrained
  internal endpoints, but seven input and three output ports lack I/O delays.
- `hw_bb_locked_bus_skew_routed.rpt`: 195 reported paths, zero violations;
  worst +1.655 ns at line 5546, HMSS `path_13/interconnect0_13` Gray-pointer
  CDC (requirement 2.222 ns, actual skew 0.567 ns). This report predates
  the last physical optimization; no extra final DCP audit was launched.
- DFX and bitstream-precondition DRC both complete with zero errors;
  bitstream generation succeeds. Earlier cumulative `Invalid part string
  Project` logging did not terminate this run.
- Whole-design routed resources: LUT 597,606; registers 510,579;
  BRAM 602.5; URAM 156; DSP 2,277. Routed SLR0/1/2 occupied CLBs remain
  95.26% / 75.96% / 42.38%; SLL0/1 is 50.70%, SLL1/2 is 32.54%.
  These whole-design totals include platform/static logic, unlike the
  kernel-only synthesis totals reported earlier.

The **final top-five setup paths are different from the placed top five**.
They all launch from
`u_compute_core/g_slr_mxu_weight_rx.payload_q_reg[weight_sel]`
(`LAGUNA_X6Y362/RX_REG1`) to `u_mxu/u_weight_regs` storage FFs, entirely
within SLR2. The signal has fanout 4,034. Worst path (report line 2117):
one LUT, 12.535 ns data delay = 0.195 ns logic + 12.340 ns routing;
the first source-to-LUT net alone is 12.013 ns. The report's
`SLR Crossing[0->2]` label is on the clock leg, not this data path.

RTL anchors are `VX_gemm_compute_core.sv:1582` (RX capture), line 1588
(selection unpack), line 1669 (MXU port), `VX_gemm_tree_v1.sv:107`
(Weight-array port), and `VX_gemm_weight_regs_v1.sv:53,59,66,69`
(row/column source and destination storage-region selection).
The complete top-five table and destination names are in
[results-summary.md](results-summary.md). The 0.300 ns user uncertainty
is not the sole explanation: subtracting it alone still leaves about
-2.449 ns slack. No timing exceptions or margins were changed.

The optional report-copy targets cannot find `kernel_util_synthed.rpt`
and `kernel_util_routed.rpt`; make explicitly ignores these copy errors.
Other utilization/timing reports and the xclbin are present. These copy
issues were recorded without implementing another change.

**Disposition:** simulation and hook-debugging gates pass; legal routing
and hold pass; 100 MHz setup fails. Stop and hand over the results as
requested. No board programming, additional RTL/flow fixes, new synthesis,
checkpoint implementation retry, or commit was performed after this result.

### Read-only placed bus-skew diagnostic (2026-09-06 12:33 KST)

The standard `slr_v7` placed DCP was opened separately without changing
constraints, optimizing, placing, routing, or saving a checkpoint. The
diagnostic exited 0 and closed unsaved at 12:33:01; the normal routing
process was untouched.

- `build_slr_hw/slr_v7_placed_bus_skew_minmax.rpt` uses the installed
  `report_bus_skew -delay_type min_max -sort_by_slack -path_type short`.
- There are 196 effective report entries: 195 numeric, one NA, and zero
  negative slacks. The 90 HMSS entries have worst slack +1.754 ns
  (requirement 2.222 ns, actual skew 0.468 ns). The other 105 evaluated
  platform entries have worst slack +3.501 ns. No entry directly targets
  GEMM RTL.
- The worst placed entry is HMSS `path_13/interconnect0_13/s00_w_node`
  FIFO Gray-pointer CDC, `src_gray_ff_reg` to `dest_graysync_ff_reg`.
- The archived XDC inventory contains 273 literal directives (90 HMSS,
  183 other platform). Literal directive counts and effective evaluated
  entries are different quantities; they must not be conflated.
- This is **Fully Placed**, not routed evidence. It neither explains the
  ongoing router warning's actual violated paths nor establishes final
  bus-skew closure. Platform-scoped constraints also do not exclude an
  indirect effect from user-logic congestion. No constraint was relaxed.

Logs/inventory: `build_slr_hw/slr_v7_bus_skew_audit.log` and
`build_slr_hw/slr_v7_bus_skew_constraint_inventory.tsv`.
