# Verification ledger

The requirement-by-requirement current audit is in `acceptance-audit.md`.
The final post-write-return-fix blackboxes passed on both port counts. Earlier
results below are historical and must not replace that final timing evidence.

## Latest model evidence

| Check | Current result | Log under build/ |
| --- | --- | --- |
| Four-port native suite | Seven configuration + seven C++ tests passed | `sim/xrtsim_vcs/hbm_tests_write_return_4p.log` |
| Eight-port native suite | Seven configuration + seven C++ tests passed | `sim/xrtsim_vcs/hbm_tests_write_return_directed_8p.log` |
| Four-port production replay | 660 identical FSDB-off/on handshakes | `sim/xrtsim_vcs/hbm_adapter_write_return_4p*.log` |
| Eight-port production replay | 808 identical FSDB-off/on handshakes | `sim/xrtsim_vcs/hbm_adapter_write_return_8p*.log` |
| Four-port final host blackbox | Clean PASSED, 16208 cycles | `hbm_vecadd_write_return_4p*.log` |
| Eight-port final host blackbox | Clean PASSED, 14110 cycles | `hbm_vecadd_write_return_8p*.log` |
| Actual host TCP errors/reset | Fourteen cases passed, including queued/active read/write reset EOF | `sim/xrtsim_vcs/hbm_vcs_control_reset_4p.log` |
| Frequency-only native rebuild | 250/200/250 MHz, native timestamps and all-layer hash handshake verified | `sim/xrtsim_vcs/hbm_vcs_frequency_only_4p.log`, `hbm_vecadd_audit_4p.log` |

Native suites cover exact B notification timing, every-PC distinct-pattern AXI
write/read/nonaliasing, rational edge counts, finite controller admission, BO
visibility, loaded deterministic replay and abstract ingress service bounds.
The guard and lifetime sanitizer checks are recorded below. The patch identity
and forward/reverse checks are at the end of this file.

## Historical evidence during implementation

- Shared source `platforms.mk` is evaluated by VCS Make; generated manifest,
  C++ header and SV header carry a common hash. Six configuration tests cover
  4/8-port reachability, duplicate/conflicting defines, invalid clocks, invalid
  DMA/HBM geometry and output regeneration. Startup compares host/DPI/RTL hashes.
- Standalone rational scheduler tests cover 100/250/300/600 MHz logic sampling,
  300 MHz HBM AXI, coincident-edge order, reset, repeated timestamps and one
  million DRAM edges. Timing comes from VCS picosecond timestamps, not host ticks.
- Raw DramSim tests use the real HBM2 model, 16 physical channels and 32 PCs,
  contiguous byte addresses, finite controller admission and buffered write ACKs.
- Standalone memory-model tests cover 32-PC readback, split aggregation, bursts,
  strobes, W-before-AW, held responses, ordering, AR/AW/W exhaustion, reset,
  address rejection and idle DRAM advancement.
- Socketpair BO tests cover manifest mismatch, >1 MiB chunked transfer, PC
  boundary crossing, readback, write visibility and no transport-driven ticks.
- Replay test compared 512 response timestamps under different advance batching.
  The concurrent four-worker CPU-load variant also passed, with 512 responses
  for eight ports and 256 for four ports.
- Before lifetime fixes, valid-config VCS `vecadd -n 64` passed without simv
  errors at 4 ports/250 MHz logic (16623 cycles) and 8 ports/100 MHz logic
  (14110 cycles), both with 300 MHz HBM AXI and FSDB enabled.
- Production-adapter replay (only the accelerator replaced by AXI stimulus)
  passed on 4/8 ports with 528/556 identical FSDB-off/on handshake timestamps.
  It covers W-before-AW, held R/B, 256-beat read exhaustion, 16-AW exhaustion,
  64 unassociated W beats, bounded TB egress, response order and credit recovery.
- Runtime reset now reaches the DPI model. The four-port reset-expanded replay
  passed with 533 identical timestamps: held R/B and queued responses are
  canceled, admission recovers, and a previously written RAM value survives.
  Eight-port reset-expanded replay also passed with 561 identical timestamps.
  Logs: `build/sim/xrtsim_vcs/hbm_adapter_{4p,8p}_reset_{no_fsdb,fsdb}.log`.

## Historical gate investigations (superseded by the current audit)

Latest signal-level expansion passed at four/eight ports with 657/805 identical
FSDB-off/on handshake timestamps. Full/zero/alternating/boundary-bit WSTRB masks
are checked by readback on every port. Reset also cancels AW-only, W-only and
incomplete two-beat-burst state; fresh write/read traffic verifies no stale
association. Logs: `build/sim/xrtsim_vcs/hbm_adapter_{4p,8p}_strobes_{no_fsdb,fsdb}.log`.

1. Correct local Ramulator rebuild and ASan leak elimination passed (exit 0,
   `hbm_model_asan_final.log`); rerun all unit and VCS integration tests after
   changing object destruction.
2. Standalone `hbm-tests` passed for both 4 and 8 ports, including CPU-load
   replay, after lifetime fixes. Preserve these checks on subsequent model edits.
3. Preserve the signal-level skew/stall/credit/strobe/reset/replay coverage above;
   audit reset with in-flight host control operations.
   Rerun blackbox after the production ready/reset changes.
4. Exercise topology/resource contention with directed traffic and establish
   per-port and aggregate service bounds. The current paired-PC abstract links
   need scrutiny: disjoint port reachability can hide shared-link contention.
   New eight-port directed C++ test passed for two 64-beat streams: independent
   ports finish at 828 ns, shared ingress with distinct physical channels at
   1528 ns, paired PCs at 1492 ns (one stream alone 828 ns). Data/ID/LAST and
   the ingress 32-byte/edge lower time bound are checked. These are uncalibrated
   model measurements, not hardware results. The case proves shared ingress
   contention but does not independently isolate physical-channel arbitration
   or verify an implementation-derived HMSS route. Four-port expanded run
   passed with the same times and all four concurrent independent streams
   completing at 828 ns. It additionally checks per-port/aggregate service
   bounds at every received-response prefix. Full four-port suite passed after
   fixing the configuration test's inherited-clock baseline assumption; see
   `hbm_tests_topology_4p_fixed.log`. Eight-port expanded rerun also passed with
   all eight streams finishing at 828 ns (`hbm_tests_topology_8p_all.log`).
5. Audit reset and shutdown protocol, error propagation, outstanding transfers,
   startup mismatch termination, full C++/SV configuration consistency and
   incremental consumer rebuilds, not only manifest file regeneration.
   The production polling helper now returns transport errors instead of idle
   on EOF and prioritizes a queued control command over memory EOF (required
   by normal host destructor shutdown ordering). Seven socketpair scenarios
   passed: control EOF, memory EOF, queued shutdown with both peers closed,
   truncated control, oversized memory header, truncated hello and unknown
   memory command. TB now treats polling/receive/send failures as fatal and
   closes the model/sockets. Eight real VCS TCP cases subsequently passed:
   BO roundtrip/shutdown, wrong hash/version, control/memory EOF, partial/invalid
   control and oversized memory. Logs are under
   `build/sim/xrtsim_vcs/hbm-vcs-transport-tests/` and summary
   `hbm_vcs_transport_8p.log`. Connected mid-frame stalls now have a monotonic
   total-buffer deadline, default 300000 ms (`VCS_TRANSPORT_TIMEOUT_MS`). Native
   receive and send timeout tests passed with ETIMEDOUT; ten-case actual VCS
   suite including connected-stalled control/memory passed after fixing stale
   native objects via header-content hash in VCS CFLAGS. Evidence:
   `hbm_vcs_deadline_rebuild_8p.log`, session 98072 exit 0. Shutdown with
   outstanding device work: eight-port production-adapter cleanup passed with
   AW-only, W-only and a held long-read response (808 identical FSDB-off/on
   handshakes). This uses the actual DPI close function but does not combine a
   host TCP shutdown packet with outstanding DUT traffic in one test. Four-port
   cleanup replay also passed with 660 identical traces. Control reset policy
   now explicitly closes the session on any accepted unacknowledged register
   command. Four actual queued/active read/write fault-injection cases require
   host EOF and the exact cancellation fatal; all passed in the fourteen-case
   four-port suite (`hbm_vcs_control_reset_4p.log`, session 5585 exit 0).
   The 250-to-200 MHz same-geometry rebuild passed fourteen cases with both
   DPI/model object timestamps updated (`hbm_vcs_frequency_only_4p.log`, session
   94344 exit 0). A source-unchanged return to 250 MHz plus host blackbox is next
   to distinguish frequency invalidation from the initial build-rule edit.
6. Initial linked HMSS/platform inspection found older MXU16 artifacts; see
   `hardware-evidence.md`. Complete outer kernel-to-HMSS mapping and manifest
   compatibility checks; compare available measured latency/bandwidth or
   explicitly record absence. Do not equate SP_FLAGS reachability to verified ingress.
7. Document public usage, timing/visibility/ordering semantics, model limits and
   the final requirement-by-requirement acceptance results.

## Dependency rebuild warning

The pre-existing `third_party/ramulator/build/CMakeCache.txt` belongs to another
checkout (`vortex_fpint`). Do not use it. The initial rebuild accidentally used
that cache and did not update this checkout's library. No source there was edited.

Use the current source explicitly:

```sh
cmake -S third_party/ramulator -B build/ramulator-u55c -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build build/ramulator-u55c --target ramulator -j4
```

The Ramulator lifetime fixes are committed and published in the
`jang1664/ramulator2` fork on branch `vortex-hbm-lifetime`, at
`1c664006681c3ba5fd1e8cfc8ed5178aaa90f070`. The parent submodule pins that
revision. `ramulator-lifetime.patch` remains a historical portable artifact
against `e62c84a6f0e06566ba6e182d308434b4532068a5`; do not reapply it to the pinned revision.

Before committing, patch consistency was checked against the submodule diff after CRLF
normalization (SHA256 `4044a06716cc3a8ff61b72013c850d53431f8e284f576564b0323be5b10bbd91`).
The original headers mix CRLF context with LF additions. Forward applicability
to HEAD was verified using an isolated temporary Git index, and reverse
applicability to the current worktree was checked, both with
`git apply --check --ignore-space-change` (plus `--cached` or `--reverse`).
Use `--ignore-space-change` when applying the saved LF-normalized patch to that
original checkout; these checks did not modify the submodule's real index/files.
