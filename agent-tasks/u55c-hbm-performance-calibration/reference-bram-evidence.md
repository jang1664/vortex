# Archived BRAM simulation gap

## User decision and implementation update

Latest update: selecting only dual-port RAM was incomplete. The compiler still
used archived `VX_sp_ram`, which also instantiates the synthesis-only patch.
The override now selects **both** repo `VX_dp_ram.sv` and `VX_sp_ram.sv`, while
keeping archived headers and all non-RAM DUT sources. The fresh observer-free
`archived-document-repo-rams` stage passed compilation and compiler-path audit
(2 approved RAM, 217 archive, 5 harness, 0 unexpected records). Report:
`build_hbm_reference/sim/xrtsim_vcs/repo_rams_compile_audit.json`.

With both RAM sources, vecadd -n64 completes its kernel and shuts down normally
without the earlier X assertions. It still **fails correctness**: all 64 output
floats are zero, with 16692 instructions and 16064 cycles. Raw logs are
`build_hbm_reference_document/archived_repo_rams_vecadd.log` and
`archived_repo_rams_vecadd_simv.log`. Store traffic, result addressing and cache
writeback/completion remain to be checked. The historical single-RAM results
below are retained as diagnosis history, not current acceptance evidence.

The user selected the existing repo RAM source instead of writing a new
compatibility model. `prepare_reference.py --repo-ram` selects only
`hw/rtl/libs/VX_dp_ram.sv`; archived headers and all other DUT modules remain.
RAM SHA-256: `e3a96bbdc4a1ac5dd1fc7334ffc7c3a274457265edb98f9c99afed8a3cb110cd`.
This supersedes the earlier pending proposal below; no new
`VX_async_ram_patch` model was written.

Fresh observer-free stage `archived-document-repo-ram` compiled successfully.
Actual compiler-path audit reports one approved repo RAM, 220 archive entries,
five harness entries and zero unexpected paths. Its report is
`build_hbm_reference/sim/xrtsim_vcs/repo_ram_compile_audit.json`.
The archived launch directory now selects this stage and its matching host
bridge via owned symlinks. It still uses the temporary wrapper with run-only.

The vecadd smoke has not passed: it reaches 7185000ps and fails
`HBM_GUARD_AR: unsupported or boundary-crossing burst`, rather than the prior
LSU demux assertion at 6875000ps. Inspect the actual AR fields next; do not
assume a boundary issue from a guard message that combines multiple checks.
Raw host/simulation logs: `build_hbm_reference_document/archived_repo_ram_vecadd.log`
and `archived_repo_ram_vecadd_simv.log`. This result does not establish full
RAM-cycle equivalence or hardware performance fidelity.

The archived document-profile vecadd run fails before its first normal HBM
read response. The non-driving bank observer records:

| Time (ps) | Boundary | Address |
| --- | --- | --- |
| 6815000 | Accepted icache word request | `0x60000000` |
| 6815000 | Accepted bank line request | `0x6000000` |
| 6835000 | Memory-request FIFO push | `0x6000000` |
| 6845000 | Valid FIFO output | X |

Raw trace: `build_hbm_reference_document/archived_bank_observer_simv.log`.
This narrows the failure to storage/readout, not DCR startup or HBM latency.

The archived `VX_fifo_queue` uses `VX_dp_ram`, whose BRAM branch instantiates
`VX_async_ram_patch`. Its synchronous RAM read enable/address come from an
empty black-box `VX_placeholder`. These outputs are undriven in ordinary RTL
simulation. Adding `SIMULATION` to the build cannot restore branches already
removed from the preprocessed archived source.

Read-only comparison with the repository source explains the preprocessing
gap: `hw/rtl/VX_platform.vh:211` defines `ASYNC_BRAM_PATCH` only outside
`SIMULATION`, and `hw/rtl/libs/VX_dp_ram.sv:228` guards its patch instantiation
with that macro. The archived `VX_dp_ram.sv` has an unconditional instantiation
instead. This comparison explains the mechanism; it does not authorize using
the current source as the reference implementation.

Same-artifact evidence is in `_x/logs/link/imp/impl_1_runme.log:1457`: the
implementation explicitly resolves the icache bank's
`mem_req_queue/g_depth_n.dp_ram/g_async.g_bram.async_ram_patch`. The following
line reports completion of the patch pass. Other instances have explicit
asynchronous-fallback warnings, so a blanket placeholder passthrough is unsafe.

The repository's `hw/scripts/xilinx_async_bram_patch.tcl:427` describes how
registered address drivers are detected, next-state data (including reset
where requested) feeds the RAM address, and the register CE feeds RAM read
enable. Unregistered cases select an asynchronous fallback. This script is
mechanism evidence, not yet proof of the exact archived script version.
The archived `xrt_backup/post_init_hook.tcl` sources
`${::env(TOOL_DIR)}/xilinx_async_bram_patch.tcl` before floorplanning/reports;
it does not embed the script contents. Checkpoint inspection is therefore
needed rather than assuming the current external script is identical.

`audit_reference_bram.tcl` reads an existing optimized checkpoint to inspect
the actual icache FIFO patch nets without synthesizing, modifying a checkpoint,
or writing archived files. Further work must establish cycle equivalence of
any simulation-only replacement before accepting hardware-reference results.
No placeholder override, force, assertion suppression, or archived RTL edit
has been made. Current RTL must not replace this historical DUT.

## Checkpoint audit coverage

The first audit completed successfully as a tool invocation but found **zero
cells** with the combined historical path and `VX_async_ram_patch*` REF_NAME
filter. It therefore proves no RAM connections. Its raw output is
`build_hbm_reference/reference_bram_audit.log`; checkpoint load took 278s.

The revised audit searches icache memory-request FIFO cells without depending
on the pre-optimization module REF_NAME, searches nets independently, and
returns an error if no patch nets are found. It also avoids interpreting literal
brackets in generated hierarchy names as glob syntax. Revised output is
`build_hbm_reference/reference_bram_audit_v2.log` (pending at launch).

The revised audit completed with exit 1: it found 67 FIFO cells but zero
originally named patch nets. It found the patch hierarchy with REF_NAME
`ulp_vortex_afu_1_0_VX_async_ram_patch__parameterized11`, explaining the first
audit's overly restrictive REF_NAME prefix. It also found `raddr_next` LUT2
cells. Thus the hierarchy exists; flattening was only a hypothesis, not the
cause established by these results. Connectivity remains unproven.

A third, read-only interactive audit now reports address/enable/clock/reset
pin drivers of BRAM primitives and input drivers/INIT values of `raddr_next`
LUTs. It retains the open checkpoint for follow-up queries instead of paying
the checkpoint load cost again. Log:
`build_hbm_reference/reference_bram_audit_v3_vivado.log`.

## Required validation before any simulation compatibility model is accepted

- Inspect actual RAM primitive read-address, enable, reset and output-register
  settings, not just the presence of a patch cell or successful tool exit.
- Check each used parameterization: address-register hint, reset behavior,
  write-first/read-first behavior, byte enables, and registered versus fallback
  read paths. One icache FIFO cannot prove all helper instances equivalent.
- Exercise empty-to-nonempty FIFO transitions, simultaneous push/pop, pointer
  wraparound, backpressure, reset with pending data, and same-address read/write.
  Compare output-valid cycles as well as data. Do not add or remove a cycle.
- Keep any proposed compatibility source separate from the archive and record
  its hash and exact instance/module scope. Treat it as a reference-build
  exception requiring explicit rationale, not current-RTL fallback.
- After compatibility validation, rebuild a fresh observer-free reference
  stage, rerun source/IP/compile audits and transport/correctness tests, then
  begin repeated baseline/document-profile/hardware workload comparisons.

These are pending gates, not completed tests or authorization to alter the
archived production sources.

## Primitive-pin evidence (2026-09-08 16:58)

The interactive checkpoint inspection found both RAMB36E2 read-address bits
`ADDRARDADDR[6:7]` driven by the two `raddr_next` LUT2 cells. Each LUT has
`INIT=4'h2`, with I0 driven by read-pointer next-state combinational logic and
I1 by the icache reset register. Thus reset masks the next read address.
Both RAMs report READ_WIDTH_A=72, WRITE_WIDTH_B=72, READ_WIDTH_B=0,
WRITE_WIDTH_A=0, DOA_REG=0, DOB_REG=0 and WRITE_MODE_A/B=READ_FIRST.
BRAM read enable is driven by a LUT5 (INIT=32'h6FFFFF6F) involving read/write
addresses and pipeline logic; do not model the primitive as an always-enabled
write-first array merely because the original RTL branch has that name.

The existing optimized checkpoint exported the icache FIFO cell to
`build_hbm_reference/reference_icache_fifo_funcsim.v` (105KB), without synthesis
or changes to the original checkpoint. This is an additional inspection
artifact, not a new hardware RTL implementation. Its optimized interface
contains propagated/renamed signals, so it is not yet a drop-in behavioral FIFO
oracle. Port mapping and surrounding optimized logic need checking before
attempting equivalence tests. Session 42817 was closed normally at 17:00 while
awaiting the user decision; its log and exported netlist remain available.

## Decision requested

The exported FIFO interface was inspected and includes optimized pipeline
inputs/outputs beyond the original FIFO ports. Treating it as an independent
FIFO oracle without reconstructing those boundaries would be misleading.

Request user approval for one explicit reference-build exception: implement a
separate simulation-only `VX_async_ram_patch` compatibility model and select
only that helper through the temporary Makefile. Do not alter archived files,
reuse current DUT RTL as a fallback, or disable assertions. Record the selected
model and its hash in provenance; complete the validation gates above before
accepting any hardware-reference performance results. This exception has not
yet been implemented or approved. The earlier temporary-wrapper approval does
not imply approval for replacing a DUT helper.

An archive-wide search finds `VX_placeholder` only in its declaration and
`VX_async_ram_patch.sv`; no second consumer was found in `src/`. This confines
the identified placeholder compatibility issue to that helper, but does not
prove that other simulation-compatibility issues are absent.
