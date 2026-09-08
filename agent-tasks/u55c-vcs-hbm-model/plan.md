# U55C HBM modeling in xrt-vcs-sim

## Objective and scope

Implement deterministic, frequency-aware U55C memory simulation while retaining
DramSim/Ramulator. VCS simulation time owns all device-side progress. The user
selects the logic frequency independently of the HBM AXI and DRAM frequencies.
Consume `hw/syn/xilinx/xrt/platforms.mk` during the VCS build so simulation and
hardware use the same external memory-port connectivity specification.

This document is an implementation plan; no simulator changes are included in
this planning task. Do not introduce an FSM or change other simulator backends as
part of this task unless needed for a compatible shared API extension.

## Confirmed starting point

- `sim/xrtsim_vcs/xrt_sim_vcs.cpp` owns RAM and DramSim in the host process. An
  independent async loop calls `process_axi_events()` and advances DramSim once
  per iteration, regardless of VCS time.
- `sim/xrtsim_vcs/tb_vcs_xrtsim.sv` runs a fixed 10 ns logic clock, captures AXI
  handshakes on posedge, and polls/sends socket traffic on negedge. Socket packets
  carry no simulation timestamps or synchronization barriers.
- `sim/common/dram_sim.cpp` uses the Ramulator `HBM2_2Gbps` preset. The local
  preset has a 1 ns tCK. `MEM_CLOCK_RATIO` scales API calls, not VCS elapsed time.
- `sim/xrtsim_vcs/Makefile` links DramSim into the host library, not the VCS DPI
  model, and does not currently include the platform connectivity file.
- `platforms.mk` sets U55C memory to 16 GiB, with 32 addressable 512 MiB HBM
  regions, and generates `SP_FLAGS` from `NUM_HBM_PORTS` independently of
  `NUM_DMA_CHANNELS`. It requires the shared `gemm_geometry_value` helper, `XSA`,
  `DEV_ARCH`, and effective `CONFIGS` to be established before evaluation.
- The current host constructs DramSim with `NUM_HBM_PORTS` channels. External
  kernel AXI ports must not be assumed to equal physical HBM channels or PCs.

## Architecture decision

Move device RAM and the memory timing model into the VCS process, accessed through
DPI. Retain the host XRT shim for BO bookkeeping and control transport. Transfer
host uploads/downloads through an explicit memory-service protocol to the same
authoritative RAM instance. Eliminate the host's free-running DRAM tick loop.

```text
Host XRT shim -- control / BO transfer sockets --> VCS DPI services
                                                   |
Vortex_axi -> AFU external AXI ports [logic clock]   |
                    |                              |
          finite request queues / CDC model        |
                    |                              |
     width conversion + HBM switch [HBM AXI clock]  |
                    |                              |
       physical channel / pseudo-channel mapping   |
                    |                              |
          DramSim / Ramulator [DRAM tCK] <----------+
                    |
       finite response queues / CDC -> DUT AXI
```

The first version is a deterministic transaction-level memory subsystem model,
not a replacement for implementation-level CDC verification or a claim to
reproduce proprietary HMSS arbitration exactly.

## 1. Share platform configuration and connectivity

1. Inspect `hw/syn/xilinx/xrt/Makefile`, `platforms.mk`, and
   `gen_vitis_ini.py` together. Reuse or extract the common geometry helper and
   platform-selection logic without importing synthesis/link targets into VCS.
2. Include the same source `platforms.mk` in the VCS configuration evaluation,
   before deriving C++ flags and VCS defines. Provide an explicit U55C platform
   identity. Avoid silently selecting another platform when metadata is missing.
   Prefer explicit/exported metadata so simulation does not require a live
   `platforminfo` installation just to resolve a known platform.
3. Generate a canonical connectivity manifest from Make-evaluated `SP_FLAGS`;
   do not regex-parse Makefile source or duplicate the port table in C++/SV.
   Record platform identity, effective defines, port widths/counts, allowed PC
   ranges, address aperture, frequencies, and model provenance. Generate the
   C++/SV configuration artifacts from this resolved manifest.
4. Validate conflicting/duplicate defines, missing ports, invalid ranges and
   unsupported geometry. Ensure RTL, DPI, and host agree via a manifest hash
   exchanged at startup. Changes to platform selection, `platforms.mk`, helper
   files, or effective configuration must invalidate generated outputs and
   rebuild affected binaries. Account for configure-generated build copies.

Current expected connectivity:

| External kernel port | NUM_HBM_PORTS=4 | NUM_HBM_PORTS=8 |
| --- | --- | --- |
| m_axi_mem_0 | HBM[0:7] | HBM[0:3] |
| m_axi_mem_1 | HBM[8:15] | HBM[4:7] |
| m_axi_mem_2 | HBM[16:23] | HBM[8:11] |
| m_axi_mem_3 | HBM[24:31] | HBM[12:15] |
| m_axi_mem_4 | absent | HBM[16:19] |
| m_axi_mem_5 | absent | HBM[20:23] |
| m_axi_mem_6 | absent | HBM[24:27] |
| m_axi_mem_7 | absent | HBM[28:31] |

`SP_FLAGS` specifies address reachability, not necessarily the exact physical
HBM switch ingress or internal route chosen by Vitis. Inspect available linked
HMSS configuration, block-design metadata, or connectivity reports to derive
kernel-port -> converter/interconnect -> HBM AXI ingress -> destination PC paths.
Record artifact provenance and its compatibility with the manifest. When exact
routes are unavailable, use an explicitly labeled abstract routing profile;
never report inferred ingress assignments as verified hardware wiring.

## 2. Establish clock and event semantics

- Define independent `LOGIC_FREQ_HZ`, `HBM_AXI_FREQ_HZ`, and DRAM tCK. Derive tCK
  from the selected Ramulator timing profile and validate it against the target
  platform. Do not assume that 300 MHz is the physical HBM clock.
- Parameterize the TB logic clock. Replace free-running host ticks with a
  VCS-owned scheduler that advances HBM AXI and DRAM events to a specified VCS
  time. Idle periods must still advance refresh and pending memory operations.
- Use integer/rational event times with retained remainders. Declare simulation
  precision and bound quantization error; do not accumulate drift by rounding
  each 300 MHz clock period independently. Reject zero/invalid frequencies.
- Add a compatible raw-memory-cycle API or a VCS adapter using ratio=1 so one
  scheduled DRAM edge advances exactly one Ramulator cycle. Do not apply a clock
  ratio twice or change the existing tick contract for other backends.
- Timestamp request acceptance at the actual DUT handshake. If DPI processing
  remains at negedge, batch the captured posedge timestamps and merge them with
  memory events chronologically. Do not advance past unsubmitted requests.
- Specify a total order for coincident clock edges, enqueue, arbitration,
  Ramulator completion, and response publication. Use a registered boundary:
  requests/completions produced on an edge are eligible only at the documented
  subsequent receiving edge. Apply that rule consistently in tests.
- Publish responses only at legal logic-domain boundaries after modeled CDC
  delay. Define reset epoch, reset cancellation/drain behavior, and shutdown.

## 3. Move RAM ownership and host transfers

- Add a VCS-side memory subsystem object wrapping authoritative RAM, queues,
  timing scheduler, routing, and DramSim. Serialize model mutation on the VCS
  simulation thread; background transport workers may enqueue messages only.
- Extend the BO upload/download protocol with explicit address, size, payload,
  status, and completion handling. Acknowledge writes only after their defined
  visibility point; ensure kernel launch cannot overtake preceding uploads.
- Preserve current bank/address conversion semantics and validate them against
  `VX_mem_remap`, `Vortex_axi`, the AFU wrapper, and the platform manifest.
- Host load may affect wall-clock runtime or command arrival time, but must not
  alter memory timing for an identical timestamped device request sequence.
  Use a deterministic command/replay schedule for timing reproducibility tests.
- Update VCS DPI sources, Ramulator/yaml/spdlog include/link flags, runtime library
  paths, and stats lifetime. Remove duplicate device RAM/timing ownership from
  the host only after transfer-path verification.

## 4. Model U55C routing, throughput, and completion

- Distinguish kernel AXI port, HBM AXI ingress, physical channel, pseudo-channel,
  and bank/row/column. Audit Ramulator HBM2 organization and address mapping
  before choosing instance/channel counts; do not substitute 32 channels for
  32 PCs without checking the model's hierarchy.
- Route each beat using its physical address and manifest reachability. Check
  the full burst range. Preserve contiguous byte addresses when splitting wider
  DUT beats into HBM interface beats and DRAM requests; audit the existing
  `DramSim::send_request` width/address conversion for aliasing and overlap.
- Model finite ingress/egress queues, CDC delay in receiving-domain cycles,
  width conversion, arbitration, and configured switch link service rates.
  Apply shared-resource contention where routes overlap, including return paths.
  Tie admission/backpressure to outstanding work and reserved response capacity,
  not only the current TB response queue occupancy.
- Keep AW/W association and burst assembly bounded, with an explicit policy for
  independently arriving AXI channels. Retain byte strobes, burst beat order,
  RLAST, exactly one B per write burst, and same-ID ordering on each channel.
- Aggregate split read completions before releasing a DUT beat. Model all write
  beats, not only one timing request at WLAST. Since the existing DramSim invokes
  write callbacks on controller acceptance, define B as a documented buffered
  write acknowledgment point; do not treat that callback as physical completion.
  Define read-after-write visibility and any forwarding consistently.
- Keep controller/switch overhead separate from Ramulator timing to prevent
  double-counting. Label uncalibrated latency/arbitration parameters explicitly.

## 5. Verification and acceptance

1. Configuration: compare generated simulation connectivity against hardware
   `SP_FLAGS`/Vitis connectivity for both 4 and 8 ports. Exercise invalid and
   duplicate geometry, manifest mismatch, and incremental rebuild invalidation.
2. Scheduler: test equal, faster, slower, and non-integer clock ratios (including
   250:300), coincident edges, long-run drift, reset, and idle refresh. Assert
   exact event counts under the declared epoch and edge-inclusion convention.
3. AXI/data: test bursts, split completions, byte strobes, same-ID ordering,
   AW/W skew, backpressure, queue exhaustion, address boundaries, and BO transfer
   visibility. Verify RAM read/write round trips through each mapped PC.
4. Topology: exercise independent PCs and routes sharing an ingress/link/channel.
   Check per-port width-times-frequency limits, aggregate resource limits, and
   contention behavior using directed traffic independent of application stalls.
5. Determinism: replay identical timed traffic under different host CPU load and
   FSDB settings; compare request/response timestamps and cycle counts exactly.
6. Integration: run RTL tests and xrt-vcs-sim blackbox checks only from a configured
   build directory after sourcing the appropriate `configs/` profile. Configure
   with `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`
   when needed; use `/usr/bin/gcc` and `/usr/bin/g++` for host unit builds. Follow
   `run-bb-common`, inspect `ci/run_black.sh --help`, and run
   `ci/run_black.sh xrt-vcs-sim --app APP --args "..."`. Inspect compile logs
   before simulation logs. Do not substitute simx or Verilator execution.
7. Calibration: compare directed latency/bandwidth against available U55C results
   and platform metadata. Report modeled versus measured values and establish
   tolerances from those workloads before claiming U55C performance fidelity.
   New hardware measurements are a separate execution step, not part of this
   documentation task.

Completion requires a single authoritative device time and RAM state, independent
clock parameters, shared build-time platform connectivity, bounded AXI handling,
passing deterministic directed/integration tests, and explicit provenance for
physical routing and timing assumptions. Missing physical routing/calibration
evidence must remain visible as a fidelity limitation.

## Suggested implementation order

1. Resolve platform inputs and generate/validate the shared manifest.
2. Implement and test the scheduler plus compatible DramSim raw-cycle adapter.
3. Move device memory into DPI and verify host BO/control sequencing.
4. Add CDC, width conversion, PC mapping, and bounded switch service queues.
5. Run the verification matrix and calibrate the U55C profile where evidence is
   available. Record remaining abstraction limits with the resulting profile.

## References

- Local build/connectivity: `hw/syn/xilinx/xrt/platforms.mk`,
  `hw/syn/xilinx/xrt/Makefile`, `hw/syn/xilinx/xrt/gen_vitis_ini.py`.
- Local simulation: `sim/xrtsim_vcs/{Makefile,tb_vcs_xrtsim.sv,xrt_sim_vcs.cpp,
  dpi_vcs_server.cpp,vcs_protocol.h}`, `sim/common/dram_sim.cpp`,
  `third_party/ramulator/src/dram/impl/HBM2.cpp`.
- [AMD U55C HBM memory](https://docs.amd.com/r/en-US/ug1469-alveo-u55c/HBM-Memory):
  two 8 GB stacks, 32 AXI interfaces, and an internal switch.
- [AMD PG276 performance](https://docs.amd.com/r/en-US/pg276-axi-hbm/Performance):
  AXI and memory clock limits are distinct; maximum ratings do not establish the
  actual clocks of a particular linked U55C platform.
