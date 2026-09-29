# U55C HBM model port assessment

Reviewed on 2026-09-29 against fpint-fpga HEAD 73664e653 and the current
uncommitted worktree. Assessment only: no source merge or simulation was run.

## Recommendation

Port the simulator/model changes from the two HBM commits, adapting the build
and port-count integration to this branch. Avoid merging the entire feat/gemv
branch or copying its current testbench wholesale. The work is feasible, but
includes a host/DPI protocol and memory-ownership migration, not just timing
constant changes. Keep workload calibration explicitly selectable.

## Relevant commits

| Commit | Purpose |
|---|---|
| a26daee8b | Pin Ramulator fork at 1c664006681c3ba5fd1e8cfc8ed5178aaa90f070 for lifetime fixes |
| 96dfb6be3 | Deterministic VCS-owned multi-clock model, 32 PCs, finite queues, CDC, AXI checks, manifest handshake, tests |
| 5ff9536d9 | Optional performance profiles, 900 MHz DRAM schedule, 8H RBC timing mapping, byte budgets, residual read delay |

The first model moves authoritative RAM and Ramulator from the host shim to
the VCS DPI server. Host BO/control calls continue over sockets, while DUT
transactions use the local model. The shim, DPI server, protocol header,
testbench and generated configuration must be updated together and rebuilt.
The default refined model and optional calibrated mode are separate choices.

## Applicability checks performed

- `git merge-tree --write-tree --merge-base=96dfb6be3^ HEAD 96dfb6be3`
  found content conflicts in `hw/syn/xilinx/xrt/Makefile` and
  `sim/xrtsim_vcs/xrt_sim_vcs.cpp`. It did not touch the worktree or index.
- The host-shim conflicts mostly concern removal of the old RAM/thread/DRAM
  machinery, whose channel counts differ between the branches.
- A temporary index resolved the host shim to the incoming version and retained
  the current synthesis Makefile, solely for a second merge-tree probe.
  Applying 5ff9536d9 with its parent as base then conflicted only in `.gitignore`.
  This is textual evidence, not a compile/functional pass.
- The dependency commit a26daee8b merged cleanly in a separate merge-tree probe.
  Its target object exists locally. The checked-out dependency is still
  e62c84a6f0e06566ba6e182d308434b4532068a5; no submodule update was performed.
- Extracted the model into a temporary directory and evaluated the current
  `platforms.mk` with each of the four C1/C2/C3/C4 shell configurations.
  The incoming generator accepted all four as eight kernel ports, 32 PCs,
  and a 16 GiB aperture. This checks manifest generation, not RTL elaboration.

## Integration points requiring adaptation

1. Current TB uses NUM_DMA_CHANNELS for external ports; current Vortex_axi
   also defaults its NUM_HBM_PORTS parameter to that macro. There is no
   independent NUM_HBM_PORTS macro in current VX_config.vh. The source branch
   has a broader interconnect separation (b44f5e737). Preserve current eight-port
   geometry and make manifest validation agree with the actual DUT. Reject
   unsupported overrides rather than silently accepting a mismatched model.
   Four-port support is a separate RTL/connectivity change.
2. Current platforms.mk already supplies the required eight contiguous
   four-PC ranges. It lacks source-branch four-port connectivity. No broad
   topology or SLR-floorplan import is needed for the present configurations.
   Supply the small geometry helper for model evaluation and preserve the
   current synthesis Makefile, which also has uncommitted SLR changes.
3. Pin and explicitly rebuild the Ramulator fork. The existing shared library
   and CMake cache predate the required revision; changing the gitlink alone
   does not establish which binary is loaded. The dependency URL changes to
   SSH in the source commit. Shared DramSim keeps its legacy constructor/API
   but adds destruction of owned objects and the new raw U55C path.
4. Retain current GEMM RTL and waveform hierarchy. Changes after 5ff9536d9
   include the metadata-driven naive hierarchy, which is unrelated here.
5. The new Makefile evaluates platform definitions, potentially adding flags
   to prior simulation CONFIGS. Audit the effective definitions and rebuild
   both host library and simv; manifest/protocol checks intentionally reject
   mixed old/new binaries. Address alignment, INCR bursts, 4 KiB boundaries,
   port reachability and stable stalled responses are checked more strictly.
6. Bring the model tests and profile tests with the code. The five calibration
   native tests are registered in the task-specific `model-tests.mk`, not in
   the base `hbm-tests` target; integrate them into the port's test entrypoint.
   Do not import the calibration commit's entire 35k-line experiment archive
   just to obtain the production model and a few tests.

## Calibration boundary

The opt-in document profile uses 100 MHz logic (default), 450 MHz HBM AXI and
900 MHz DRAM, with a 121111 ps residual read delay. The separately adopted
`u55c-temp-100mhz-workload-v1.json` uses 521111 ps instead, a whole-kernel fit
for one historical eight-port image. The recorded maximum held-out cycle
error is 4.272% across three shapes. This accuracy is not established for
the current C1-C4 images or the restored ACC naive path. The historical
256x256x256 workload failed correctness in both hardware and reference VCS;
that record does not establish a defect in this branch's passing workload.

The model does not claim proprietary HMSS switch fidelity or universal U55C
timing accuracy. Preserve profile provenance and keep the fitted profile
opt-in until a current-image hardware comparison establishes its relevance.

## Verification proposed for implementation

Use a separate configured build, with the proper config sourced first.
Run model/config/clock/address/bandwidth tests, AXI guard tests, adapter replay
(including FSDB on/off), and TCP/reset/manifest tests. Run a small vecadd to
exercise BO/control transport, then the previously passing naive ACC ON/OFF
matrix M=1,16,256 and K=N=256 through ci/run_black.sh xrt-vcs-sim. Add C2
elaboration and a C4 improve smoke. Repeat selected simulations to check
deterministic cycle counts. New-model cycle values need not equal old-model
values. Hardware timing calibration remains a separate validation step.
