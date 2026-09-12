# Source-based full-SLR flow and validation

Implemented on 2026-09-05. Physical synthesis/place/route evidence is still
pending; Tcl fixtures are not a substitute for a placed design.

## Configuration and ownership

- `GEMM_SLR_FLOORPLAN=1` selects the three full-SLR pblocks and requires
  `-DGEMM_SLR_PIPELINE` in the sourced `CONFIGS`.
- `run_hw.sh --slr-floorplan 0|1` overrides the sourced floorplan setting;
  `--postfix slr_v1` keeps the source-built experiment in a separate output.
- The Makefile exports TMEM array, DMA channel, HBM port and MXU row/column
  counts plus `MEM_BLOCK_SIZE` from `CONFIGS`. There is no configuration
  whitelist. `geometry` follows `VX_gemm_node` and `VX_tmem_subsystem`:
  physical TMEM bytes = `2 * MXU_ROW` (fixed FP16 input); HBM bytes =
  `MEM_BLOCK_SIZE` (currently required to be 64 by RTL). Scale/zero-point
  and physical TMEM widths must match, requiring `MXU_ROW == MXU_COL`.
  The supported `{HBM/TMEM width ratio, arrays per DMA channel}` structures
  are `{1,1}` direct, `{1,2}` bank-select and `{2,2}` pair-adapter.
  U55C exposes four or eight HBM ports; DMA channels must divide that count.
  TMEM/DMA counts must be powers of two and TMEM arrays divisible by channels.
  Exact array/channel and active route index sets are checked, not just
  cardinality. Inactive pair/bank-select state is rejected. Direct routes
  are wires and may disappear; surviving direct leaves must be in range
  and belong to a direct configuration. MXU16/t8 therefore accepts four
  pair adapters and MXU16/t16 accepts eight without adding profile entries.
  Missing, malformed or repeated definitions are rejected; only absent
  `NUM_HBM_PORTS`, `MXU_ROW`, `MEM_BLOCK_SIZE` default to 8, 32, 64, matching
  `VX_config.vh`. Width formulas must be kept in sync if fixed FP formats
  change. TH16 and TH32 retain the same SLR ownership policy.
  Standalone DCP checkers describe square FP16 MXUs with a 64-byte HBM bus.
  See [four-config preflight](four-config-pnr/preflight-spec.md).
- SLR0 contains HBM DMA, TMEM arrays/switches and the TMEM DMA controller;
  SLR1 contains local DMA, node/job/control logic and ACC; SLR2 contains MXU.
  Crossing halves are assigned independently. Residual TMEM/control bridge
  glue is classified by named source- or destination-local signal families;
  unknown residual families fail with the offending leaf name.
- Pblocks contain primitive leaf cells, not overlapping mixed-ownership
  parents. `IS_SOFT=false`, `CONTAIN_ROUTING=false`, and
  `EXCLUDE_PLACEMENT=false`; platform/RP ancestor pblocks remain untouched.
  These three values are reapplied immediately after `add_cells_to_pblock`,
  because Vivado's nested-RP processing can override child properties at that
  point. A shared post-add/post-place checker logs and verifies actual values,
  and also records `SNAPPING_MODE`, `GRID_RANGES` and `DERIVED_RANGES` so
  platform clipping is visible. It does not introduce narrower ranges or
  change SLR ownership. Failure to retain any intended value is fatal.

The SLR floorplan setting participates in the link fingerprint. The pipeline
macro participates in the existing RTL configuration fingerprint. Refresh the
configured build after editing source templates, before launching hardware.

## Hooks and reports

`post_init_hook.tcl` loads the ownership map, rejects stale user pblocks,
validates required hierarchy/profile groups, creates the pblocks and writes
`post_init_slr_links.tsv`. Every surviving marked RX must have a matching,
directly connected marked TX Q-to-D peer in an adjacent assigned SLR.
Immediately afterwards it scans all partition boundary nets and writes
`post_init_slr_boundary_nets.tsv`. Entire data-bank absorption or lifted local
helpers therefore fail before placement, even when surviving metadata pairs
are individually valid. Post-place repeats both checks against the placed
netlist. Fixtures verify report-source/check order, boundary-error propagation,
and that a disabled floorplan does not source or execute these checks.

`post_place_hook.tcl` independently validates:

- exactly three user GEMM pblocks, no old DMA pblocks;
- each leaf's actual user-pblock membership and actual SLR;
- required marked endpoint groups and exact FF-to-FF connectivity;
- every endpoint's LOC/BEL, with per-group actual Laguna TX/RX pair counts;
  zero Laguna pairs are a warning, not a fatal condition (2026-09-10 policy).
  Direct FF pairing, group correspondence and actual SLR ownership remain fatal
  checks. Fabric placement is permitted so routed timing can determine QoR.
- nets touching logical partition hierarchy ports, rejecting unregistered
  functional owner-to-owner connections, including reverse ready/status;
  clock/reset control pins, constants and platform-owned endpoints are exempt.

Outputs include `post_place_gemm_slr*-utilization.rpt`,
`post_place_slr_links.tsv`, `post_place_slr_boundary_nets.tsv`, and
`post_place_slr_timing.rpt`. A completely unmapped crossing group is fatal;
the per-pair TSV also records partially mapped groups for physical review.
Inactive legacy DMA sync and output response streams may optimize away
completely. The currently unconsumed DMA idle status pair may also disappear
as a whole. A partly surviving stream or status pair must still preserve both
marked endpoints; missing attributes or a single remaining half remain fatal.

`--no-early-fail` only disables the congestion threshold gate. When the SLR
floorplan is enabled, the generated INI keeps the post-place hook and its
physical checks. `VORTEX_CONGESTION_FAIL_FAST` separately controls the
congestion check inside that hook.

The existing `tests/check_floorplan_dcp.tcl` is now read-only validation of an
already generated SLR image. It never adds constraints or runs implementation;
it is not a DCP retry path and has not been run for this change.

`tests/check_slr_synth_dcp.tcl` separately opens a synthesized checkpoint for
read-only inventory, attribute and direct FF-pair checks. It creates no pblocks
and invokes no synthesis, optimization, placement, routing or checkpoint write.

## First source-run post-init correction

The first normal `slr_v1` source build completed kernel synthesis but stopped
at post-init on `SLR floorplan missing required group: DMA idle SLR0`.
`VX_gemm_node.sv:1232` forwards `source_dma_ctrl_if.idle` into
`gemm_ctrl_if.dma_flag.idle`, but `VX_gemm_ctrl.sv` never reads that field:
child availability uses `dma_flag.cmd_ready` at line 1266. The full unused
idle-status cone, including both boundary FFs, is therefore removable.

A read-only Vivado 2025.1 inspection of the actual kernel synthesis checkpoint
confirmed **zero surviving DMA idle cells**. The corrected floorplan permits
only complete removal of that pair; it does not preserve unused FFs or relax
the checks on meaningful command/completion crossings. Fixtures cover absent
both halves (pass), a single remaining half (fail), and an unmarked endpoint
on a surviving pair (fail). No functional RTL change was needed.

The first inspection log is `build_slr_hw/slr_synth_preflight.log`. Its
per-leaf inventory was stopped after ten minutes and replaced with an
equivalent batch-property/local-list implementation, with stage and 100k-leaf
progress messages. A second run showed classification, not global cell
enumeration, remained slow. A synthetic 100,061-cell benchmark of the same
algorithm completed in 1.59 s in system Tcl but exceeded 93 s in Vivado Tcl.
Replacing per-leaf namespace dictionary writes with a local array and one
final dictionary construction reduced the Vivado benchmark to 7.34 s.
Canonical `NAME` and `REF_NAME` values are batched, with list lengths and name
uniqueness checked; replica enumeration and all ownership checks are retained.
The exact internal cause of Vivado's different dictionary cost is not proven.
An additional 1,000-lookup microbenchmark with a 100k-entry map measured
1.520 s for a namespace dictionary, 1.465 s for a local dictionary, and
0.001587 s for a local array in Vivado. Direct-pair and partition-boundary
validation therefore take one local-array snapshot of the public ownership
dictionary, retaining identical membership/SLR tests without per-pin large
dictionary lookup costs.

Earlier diagnostic logs are preserved. The current read-only run uses
`build_slr_hw/slr_synth_preflight_v4.log` and
`build_slr_hw/slr_synth_preflight_v4_links.tsv`. These inspect synthesized
logic only, not successful placement or Laguna mapping.

The v4 read-only check completed in approximately 3m19s. It classified
922,739 total primitives, of which the GEMM ownership map contains
125,814 / 229,683 / 143,164 leaves in SLR0 / SLR1 / SLR2 respectively.
All hierarchy/profile and marked-group checks passed (9,474 marked FFs).
Direct-pair checks found 4,512 valid links and exactly 515 failures:

- Three input/scale/zero-point response `payload_rx_q_reg[5]` D pins are
  driven by literal GND primitives. These constant metadata bits do not
  carry a functional crossing. The checker now reports `# tieoff` records
  for only `GND/G` or `VCC/P` sources; it never treats RAM, DSP or LUT outputs
  as constants.
- All 512 weight-response data RX D pins are driven directly by the wide
  switch's response RAM `DOUT*` pins. The intended payload TX stage was
  absorbed into the BRAM output register, so it is not a dedicated SLR0
  crossing FF. This is a real physical-contract failure and remains fatal.

The scoped RTL correction adds `PRESERVE_TX_PAYLOAD=0` and
`PRESERVE_TX_PAYLOAD_LSB=0` to `VX_slr_stream` and propagates a response-only
option through `VX_slr_mem_bus` and the read reservation wrapper. Only the
weight reservation opts in. Since responses pack `{data, tag}`, the memory
bridge supplies `$bits(upstream_if.rsp_data.tag)` as the preserved slice LSB.
`DONT_TOUCH` protects only the data TX FFs from RAM absorption. Constant tag
bits remain optimizable to avoid preserved TX-only orphans; requests, other
response streams, queue state and RAM arrays are not preserved broadly.
The per-bit `g_payload[bit].payload_tx_q` bank retains stable `u_tx/u_rx`
ownership, and its role/group matching is covered by a fixture. RTL capture
conditions and cycle latency are unchanged.

[AMD UG912 DONT_TOUCH](https://docs.amd.com/r/2024.2-English/ug912-vivado-properties/DONT_TOUCH)
recommends applying the property in RTL because optimization can precede
XDC loading, and documents its preservation through implementation. Its
optimization/resource cost is why this option is localized. New source
synthesis must still prove standalone TX/RX pairs and unchanged RAM
inference; the old checkpoint cannot prove the correction. Updated fixtures
pass both literal-constant cases and still reject an owned RAMB driver.
Current-source unit/blackbox checks and normal `slr_v2` source implementation
are coordinated by the main agent; no DCP implementation retry is used.

The subsequent read-only `boundaries` scan found 31,236 illegal owner-crossing
pin connections in the old checkpoint (`slr_synth_boundary_preflight.tsv`):

- 30,720 prealigner Q-to-MXU DSP input connections, from 2,304 replicated
  prealigner source pins. The input transport's data stages have apparently
  been absorbed into DSP input registers: only 193 MXU input control/metadata
  FF pairs remain. RTL explicitly connects `mxu_input_capture`, so the
  physical topology, not a missing RTL assignment, is the issue. Dedicated
  input-data TX **and RX** FF preservation is now implemented with separate
  `data_q` vectors sized by `$bits(prealigner_int_data)`. Only those vectors
  carry `DONT_TOUCH`; `control_q` stays optimizable and the assembled
  `payload_q` view preserves existing assertions. No clock is added.
- The already diagnosed 512 weight RAMB-output-to-response-RX connections.
- Four command-RX FIFO pointer connections: synthesis lifted `read_q0` and
  `write_q0` LUTs to node-level `u_commands/u_rx`, outside the original bridge
  name. Their default SLR1 ownership conflicts with the SLR0 pointer FFs;
  the lifted local LUTs now have explicit SLR0 ownership, not another pipeline.
  The rule accepts only `read_q0`/`write_q0` and their replica suffixes, not an
  arbitrary lifted `u_commands` subtree.

No other illegal source/destination family appeared in this scan. These
findings are still physical-contract failures; passing functional simulation
does not establish that dedicated crossing FFs survived synthesis.
The current post-init gate separately requires both named MXU input `data_q`
banks (and their USER_SLL attributes), so control-only survival can no longer
pass that stage. Fixtures cover missing input data RX, per-bit transport
names, exact lifted pointer ownership and constant-vs-RAMB discrimination.

## Second source-run reset mapping correction

The new `slr_v2` kernel netlist retained 10,754 marked FFs. The standalone
weight response data TX bank and both 384-bit MXU input data banks survived;
the complete partition-boundary scan passed. Exact-pair checking nevertheless
reported two related errors: weight RX valid had a LUT on D, and its TX valid
FF consequently had no direct RX peer.

Read-only inspection (`build_slr_hw/slr_v2_valid_diagnose.log`) established:

- The intervening primitive is `LUT2`, `INIT=4'h2`.
- I0 is weight TX valid Q; I1 is the core-reset relay Q.
- RX is an FDRE with CE tied high and R tied low. The LUT implements
  `TX_valid && !reset`, i.e. the RTL's synchronous reset moved onto D.

The mapping correction applies `EXTRACT_RESET="yes"` to existing explicitly
synchronous-reset USER_SLL banks: MXU input RX control, weight RX, output
TX/RX valid containers; stream valid/credit FFs; and bridge idle FFs. It does
not add resets to payload data, change any sequential equation, add cycles,
or expand `DONT_TOUCH`. Packed containers only reset their existing valid
field; other fields remain reset-free.

[AMD UG901 EXTRACT_RESET (2025.1)](https://docs.amd.com/r/2025.1-English/ug901-vivado-synthesis/EXTRACT_RESET)
documents that `yes` forces an existing synchronous reset onto the dedicated
FF R pin instead of D-input logic. This preserves the required direct Q-to-D
physical connection while keeping the same reset behavior. Current-source
simulation and a subsequent normal source build still have to verify the
mapping correction; no DCP implementation retry or path exception is used.

## Local flow-test evidence

Run from the source workspace, with a configured `build_slr_hw` directory:

```sh
tclsh hw/syn/xilinx/xrt/test_slr_floorplan.tcl
tclsh hw/syn/xilinx/xrt/tests/test_post_place_hook.tcl
XRT_TEST_BUILD_DIR="$PWD/build_slr_hw/hw/syn/xilinx/xrt" \
  python3 hw/syn/xilinx/xrt/tests/test_gen_vitis_ini.py
bash -n hw/syn/xilinx/xrt/run_hw.sh.in
git diff --check
```

Results: SLR fixture passed both profiles and negative ownership/part/option/
connectivity/Laguna cases; 24 congestion-hook checks passed; nine INI/Makefile
tests passed, including preserving the physical hook with congestion disabled.
Shell syntax and whitespace checks passed. None of these tests starts Vivado
synthesis, implementation or an FPGA run. Functional/performance simulation
gates must pass before the normal source-based full implementation is started.

After refreshing `build_slr_hw` from the primary config, a full hardware
`make -n` completed successfully and retained both `--gemm-slr-floorplan` and
`--disable-congestion-fail-fast` in the generated command. The current 2025.1
`platforminfo` environment warned that the bare U55C platform name resolved
through multiple search paths. Resolve that environment ambiguity or pass
the explicit `.xpfm` path to `make PLATFORM=...` before the actual build.

## Installed Vivado API-only preflight

An API-only batch process used installed Vivado 2025.1 (SW build 6140274),
without creating/opening a project, loading a checkpoint or running synthesis
or implementation. Its help output is retained in the generated
`build_slr_hw/slr_api_preflight.log`. The installed command reference confirms:

- `get_slrs -of_objects` accepts cells;
- `get_pblocks -of_objects` accepts cells;
- `get_pins -leaf -of_objects` returns primitive endpoints of nets;
- `get_nets -segments` and `-top_net_of_hierarchical_group` support following
  the connected net segments across hierarchy;
- property filters support Boolean properties, comparisons and `&&`;
- `resize_pblock ... -add SLR0` is a documented full-SLR form.

`list_property -class cell` requires an open project, so this help-only
preflight does **not** establish the properties of an actual inferred FDRE.
UG912 documents `USER_SLL_REG` for FD cells, but checking its survival on this
RTL's FFs and actual Laguna mapping remains the post-init/post-place gate.
The explicit platform file
`/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm`
was separately resolved successfully by the main agent, avoiding the bare-name
platform search ambiguity noted above.

## Tcl API references

### Optimized/placement-generated ownership lifecycle

The `slr_v3` standard opt checkpoint exposed 512 accumulator LUTs with only
platform-RP membership. The later `Place 30-642` reset helper was absent from
that checkpoint and appears only inside placement. A primitive snapshot at
post-init therefore does not cover the full implementation lifecycle.

The hardware SLR flow now adds an `OPT_DESIGN.TCL.POST` hook which:

- Re-inventories current logical owners and checks every leaf's actual
  `PBLOCK` value using batched property reads, not a collection-wide union.
- Rejects conflicting user owners before reattaching missing memberships.
- Anchors maximal retained homogeneous hierarchy islands. Every nonconstant
  primitive contributes its existing SLR ownership, or blocks selection if
  unowned. Actual PARENT chains include intermediate primitive containers
  such as DSP48E2; these are traversal nodes, not eligible hierarchy anchors.
  Mixed-owner compute/GEMM/TMEM/transport parents are never assigned.
  Coverage of local FP reset families and profile indices remains checked.
- Reasserts all three hard-pblock properties and repeats exact FF-pair and
  full boundary checks. The same per-leaf membership checker runs post-place.

Hierarchy assignment is a documented `add_cells_to_pblock` operation; see
[UG912 PBLOCK](https://docs.amd.com/r/en-US/ug912-vivado-properties/PBLOCK).
This provides the intended owner for subsequently generated local children;
the actual new normal source implementation must still demonstrate that the
specific placement-shape failure is gone. No DCP implementation retry, RTL
change, added latency, pblock softening, or platform reassignment is involved.

The slr_v5 normal run subsequently verifies this hook/API correction but
fails placement on a TMEM input-switch round-robin reset helper in ROOT
versus its original SLR0 FF. Thus FP-only anchoring is an incomplete
lifecycle fix. The follow-up generalizes anchors to maximal retained
single-owner hierarchy islands, derived from **all** nonconstant primitive
descendants and actual PARENT relationships. Mixed/unowned subtrees and
architectural crossing containers are not attached wholesale. Every owned
FF without a selected homogeneous ancestor is reported separately, so this
check does not silently assume protection for direct leaves of mixed parents.
The first actual read-only graph audit exposed `DSP_ALU_INST` whose PARENT is
a primitive DSP container rather than an IS_PRIMITIVE0 hierarchy. The corrected
algorithm keeps such containers in the graph while forbidding their selection
as hierarchy anchors. Sixty-three pure-tree/typed-runtime checks pass, including
nested DSP children, conflicting/unowned descendants, broken chains and runtime
idempotence; existing lifecycle53, SLR and congestion24 checks also pass. The
1.3M-leaf analysis takes5.433 seconds in system Tcl, not measured Vivado runtime.
Actual-netlist coverage and constraints-only preflight must pass before the
next normal source implementation; this generalization is not yet physically
validated.

Relationship-property queries explicitly resolve canonical cell names through
`get_cells` before passing the object collection to `get_property`. Actual
Vivado rejects the previous raw-name PBLOCK query even for one cell. The
shared helper checks exact name/count/uniqueness coverage and restores the
requested value order. PBLOCK/PARENT/IS_PRIMITIVE use it; the post-opt hook
adds stage/error-stack context. Strict fixtures cover object typing and
reordered collections. Actual full-hook in-memory preflight passes twice,
recovering 512 leaves and preserving all 96 FP parents without opt/place/route
or checkpoint writes. This validates API/constraint behavior, not placement.

### Post-place typed SLR lookup and failure evidence

The slr_v6 normal run passes the generalized post-opt hook and completes
placement, but fails the first post-place group query: `get_slrs -of_objects`
receives canonical NAME strings and returns empty under `-quiet`. Installed
Vivado2025.1 help requires typed objects for this relationship query, just
as for the earlier property-query correction. New `cell_objects` resolves
the requested names and requires exact count, uniqueness and identity
coverage before returning the typed collection. It permits different
collection order, but never missing/extra/duplicate objects. The actual
SLR result must still exactly match the intended single SLR.

Twenty-two dedicated post-place fixture checks cover raw-string failure,
typed singleton/reordered collections, resolution errors, and empty/wrong/
multiple SLR results, retaining all membership/pblock/Laguna gates.
An actual runtime probe must use **known placed** cells: two empty query
results from an unplaced design are not positive evidence of lookup validity.

Since VPL saves its normal placed checkpoint after this hook, an SLR-check
failure now saves `post_place_slr_failed.dcp` (or a numbered non-overwriting
name) solely for subsequent read-only diagnosis. The hook rethrows the
original error/options and never proceeds to routing. Failure to save the
diagnostic also preserves the original error. Disabled/successful SLR checks
save no extra checkpoint. Thirteen hook fixtures cover these cases. This is
not a checkpoint-based implementation retry and changes no RTL or constraints.

The complete fixture suite passes:63 hierarchy,59 post-opt,22 typed SLR,
13 diagnostic snapshot,28 congestion parser,24 congestion hook,10 INI,
3 utilization parser, plus the existing ownership/direct-pair/Laguna suite.

## Structural geometry validation (2026-09-07)

Replaced the fixed configuration whitelist with the width/count contracts
described above. SLR ownership, full-SLR ranges, marked endpoint checks and
post-opt/post-place checks are unchanged. No RTL or pipeline latency changed.

Verification used a separate `build_floorplan_geometry.84rxny` directory,
configured after sourcing `configs/improve_th16_tcol16_m16_t8_bigmem.sh` with
`../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`.

- Eight plain-Tcl suites PASS: structural inventory, homogeneous anchors,
  lifted-owner recovery, post-opt hook, post-place hook, typed post-place
  objects, diagnostic snapshot and congestion checks.
- Inventory fixtures cover direct, bank-select and pair routes with four/eight
  DMA channels, dot/slash generate spellings, MXU16/t8, and multiple HBM ports
  per DMA channel. Negative tests reject malformed/missing geometry, unsupported
  width/count relations, missing or wrong route indices, inactive route state
  and the existing ownership/FF-pair failures.
- `test_gen_vitis_ini.py`: 13/13 PASS (148.507 s). All six timing configs pass
  Makefile export -> actual `floorplan.tcl::geometry` checks, in addition to
  HBM connectivity and hook registration checks. A new source-contract test
  catches drift in the mirrored fixed FP16 width formulas and RTL defaults.
- An earlier run during editing failed the existing dummy-XO cache-reuse
  check. The complete rerun above, with source files held fixed, passed it.

No Vivado synthesis, checkpoint validation, placement or routing was performed.
These fixtures establish structural hook compatibility, not physical timing
or congestion closure. The earlier MXU16 xrt-vcs-sim results remain separate
functional evidence; simulation was not rerun for these Tcl/Makefile changes.
Refresh the configured build before the next source hardware run so both new
geometry environment variables reach the hooks. Historical copied hook bundles
are not modified by this change.

### Command references

The full-SLR range form is documented in
[UG835 resize_pblock](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/resize_pblock).
Cell membership is queried with
[UG835 get_pblocks -of_objects](https://docs.amd.com/r/2020.2-English/ug835-vivado-tcl-commands/get_pblocks),
not the unsupported reverse `get_cells -of_objects pblock` direction.
Actual placement checks follow
[UG912 USER_SLL_REG](https://docs.amd.com/r/2023.1-English/ug912-vivado-properties/USER_SLL_REG)
and [UG949 SLR crossing registers](https://docs.amd.com/r/2021.2-English/ug949-vivado-design-methodology/Using-SLR-Crossing-Registers?contentId=5ZaV7FTGGV8yKT2IzLlkNg).
