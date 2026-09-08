# U55C memory model

Deterministic transaction-level implementation and scoped acceptance are
complete. See `agent-tasks/u55c-vcs-hbm-model/acceptance-audit.md` for the
requirement/evidence map and the fidelity limits below before interpreting
results as physical U55C performance.

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
- The DRAM profile is HBM2_2Gbps, with tCK checked against Ramulator at startup
  (currently 1000 ps). `HBM_AXI_FREQ_HZ=300000000` is a model input, not a claim
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
  a single B notification slot is charged per burst after all beat admissions.
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

The switch is an **uncalibrated abstract paired-PC-link profile**. Each kernel
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
