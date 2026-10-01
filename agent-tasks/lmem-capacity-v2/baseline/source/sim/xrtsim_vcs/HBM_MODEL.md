# U55C memory model

The original deterministic transaction-level implementation has a scoped
acceptance audit in `agent-tasks/u55c-vcs-hbm-model/acceptance-audit.md`.
The optional performance mode described below has a separate, user-accepted
workload calibration audit in `agent-tasks/u55c-hbm-performance-calibration/acceptance-audit.md`;
the earlier audit does not establish physical U55C performance accuracy.

The calibration task now records an opt-in effective-delay candidate meeting
a prospectively selected10% kernel-cycle error target on three held-out GEMM
cases for one historical100MHz image (maximum4.272%). See
`agent-tasks/u55c-hbm-performance-calibration/RESULTS.md` for the profile,
reproduction paths and accepted provenance limitations. The adopted opt-in
profile is `profiles/u55c-temp-100mhz-workload-v1.json`, numerically identical
to the frozen candidate. Its hardware-calibrated label means workload timing
only. The production document profile and default selection are unchanged.
These results are not direct physical HBM latency measurements.

## Ownership and launch

The normal host application/runtime launch flow is unchanged. The blackbox
wrapper launches `simv` and the host application as separate processes. The
host XRT shim retains BO allocators and control-register calls. It no longer
owns device RAM, DramSim or a free-running simulation thread.

After accepting both sockets, the VCS DPI server creates the memory model and
validates the host manifest hash/protocol version. The testbench also compares
its embedded manifest hash and port count to DPI. Host BO transfers use the
memory socket; DUT AXI transactions call the local model directly.

BO transfers are split into at most 1 MiB frames. A write acknowledgment means
the authoritative RAM has been updated. Host register calls and BO transfers
share a mutex, so a kernel-start command cannot overtake a completed upload.
Transport waiting consumes wall time only, never advances device time itself.

## Configuration

Run from a configured build directory and source a valid `configs/` profile.
For example, from `build/`:

```sh
source ../configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh
export LOGIC_FREQ_HZ=250000000
export HBM_AXI_FREQ_HZ=300000000
ci/run_black.sh xrt-vcs-sim --app vecadd --args '-n 64'
```

`XRT_VCS_PLATFORM` defaults to the abstract target identity `xilinx_u55c`.
It can identify a specific U55C platform, but doing so does not verify physical
routing or clock metadata. Other board families are rejected.

The VCS Makefile evaluates the source hardware `platforms.mk` and shared
`geometry.mk`; it does not duplicate the connectivity table. The generated
`u55c_model_manifest.json`, `u55c_model_config.h` and
`u55c_model_config.svh` live in the simulator output directory. The manifest
records frequencies, reachable PCs, source hashes and abstraction limits.

Changing HBM port count also requires compatible DMA/TMEM geometry. In
particular, four HBM ports cannot support the current RTL's eight-DMA profile.

## Time and visibility contract

- VCS is the sole device-time authority. At negedge the adapter replays the
  preceding posedge's accepted requests before advancing past that timestamp.
- Logic clock edges use retained rational remainders; HBM and DRAM edge order
  uses exact rational comparisons with upward quantization to 1 ps. Epoch zero
  is not a memory clock edge. Each advance includes its upper-bound timestamp.
- Exact coincident memory edges execute DRAM before HBM AXI. Newly completed
  responses cannot traverse the return link on that same timestamp.
- Request CDC requires two HBM receiving edges. Completed return transfers
  require two subsequent logic receiving edges in the model. The TB publishes
  at negedge for stable sampling at the following posedge, adding adapter
  publication delay; output backpressure can delay actual acceptance further.
- The default DRAM profile is HBM2_2Gbps, with tCK checked against Ramulator at
  startup (1000 ps). The optional performance profile can select the explicit
  900 MHz timing adapter instead. `HBM_AXI_FREQ_HZ=300000000` is a model input, not a claim
  that the physical memory clock is 300 MHz. Legacy `MEM_CLOCK_RATIO` is not
  applied to this raw-cycle path.
- AR snapshots functional RAM at acceptance. W updates strobed bytes when
  associated with its AW, including previously queued W-before-AW data. This
  supplies consistent buffered-write visibility; DRAM callbacks only determine
  response timing. B is a buffered acknowledgment, not media completion.
- Every full-width 64-byte beat issues two contiguous 32-byte timing requests.
  Reads aggregate both completions; all write beats are timed. Response order
  is FIFO per port and R/B channel, stronger than AXI's same-ID requirement.
  Read data occupies two return-link slots per beat. Writes return no data:
  in legacy mode a single B notification slot is charged per burst after all
  beat admissions. Performance mode handles B separately without charging a
  read/write data-byte budget for the notification.
- Aligned full-width INCR bursts of up to 64 beats are supported and must not
  cross a 4 KiB boundary or the port's manifest reachability range. Other AXI
  transfer shapes are rejected rather than silently reinterpreted.
- Model reset cancels outstanding timing work, recreates Ramulator and preserves
  RAM. Production TB runtime reset calls DPI once per assertion, clears its
  response queues and continues advancing timing while reset is held. Host
  sockets remain connected; command servicing resumes after reset. Directed
  tests cover held R/B, queued responses and preserved RAM. In-flight host
  control reset cancels the session with an explicit fatal/transport closure if
  an accepted register operation has not yet received its host response; no
  success ACK is fabricated. With no pending register operation, reset preserves
  the host connection and RAM. `+TEST_CONTROL_RESET=1|2` is explicit TB fault
  injection for queued/active-command regression tests, not a host reset API.
- Host socket EOF, malformed memory frames and failed control transfers are
  reported to the TB as fatal transport errors, with model/socket cleanup.
  A queued control command is checked before memory EOF so the host's normal
  shutdown packet is not lost when it immediately closes its sockets.
- `VCS_TRANSPORT_TIMEOUT_MS` bounds each exact-buffer send/receive using a
  monotonic wall-clock deadline (default 300000 ms, positive integer required).
  Partial progress does not renew the deadline. A header and its payload are
  separate buffers, as are each chunk's ACK and data. Timeout returns a transport
  error; it never advances simulated time. Set a larger limit for unusually
  slow instrumented runs, and propagate it to both host and simv. Idle device
  execution with no pending transfer is not timed out by this mechanism.

## Fidelity limits

The physical byte layout is 32 contiguous 512 MiB PCs over 16 physical channels.
Ramulator uses an explicit 128-bit channel width and two-entry prefetch, with
ChRaBaRoCo mapping. Kernel AXI ports are not treated as physical DRAM channels.

By default the switch is an **uncalibrated abstract paired-PC-link profile**. Each kernel
port and paired-PC physical-channel link can service one 32-byte fragment per
HBM edge in each direction. Queues are finite: 256 reserved read responses,
16 write bursts and 64 unassociated W beats per port, plus bounded TB egress
queues. These values do not claim to reproduce proprietary HMSS buffering,
arbitration, ingress wiring or measured U55C bandwidth/latency.

SP_FLAGS proves address reachability only. Older linked HMSS paths and clocks
are documented in `agent-tasks/u55c-vcs-hbm-model/hardware-evidence.md`; they do
not prove current-profile wiring or timing. The manifest explicitly labels the
abstract fallback. Do not use application cycle counts as calibration data
without a corresponding measured hardware workload and stated tolerance.

## Optional documentation-based performance mode

Keep the kernel default at 100 MHz. From a configured simulator build directory,
after sourcing the selected config, enable the candidate profile with:

```sh
export LOGIC_FREQ_HZ=100000000
export HBM_AXI_FREQ_HZ=450000000
export U55C_PERFORMANCE_PROFILE="$(realpath ../../../sim/xrtsim_vcs/profiles/u55c-pg276-v1.json)"
make -f ../../../sim/xrtsim_vcs/Makefile hbm-config
```

This only generates configuration; rebuild all consumers before running. The
profile path must identify valid schema-version-1 JSON, and the selected HBM
AXI frequency must match the profile. Its contents and timing-backend source
hashes participate in manifest identity. A stale host/simulator manifest is
rejected at connection. Unset `U55C_PERFORMANCE_PROFILE` and regenerate/rebuild
to return to the original model. Do not mix outputs from different profiles.

Profile status distinguishes `documentation-based`, `hardware-calibrated`, and
`diagnostic-only`. The last is for explicitly labelled sensitivity experiments,
not a documented board value or an accepted calibration. It is selected only
through the same explicit profile path; it does not change the default profile.

The candidate retains Ramulator with exact rational 900 MHz edge scheduling,
explicit timing minima, 8H organization and a row/bank/column timing-address
permutation with bank-group interleaving. Functional RAM addresses do not change.
The legacy DRAM organization/address mapping is unchanged when this mode is off.

Per-port read/write and aggregate read/write/shared byte budgets replace the
paired-PC service gates. Integer-picosecond credit accumulation has bounded idle
credit and resets to zero. Writes consume data credit on 32-byte DRAM admission;
reads consume it on 32-byte return service, after completion and residual delay.
Each port services at most one quantum per direction per HBM edge. Arbitration
advances on successful service; separate R/B queues prevent a delayed read from
blocking write notifications. Ramulator backpressure, refresh, finite model
queues and AXI ordering still apply. No proprietary switch arbitration or
internal contention topology is modeled.

`MemoryModel::service_counters()` exposes simulation-only per-port byte counts
at these charge points. Counters reset with the model and remain zero in legacy
mode. They distinguish actual service from queued host/AXI write acceptance;
they are not hardware counters and do not measure write media persistence.

The current candidate has 14.4 GB/s per-direction port ceilings, a 460.8 GB/s
shared card ceiling, 64-byte port and 1024-byte aggregate burst allowances,
and a 121111 ps residual read delay. These are profile parameters, not guaranteed
sustained kernel bandwidth. At 100 MHz, each 64-byte kernel port itself limits
each direction to 6.4 GB/s; eight such ports cannot demonstrate the card ceiling.
The residual aligns an isolated closed-page model reference with the documented
minimum; it is not measured board latency. CDC, full-beat serialization and TB
publication remain separate, and open-page latency is not independently fitted.
See the JSON provenance and
`agent-tasks/u55c-hbm-performance-calibration/model-progress.md` for measurements
and outstanding acceptance gates. Do not label this profile hardware-calibrated.

Historical xclbin comparisons must use the selected artifact root's
`sources.txt` and `src/`, alongside its `bin/`, through a separate temporary
Makefile. The normal Makefile consumes current RTL and is not that reference
build. Keep historical performance comparison and current-RTL regression results
separate.

## Directed tests and dependency lifetime fix

From `build/sim/xrtsim_vcs/`, after sourcing the selected config:

```sh
make -f ../../../sim/xrtsim_vcs/Makefile hbm-tests
make -f ../../../sim/xrtsim_vcs/Makefile hbm-axi-tests
make -f ../../../sim/xrtsim_vcs/Makefile hbm-adapter-tests
make -f ../../../sim/xrtsim_vcs/Makefile hbm-vcs-transport-tests
```

The first target runs configuration and real-Ramulator native tests, including
every-PC distinct-pattern AXI read/write and abstract ingress contention. The
second checks the production AXI guard. The adapter target replaces only the
accelerator with timed AXI stimulus and compares exact FSDB-off/on handshakes.
The transport target uses the actual accelerator TB and TCP connections to
check BO/register round trips, startup errors, disconnects, partial-frame
deadlines and queued/active control-reset failure. It rebuilds `simv` first.
Keep configurations sequential when sharing the same simulator output directory.

Assertions stay enabled in these tests even when the simulator build uses
NDEBUG. Ramulator lifetime fixes are published in the `jang1664/ramulator2`
fork and pinned at `1c664006681c3ba5fd1e8cfc8ed5178aaa90f070` by the submodule.
`agent-tasks/u55c-vcs-hbm-model/ramulator-lifetime.patch` is retained for
historical reference; do not reapply it to the pinned revision.
The existing dependency build cache belongs to a different checkout; use the
explicit source/build commands in the verification ledger to rebuild it.
The saved patch normalizes original CRLF context; use `git apply
--ignore-space-change` when applying it to the recorded original submodule
revision. Forward/reverse applicability and normalized diff identity have been
checked without modifying the real index during that audit.
