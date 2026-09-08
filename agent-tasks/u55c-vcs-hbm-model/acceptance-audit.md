# Acceptance audit

This tracks the original plan, including its explicitly permitted abstract
routing fallback. Implementation and scoped acceptance are complete as of
2026-09-08; this is not a claim of calibrated hardware performance. Paths below
are relative to this repository. Detailed test
history and exact commands remain in `STATUS.yaml` and `verification.md`.

## Requirement-to-evidence map

| Plan requirement | Current implementation and evidence | Audit status |
| --- | --- | --- |
| 1.1 shared geometry/platform evaluation | `geometry.mk`, hardware Makefile and VCS `platform_config.mk` share evaluated platform inputs without importing synthesis targets | Implemented; configuration tests passed |
| 1.2 explicit U55C platform, no platforminfo dependency | VCS platform validation and exported resolved inputs; wrong-platform test | Tested |
| 1.3 canonical manifest and C++/SV artifacts | `gen_hbm_config.py` consumes evaluated SP_FLAGS, emits geometry/clocks/provenance and common hash | Tested for four/eight ports |
| 1.4 invalid inputs and startup consistency | Seven configuration tests, including eight invalid route variants; actual TCP hash/version failures; TB/DPI and host/DPI hash checks | Tested |
| 1.4 incremental consumer rebuilds | Deferred source/generated-header digest changes VCS native CFLAGS; same-geometry 250/200/250 MHz runs, native timestamps and host blackbox; source platform/helper dependencies and hash inputs inspected | Verified |
| 1 physical HMSS path provenance | `hardware-evidence.md` records older MXU16 kernel-to-converter-to-HBM ingress paths and incompatible clocks | Explicit abstract fallback permitted by plan; not verified current wiring |
| 2 independent clocks and DRAM tCK | Rational TB clock, `hbm_clock.h`, raw Ramulator API and runtime tCK/width validation | Tested; target physical-clock mismatch documented |
| 2 idle progression and one raw tick per DRAM edge | Scheduler advances even without DUT traffic; memory test checks exact idle edge count; no MEM_CLOCK_RATIO in raw path | Tested at model boundary |
| 2 integer/rational timing, invalid clocks, drift | Scheduler tests cover coincident edges, equal/faster/slower/noninteger rates, million-edge run, epoch and reversal checks | Tested |
| 2 timestamp ordering and registered CDC | Captured actual posedge replayed before later memory events; DRAM-before-HBM order, two-edge CDC and negedge publication documented | Model and production-adapter replay tested |
| 2 reset and shutdown | Model reset recreates timing and preserves RAM; signal reset cancels queued/partial AXI; actual TCP control reset fails accepted commands explicitly | Tested separately across model, adapter and host transport |
| 3 authoritative VCS RAM/timing ownership | Host no longer owns RAM/DramSim or async tick loop; DPI owns model and services BO frames on simulation thread | Actual host blackbox and BO TCP tests passed |
| 3 BO visibility, ordering and address preservation | Bounded chunked protocol, visibility ACK, shared host mutex; PC-boundary transfer, per-PC distinct AXI write/read and retained-value checks | Tested on both port counts |
| 3 reproducibility under host load | Timestamped replay with different advance batching and four CPU-load workers, plus production FSDB off/on traces | Both independent checks passed |
| 3 linkage, include/rpath and stats lifetime | Native VCS linking and host library builds; current-source Ramulator rebuild; ASan lifetime fix; patch normalized hash and forward/reverse applicability checked | Verified with documented CRLF handling |
| 4 physical channel/PC organization and byte mapping | Explicit 16 channels, two PCs/channel, 128-bit channel width, 32-byte transaction, contiguous physical byte mapping | Raw/model and strengthened nonaliasing tests passed on both port counts |
| 4 full burst reachability and contiguous split | Aligned full-width INCR validation, 4 KiB/aperture checks, two 32-byte fragments per 64-byte beat | Unit/guard/production signal tests passed |
| 4 finite buffers, CDC and service rates | Model AR/AW/W reservations and finite TB egress; 256-read/16-AW/64-W exhaustion/recovery; per-response-prefix service bounds | Tested |
| 4 shared-resource contention including returns | Abstract same-ingress paired-PC/different-channel streams versus independent/all-port traffic; both directions have per-edge service budgets | Abstract ingress behavior tested; no proprietary route fidelity claimed |
| 4 AW/W skew, strobes, LAST, ordering, one B | Real adapter tests on every port and bounded skew/reset states; distinct ID/order/readback assertions | Tested |
| 4 split completions and all write beats timed | Model waits for two read fragments and all burst write beats; B explicitly buffered acceptance, AR snapshots/W-association visibility | Tested/documented |
| 4 avoid timing double-counting and label assumptions | HBM link/CDC service is separate from DRAM raw ticks; legacy ratio excluded; source audit removed spurious write-data return charge; exact 1/2/4-beat B timing tests passed | Source reviewed; directed and both-port blackbox regressions passed |
| 5.1 configuration matrix | Seven tests plus TCP mismatch and source-unchanged frequency blackbox | Passed |
| 5.2 scheduler matrix | Rational clock tests and idle model progression | Passed |
| 5.3 AXI/data matrix | Native/guard/signal/TCP tests; per-PC distinct AXI writes and retained-value checks | Expanded tests passed on both port counts |
| 5.4 topology matrix | Four/eight-port independent, paired PC, same ingress and all-port cases with service bounds | Passed for labeled abstract profile |
| 5.5 determinism | CPU-load model replay and exact FSDB-on/off production handshake traces, rerun after final write-return fix | Passed: four-port 660 and eight-port 808 identical handshakes |
| 5.6 configured VCS integration | Final four-port vecadd 16208 cycles and eight-port 14110, clean shutdown and no Fatal/Error; required wrapper/config procedure used | Passed: `build/hbm_vecadd_write_return_{4p,8p}*.log`, sessions 73124/84272 exit 0 |
| 5.7 calibration and limitations | Older linked artifact AXI450/DRAM900 MHz versus model AXI300/tCK1000ps; no matching directed hardware dataset available in inspected artifacts | Explicit limitation, not a hardware performance claim; new measurements outside this plan's execution scope |

## Final audit outcome

Final source audit on 2026-09-08 found spurious write-data return bandwidth:
the old implementation charged two return slots per write beat. It now retains
all DRAM write-fragment timing but charges one B notification slot per burst.
Both-port native suites (including exact notification timing), production
adapter regressions and host blackboxes passed after that fix. Final runtime
logs were inspected independently of exit code and preserved. Header/source
dependency paths, ownership/callback destruction order, legacy raw/tick API
separation, event scheduling, bounded queues, address mapping and host protocol
were reviewed against the implementation. `git diff --check` passed.

No implementation/verification step remains for the plan's transaction-level
scope. Known limits are deliberately retained: the abstract ingress/channel
links are not proprietary HMSS arbitration, older physical routes are not
current-profile wiring proof, and no matching measured latency/bandwidth
dataset supports hardware performance tolerances. The plan explicitly permits
that labeled fallback and excludes new hardware measurements from this task.
Read `hardware-evidence.md` before interpreting model cycle counts as U55C
performance. Ramulator lifetime fixes are published in the `jang1664/ramulator2`
fork at `1c664006681c3ba5fd1e8cfc8ed5178aaa90f070` and pinned by the parent
submodule. The verified portable patch is retained for historical reference.
No hardware run was made.
