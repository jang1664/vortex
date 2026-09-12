# Completion audit

Status: Complete (2026-09-10 14:52 KST). All 18 selected numerical runs passed
with exit 0; final cycle comparisons and production focused checks are verified.

| Requirement | Evidence | State |
| --- | --- | --- |
| Reuse NUM_BANKS_OUT as intermediate K; H is NUM_HBM_PORTS | Production adapter dimensions and top override/default expression | Complete |
| P-to-K followed by restricted endpoints g+s*K | Request crossbar and per-group generated endpoint loops; no full cache AXI demux remains | Complete |
| Preserve HBM mapping independently of K and high address bits | Reused VX_mem_remap; arithmetic scoreboard at K1/2/4/8 and high addresses | Complete |
| Preserve independent AW/W handshakes and output cuts | Buffered request plus VX_axi_write_ack; nine-case protocol tests; top cuts retained | Complete |
| Response requester/tag identity without reorder buffer | RID requester bits, per-input index buffer, group response arbitration; out-of-order and tag-reuse tests | Complete |
| Busy/drain includes accepted requests through read retirement or B | Occupancy tracker and top cache_drain gate; delayed completion/drain tests | Complete |
| Reject unsupported geometry | Positive power-of-two/divisibility/64-byte/physical-width checks; valid control plus five negative probes | Complete |
| Automatic default K2 on both actual profiles | No-override improve vecadd and naive small PASS; simv topology P2/K2/H8/64B | Complete |
| Sustained 128B/cycle requests, responses and writes at K2 | Production unittest iteration 2: 128 handshakes per 64-cycle window; K1: 64 | Complete |
| Focused protocol, mapping, bypass, tags and contention tests | Production iteration 2 verify_rtl.py PASS; nine parameter cases | Complete |
| Preserve DMA ownership and ID extensions | Existing DMA demux/mux and per-HBM cuts retained; improve and naive FPINT small integration PASS | Complete; all six K2 numerical gates pass |
| Six required numerical cases, baseline/K1/K2, correct apps/configs | Explicit cycle-manifest and archived wrapper/simv logs | Complete; all 18 selected runs validated by strict parser |
| FPINT M256/K256/N256 compares 65536 outputs | Existing app output-comparison loops and logged shape; improve large PASS at all three variants | Complete; both apps and all variants PASS with full comparison enabled |
| FPINT perf3 node and total cycles; vecadd total cycles | Counter wiring inspected; strict parser validates selected run logs and matching raw work count | Complete; all four FPINT shape/path combinations include node and total cycles |
| Matched memory model/settings within comparisons | Baseline/K1/K2 profile manifests match after removing NUM_BANKS_OUT and dependent hash; per-run config and command capture | Complete; final large manifests match for both profiles |
| Report absolute and percentage deltas against baseline and K1 | compare-cycles.py and results.md | Complete; ten metric rows with both reference deltas in results.md |
| Preserve user work | Existing ci/fpga_bin_alias_map.yaml change untouched | Complete |
| No synthesis, place-and-route or hardware cost reporting | Execution commands are configured VCS builds/tests and read-only waveform analysis; no synthesis target invoked | Complete |

The two naive prerequisite changes are documented in baseline-prerequisites.patch
and applied equally across naive variants. The final parameter-validation-only
changes do not alter behavior at the tested valid target geometry; production
focused tests and specific invalid-width checks were rerun afterward.

Final evidence inspection:

- `compare-cycles.py cycle-manifest.json` completed successfully against all
  18 selected run directories, checking numerical PASS, exit 0, archived simv
  logs without fatal errors, cycle fields and matching raw jobs counts.
- Both FPINT apps' comparison loops cover every logical M*N element; all large
  runs use M=K=N=256, REPS=1 and full result verification (65536 outputs).
- Final baseline naive large retry: 106967 total / 97762 node cycles. K1:
  97376 / 88452. K2: 97375 / 88444. All three have exit 0.
- Baseline/K1/K2 large memory manifests match within improve and naive profiles
  after excluding NUM_BANKS_OUT and its dependent hash. All 335 frozen RTL
  files still match the pre-change hash manifest; adjacent draft copies match
  production adapter/top files.
- Production focused report.json is pass; sim.log contains the final TEST PASSED
  marker and sustained 128/64-cycle handshakes at K2, 64/64 at K1. All five
  invalid-geometry probes and the valid control passed their expected checks.
- Session 5587 terminated with exit 0. No task simulation remains outstanding.
  The failed collector attempt remains excluded; the successful immutable-runner
  retry is explicitly selected in cycle-manifest.json.
