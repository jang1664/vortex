# Naive PSUM read-priority implementation specification

Status: confirmed. User explicitly requested implementation of the accepted plan.

## Fixed scope and selection

TH16/MXU16, current N-fast FSM, Weight8, naive PSUM read/response16, external DMA naive32 / improve16. Existing passing GEMM baselines M4=15970 and M256=671993, K=N512. Preserve all pre-existing uncommitted changes. New files English. No commit, synthesis, fine reset tests, simx, or Verilator simulation requested. Use configured-build ci/run_black.sh xrt-vcs-sim and tools/verify_rtl.py checks. Static preprocessing/elaboration is allowed for identity/width checks.

Implement read priority for independent PSUM accesses and sweep maximum consecutive reads R=1,2,4,8 per bank. Only candidates PASSing all functional checks and not regressing either M4 or M256 are eligible. Pick maximum geometric mean of the two GEMM speedups; ties favor smaller R. If none improves without regression, retain original production mode and report experimental findings.

## Data and dependency tracking

Keep the existing two-entry common compute result data queue and all downstream payload buffers; do not add a write-data FIFO. Add a naive-only16-entry pending-write metadata table (valid, physical PSUM row address, remaining lane bitmap). Addresses must be normalized to physical LMEM geometry; TH16 rows are64 bytes/eight8-byte lanes.

Reserve a metadata slot when a granted write is FIRST PRESENTED to the splitter, before partial lane acceptance. Hold its ID and payload through all-lane wide acceptance. Capacity-full backpressures new writes. Carry slot ID in available low write-tag value bits, retaining UUID/routing bits. Extend naive physical commit feedback with slot/lane identification. Release only after every reserved lane physically commits. Do not count a completely withheld raw-valid write as reserved. Existing aggregate final/PSUM drain counters must remain correct.

Retain the adapter's older-transaction exact-address fence. Replace the node's broad bank-set fence with exact physically pending write lookup. Serialize same-address writes through physical completion; allow different-address pending writes. Protect accepted-but-not-completed reads from younger same-address writes using existing OOO response-slot address/completion metadata. Release read protection the cycle after last lane response acceptance, not after later response FIFO consumption. Same-cycle same-address requests use32-bit wrap-safe transaction age; older transaction first, same transaction read before write. Existing Input transaction tags increment monotonically. Expose selected physical read's logical transaction tag from adapter; write tag is already on acc_if. No common improve compute pipeline changes.

## Arbitration

Only address-safe requests participate. Implement naive-specific per-bank PSUM read/write priority using existing request/response buffer stages. Where both classes contend, prefer read until R read grants have handshaken with a write waiting, then prefer a write. Count accepted lane requests only; reset count on write grant or absence of waiting write, hold on stalls. Preserve ordinary LMEM/DMA relative ordering. The quota is relative PSUM service, not a hard cycle deadline under downstream stalls. Do not retract a stalled selected request or partially issued transaction.

Use a compile-time naive scheduler enable and configurable R. Disabled naive and all improve behavior remain as before. Add only naive-specific internal sidebands; no software command/layout changes. Prove improve preprocessed RTL/parameters/connections are unchanged; do not synthesize for cost claims. Snapshot baseline RTL is under snapshot/rtl.

## Verification and deliverables

Run fpint_gemm_ffn_hw_naive M4/M256 K=N512 for all four R values, FSDB/perf/latency observer enabled. Also run same-address-reuse checks M4/M16 K64 N16; determine actual hazard coverage from counters/FSDB rather than claiming coverage from dimensions alone. Validate ownership, partial transaction stability, physical commit lifetime, exact RAW/WAW/WAR rules during these VCS runs, no separate fine reset tests. Baseline short cases may be captured before changes if needed.

Compare GEMM cycles, Input acceptance, PSUM-only waits, exact hazard waits, write stalls, result-credit exhaustion, table-full stalls, and quota behavior. Preserve waveform annotations with cycles and RTL lines. Select/update config only after simulations stop and source hashes are checked; verify selected profile matches tested flags. Put detailed validation and sweep in a separate report; fpint_gemm_latency.md contains only final cycle comparisons. Maintain STATUS.yaml. No commit unless user subsequently asks.
