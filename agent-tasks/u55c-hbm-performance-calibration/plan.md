# U55C HBM bandwidth and zero-load latency calibration

Execution closed2026-09-09 after the user adopted the bounded workload timing
model with documented provenance/coverage limitations. See `RESULTS.md` and
`acceptance-audit.md` for the final evidence and accepted disposition. The
original plan below is retained; completion does not claim direct physical
HBM latency measurement or exhaustive vendor primitive equivalence.

## 1. Objective and agreed scope

Parameterize the existing xrt-vcs-sim HBM model for representative Vortex DMA/GEMM
memory performance without reproducing the internal U55C HBM switch.

- Default kernel clock: **100 MHz**, the existing hardware design target.
  Keep explicit frequency overrides supported.
- Retain DramSim/Ramulator and deterministic VCS-owned device time.
- Start with official-document latency and bandwidth bounds; validate workload
  performance using existing xclbins and their matching archived RTL.
- Do not implement measurement-only hardware RTL or synthesize a new xclbin.
- Label the initial profile documentation-based, not hardware-calibrated.
- Represent bandwidth limits per external kernel AXI port and in aggregate.
- Preserve finite queues, backpressure, and load-dependent waiting.
- Exclude detailed switch routes, hop latency, lateral-link contention, and
  proprietary arbitration from the calibrated abstraction.
- Target device-side memory behavior and kernel execution time, not host wall
  time, PCIe transfer time, or runtime startup overhead.

This document plans future implementation and measurement. It does not launch
hardware jobs, modify simulator behavior, or authorize commits/pushes. No FSM
is introduced. Follow repository configuration and hardware-run procedures
when executing the plan.

## 2. Starting point and fidelity boundary

The completed implementation is documented in
`../u55c-vcs-hbm-model/verification.md` and `sim/xrtsim_vcs/HBM_MODEL.md`.
It already supplies independent clocks, VCS-owned RAM/Ramulator, finite AXI
admission, reset handling, and configuration manifests. Reuse these contracts.

The existing abstract ingress/paired-PC resource model is not a measured U55C
switch model. Do not silently stack its uncalibrated penalties with the new
bandwidth/latency controls. Identify which existing resource limits remain
necessary for protocol correctness and which performance limits the calibrated
mode replaces or bypasses. Preserve the old mode as an explicit regression
baseline if useful; select the mode in the configuration manifest.

The 100 MHz kernel target is distinct from HBM AXI and physical DRAM clocks.
Do not assume either HBM clock is 100 or 300 MHz. Existing older-build evidence
reports HBM AXI 450 MHz and physical HBM 900 MHz, but is not proof of current
profile settings. Obtain HBM settings from the selected platform/build.
Keep 100 MHz as the default target. For an existing xclbin running at another
frequency, override the reference VCS run to that actual frequency. Do not
compare its hardware results directly with a 100 MHz simulation or rescale
cycles as if the kernel/HBM frequency ratio had no performance effect.

The model is intended for the calibrated sequential DMA/GEMM operating range.
Random-access, row-conflict, and route-sensitive performance outside that range
is not guaranteed. Ramulator may still introduce its own DRAM effects; retaining
it does not establish fidelity of its controller policy to AMD hardware.

## 3. Configuration and model contract

Continue consuming `hw/syn/xilinx/xrt/platforms.mk` for port count, address
reachability, and memory geometry. Internal switch wiring is not required for
this abstraction. Define a versioned calibration profile containing:

- Kernel default frequency and independently specified HBM/DRAM frequencies.
- Read zero-load latency target in ns, with transaction size and measurement
  boundary specified. Use a common target initially; add per-port targets only
  if measurements show a repeatable, material difference.
- Per-port read and write bandwidth budgets in explicitly defined GB/s
  (decimal bytes/second), distinguishing raw bounds from measured sustained rates.
- Aggregate read and write bandwidth limits. If mixed traffic needs a shared
  budget, use a documented simple rule, not an invented internal switch topology.
  Never treat full-card raw bandwidth as independently available to simultaneous
  reads and writes on the same memory resources.
- Finite queue/outstanding limits and deterministic scheduling policy.
- Board/platform/xclbin identity, effective configuration, measurement method,
  sample count, and calibration provenance. Label unmeasured values clearly.

Include effective profile values in generated configuration and startup hashes.
Reject invalid values and unsupported combinations. Do not equate the card's
advertised aggregate bandwidth with attainable bandwidth at the kernel ports.

### Timing and bandwidth behavior

Keep AXI data correctness, ordering, credits, and reset cancellation unchanged.
Use simulation-time-based byte service budgets or equivalent deterministic
serialization for per-port and aggregate bandwidth. Define bounded burst credit
and fairness so idle time cannot accumulate unlimited service credit and one
port cannot starve another. Charge actual data beats in each direction; do not
charge read-sized data traffic for write B notifications.

Latency calibration must account for all existing delay at the same AXI
boundary: Ramulator, CDC, adapter publication, and any remaining serialization.
For the reference transaction, add only the nonnegative residual delay needed
to match the selected reference latency. Do not add the full reference latency
on top of existing model delay. Specify where residual delay is applied and
verify it does not unintentionally reduce pipelined sustained throughput.

Bandwidth controls can only reduce throughput, and residual delay can only
increase latency. If the baseline is already slower than hardware, investigate
DRAM settings or retained resource penalties first; do not use negative delay,
early completion, or unexplained timing multipliers to force a match.

## 4. Documentation baseline and verification design

### 4.1 Published inputs, not new hardware microbenchmarks

Record document revision, table, units, access conditions, and conversion for
each parameter. AMD PG276 Performance specifies HBM AXI-port latency in memory
clocks: direct routing is 90 clocks for an open page and 108 for a closed page;
global addressing gives minima of 110 and 128 clocks respectively. At 900 MHz
these correspond to 100/120 ns and approximately 122.2/142.2 ns. Select the
applicable case from the archived platform configuration, not convenience.
These are HBM-IP boundary references, not measured `vortex_axi` end-to-end
latencies or a maximum under contention. Document the reference transaction
and any interpretation not established by the published table.

U55C specifies 460 GB/s aggregate bandwidth. PG276's 256-bit AXI port at
450 MHz gives 14.4 GB/s per HBM port and 460.8 GB/s across 32 ports before
overheads. Kernel-side limits must also apply: a 512-bit port at 100 MHz
provides at most 6.4 GB/s per direction, or 25.6/51.2 GB/s across four/eight
such ports. These are derived interface ceilings, not guaranteed sustained
rates. Account for refresh/DRAM effects once, including effects already present
in Ramulator; do not multiply in a second undocumented efficiency penalty.

### 4.2 Mandatory xclbin-to-RTL provenance gate

For each selected xclbin, let `ARTIFACT_ROOT` mean the directory containing
`bin/`. The hardware-reference source manifest is **`ARTIFACT_ROOT/sources.txt`**
and the archived RTL source directory is **`ARTIFACT_ROOT/src/`**. For example,
`<artifact>/bin/vortex_afu.xclbin` uses `<artifact>/sources.txt` and
`<artifact>/src/`. Resolve these paths to absolute paths from the artifact root,
not from the repository root or from inside `bin/`. There is no `sources/`
directory requirement.

The expected archive layout is:

```text
ARTIFACT_ROOT/                 # Parent of bin/, not bin/ itself
├── bin/
│   └── vortex_afu.xclbin
├── sources.txt               # Archived compilation source manifest
└── src/                      # Archived RTL snapshot
```

For this layout, derive `ARTIFACT_ROOT` from the resolved xclbin path as the
parent of its `bin/` directory. Do not infer a `../sources/` directory. The
temporary reference Makefile must take this artifact root explicitly and use
its sibling `sources.txt` and `src/` entries shown above.

**The current repository RTL has changed and MUST NOT be used as the RTL for
the hardware-reference VCS comparison.** Before any performance comparison:

User-approved RAM-only exception: use `hw/rtl/libs/VX_dp_ram.sv` and
`hw/rtl/libs/VX_sp_ram.sv` from the repository instead of their preprocessed
archived definitions. Their `SIMULATION`
branch avoids synthesis-only BRAM placeholders. Keep archived headers and all
other DUT modules; do not substitute the current core/cache/pipeline RTL.
Select this exception explicitly using `prepare_reference.py --repo-ram`,
record the source hash, and audit the actual compiler paths. No new RAM model
or changes to archived files or production Makefiles are required. Correctness
and hardware-comparison validation gates remain applicable.

1. Resolve the alias, xclbin path, artifact root, `sources.txt`, and `src/`
   snapshot. Record xclbin SHA-256, manifest and snapshot file hashes, and
   available synthesis/link logs identifying
   the snapshot used by that xclbin. Directory proximity alone is not proof.
2. Recover the original defines, generated headers, include paths, RTL file
   list, IP parameters, port geometry, connectivity, and clock settings from
   the snapshot and archived build metadata. A current similarly named config
   is not automatically equivalent. Use archived `platforms.mk`/link settings
   as the reference and explicitly compare them with current generator inputs.
3. Check runtime/device ABI, ISA/extensions, memory map, and application build
   compatibility. Use the same compatible device program binary and inputs on
   hardware and VCS where possible; record hashes and any necessary differences.
4. Build VCS in a dedicated configured build directory using the archived RTL
   and headers plus the current simulator/HBM backend under test. **Use a
   separate temporary Makefile for this hardware-reference VCS compilation;
   do not modify any existing Makefile or shared build helper to redirect RTL
   paths.** Create the temporary Makefile in the dedicated build area and invoke
   it explicitly with `make -f <temporary-makefile> <target>`. Specify the resolved
   `ARTIFACT_ROOT/src/` DUT root, the file list from
   `ARTIFACT_ROOT/sources.txt`, include paths, archived defines,
   and current simulation backend/testbench sources explicitly. Existing build
   recipes may be consulted without editing them; avoid imports that silently
   reintroduce current DUT RTL. Keep generated files, simulator executable, and
   compile caches isolated from normal current-RTL builds. Inspect the manifest's
   path convention before resolving entries; remap historical paths to archived
   `src/` files explicitly where needed, preserving the original manifest.
   Reject missing entries rather than falling back to current RTL. Resolve all
   transitive RTL includes to the archived snapshot. Inspect the effective
   compile file list and include paths; reject silent fallback to current RTL.
   Record compile commands, source manifest, backend revision, and model hash.
   Save the temporary Makefile and its hash with the verification artifacts so
   the reference build remains reproducible; it is not a production Makefile
   change. Current-RTL regressions continue using the unchanged normal build.
5. Preserve the archive and current worktree. Do not overwrite either with the
   other. If adapter compatibility needs simulation-only glue, document its
   behavior and show that it does not alter the archived DUT pipeline/timing.
   A change required inside archived production RTL is a comparability blocker,
   not permission to silently patch that reference.
6. Confirm the actual kernel clock and HBM settings from available metadata and
   runtime clock reporting. Requested synthesis frequency alone is insufficient.
   Override reference VCS clocks to match the selected hardware run.

If the snapshot is missing, incomplete, or cannot be associated with the
xclbin, report that hardware comparison as unavailable. Continue model tests,
but do not substitute current RTL or require new synthesis to hide the gap.

### 4.3 Three separate verification tracks

| Track | Inputs and procedure | What it establishes |
| --- | --- | --- |
| Model contract | Simulation-only directed tests using existing HBM/AXI harnesses, official bounds, and documented latency boundary conversions | Correct implementation of the chosen abstraction, not measured board fidelity |
| Historical hardware comparison | Existing xclbin on U55C versus the artifact root's `sources.txt` and `src/` RTL in VCS, with matched clocks/config/program/data | Workload-level agreement for that exact historical design |
| Current RTL regression | Current repository RTL and matching current configs in VCS | Functional compatibility with current development; not a comparison to an older xclbin |

For model-contract tests, cover isolated aligned reads (one outstanding,
drained queues, RREADY high), open/closed-page cases, single/all-port read and
write streams, burst/outstanding sweeps, and mixed traffic. Use simulation-side
instrumentation only; no measurement RTL is added to hardware. Check both the
HBM reference boundary and separately documented CDC/converter/publication
overhead at `vortex_axi`. Collect steady-state accepted bytes and drain time;
write B timing is diagnostic, not physical DRAM persistence latency.

### 4.4 Existing-xclbin workload comparison procedure

1. Start with one available, fully matched port/configuration profile. Validate
   another profile only if it has its own xclbin and source provenance; do not
   generalize an eight-port result to four ports.
2. Run a small correctness smoke test, then existing compatible DMA and GEMM
   workloads. Select DMA sizes spanning startup-dominated and long-stream cases;
   select GEMM sizes spanning memory-sensitive and compute-heavy cases within
   the archived design's supported shapes and memory capacity. Record the exact
   applications, dimensions, seeds, strides, options, and binary hashes before
   execution. Unsupported workloads are reported, not enabled by changing RTL.
3. Validate output data first. Use identical initial buffers and launch order,
   with a documented warm-up/reset/cache policy. Avoid unrelated board traffic
   and record temperature, runtime clocks, and evidence of throttling if exposed.
4. Use existing device cycle/performance counters where available. Record their
   definitions and start/end boundaries; compare kernel cycles and derived
   device time, excluding host startup, BO transfer, PCIe, and VCS wall time.
   Report memory stalls/traffic only if existing hardware counters expose them.
   Application bytes divided by kernel time is effective workload throughput,
   not a direct HBM-port bandwidth measurement or isolated zero-load latency.
5. After warm-up, collect at least five hardware samples per case and report
   median, min/max, and variability. Replay VCS at least twice for determinism.
   Keep raw logs and machine-readable results. If only host wall time is
   available, label it separately and do not use it to fit HBM timing.
6. Compare both the unchanged model and documentation-based model against the
   same hardware data using the same archived DUT. For every comparable metric,
   report signed and absolute relative error, with zero-denominator handling.
   Establish an intended error tolerance after assessing repeatability and
   before evaluating held-out cases; do not declare success using an invented
   universal tolerance or hide worst-case error in an average.
7. Freeze documented parameters before held-out workload evaluation. If an
   exploratory subset motivates tuning, distinguish fitted values from document
   values, preserve a held-out subset, and record every revision. Diagnose ABI,
   clock, cache, workload, and source mismatches before blaming HBM contention.

Suggested result fields: xclbin hash, snapshot-manifest hash, model/backend hash,
config and clocks, application/program hash, input/case ID, repetition, output
check, hardware/model cycles and device time, available counters, errors, and
measurement limitations. Store commands and full logs alongside the table.

## 5. Execution sequence

1. **Establish provenance.** Complete Section 4.2 for an existing xclbin and its
   artifact-root `sources.txt` and `src/` RTL; identify actual clocks and
   uncalibrated model gates.
2. **Record document inputs.** Select conditional latency and bandwidth bounds
   from Section 4.1; distinguish HBM-IP and kernel-interface boundaries.
3. **Establish a matched baseline.** Build archived RTL with the current unchanged
   simulator backend and run the Section 4.4 smoke/baseline cases. No new hardware
   RTL or synthesis is part of this step.
4. **Implement the minimal mode.** Add the versioned profile, deterministic byte
   budgets, and residual latency while retaining Ramulator and AXI correctness.
   Replace overlapping abstract-switch penalties and run model-contract tests.
5. **Freeze and compare.** Follow the repeatability, error reporting, and held-out
   workload procedure in Section 4.4. Missing hardware does not block model
   tests, but leaves workload-level board validation explicitly incomplete.
6. **Run current RTL regressions separately.** Publish both reference-design
   performance results and current-development functional results without
   conflating their DUT revisions.

## 6. Verification and acceptance

- Unit tests cover profile validation, rate limits over time windows with a
  bounded burst allowance, aggregate sharing, finite queues, fairness, idle
  periods, reset, and residual latency without double counting.
- Clock overrides preserve physical-time bandwidth/latency semantics and
  deterministic traces; host CPU load must not advance device time.
- Existing configuration, AXI guard, adapter, transport, and memory correctness
  regressions remain passing. Update topology-specific expectations explicitly
  for the selected abstraction; do not silently weaken protocol tests.
- Source the appropriate `configs/` profile and run tests from the configured
  build directory. Run blackboxes through `ci/run_black.sh xrt-vcs-sim`, using
  the `run-bb-common` skill when executing them. Do not substitute simx/Verilator.
- Configure dedicated build directories before tests with
  `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`
  when placed immediately below the repository; otherwise use the resolved
  repository configure path. Audit configure-generated copies and compile
  paths so reference builds still consume archived RTL, not current copies.
- For historical-reference runs, compile with the temporary Makefile from
  Section 4.2 and verify that the blackbox launch uses that exact simulator
  executable and manifest. Use a supported prebuilt/no-rebuild launch mechanism
  if available; do not allow a wrapper-triggered normal build to replace it with
  current RTL. If that launch path is unavailable, report the integration gap
  before running; do not modify existing Makefiles or silently substitute a
  different simulator. Record the launch command and executable hash.
  User-selected launch solution: copy `ci/run_black.sh` to a temporary wrapper
  and add `--run-only` forwarding only to that copy. Keep the original wrapper
  and existing Makefiles unchanged. The initial temporary copy is
  `build_hbm_reference/ci/run_black.reference.sh`; invoke it with `bash` from
  the configured build directory. Verify executable and manifest hashes before
  and after each no-rebuild reference launch. The inner blackbox resolves simv
  from its build root, so the historical launch layout must point that path to
  the archived stage; `--run-only` alone does not select an archived executable.
- Hardware runs use `ci/run_black.sh hw --fpga-bin <verified-alias>` from a
  configured build directory. Confirm the alias resolves to the intended xclbin
  and equivalent archived configuration. Do not add `--configs-extra` or silently
  accept a drifted alias config. Resolve mismatches before launching hardware.
- Acceptance requires passing model-contract tests, functional regressions,
  and explicit per-case hardware comparison results where available. Claim
  workload agreement only within the recorded tolerances and tested historical
  configuration. Documentation-based latency is not hardware-measured latency;
  absent counters do not justify a claim of direct bandwidth/latency validation.
- Add detailed contention only after a repeatable validation error demonstrates
  that the omitted behavior matters. Treat that as a separately scoped decision.

## 7. Deliverables

- Versioned, provenance-bearing calibration profile and simulator integration.
- Document-derived parameter table and simulation-only directed tests.
- Existing-xclbin/archived-RTL provenance manifest and workload run procedure.
- Machine-readable reference results, model comparisons, and error summary.
- Regression tests and updated model documentation distinguishing calibrated
  bandwidth/latency from unsupported internal-switch fidelity.

## References

- [AMD U55C product brief](https://www.amd.com/content/dam/amd/en/documents/products/accelerators/alveo/u55c/alveo-u55c-product-brief.pdf)
- [AMD PG276 Performance: latency table and clock limits](https://docs.amd.com/r/en-US/pg276-axi-hbm/Performance)
- [AMD PG276 Raw Throughput Evaluation](https://docs.amd.com/r/en-US/pg276-axi-hbm/Raw-Throughput-Evaluation)
- [AMD PG276 HBM performance concepts](https://docs.amd.com/r/en-US/pg276-axi-hbm/HBM-Performance-Concepts)
- [Prior local hardware evidence](../u55c-vcs-hbm-model/hardware-evidence.md)
- [Existing model documentation](../../sim/xrtsim_vcs/HBM_MODEL.md)
