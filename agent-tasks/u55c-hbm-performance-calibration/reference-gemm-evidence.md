# Historical GEMM scaler diagnosis

## Guarded application result (2026-09-08 22:26 KST)

The failure described below is resolved for the tested cases. A fresh stage
`build_hbm_reference/sim/xrtsim_vcs/archived-document-guarded-mul` contains
no diagnostic observer binds. It uses both approved repo RAM sources,
archived non-RAM RTL/headers, FMA and multiplier boundary guards, and
`fma_f32mul_module_xprop.cfg`. Only `xil_fma_lowL` and
`xil_f32mul_latency1` vendor subtrees are excluded from tmerge.

`REFERENCE_FMA_GUARD=1 REFERENCE_F32MUL_GUARD=1` explicitly selects this
temporary build mode. Original Makefiles and wrapper remain unchanged.
`audit_reference_compile.py --repo-ram --guarded-fma --guarded-f32mul`
reports 217 archive, two repo RAM, nine harness, zero unexpected sources.
Audit: `build_hbm_reference/sim/xrtsim_vcs/guarded_mul_compile_audit.json`.

Validation:

- Binary FP boundary guard: 16 directed cases pass, covering normal, idle,
  independent A/B validity, stalls, unknown valid/ready/data and result.
- Same archived multiplier with guards: known captured operands pass;
  intentionally unknown A is rejected by `REFERENCE_BINARY_FP_A_DATA`.
- GEMM 16x16x16, QBLK32: two passes, both 7344 cycles / 6253 instructions.
- GEMM 16x16x64, QBLK32: passes, 7419 cycles / 6259 instructions.
- No boundary-guard fatal in these application simulator logs.

Host/simulator log pairs are under `build_hbm_reference_document`:
`archived_guarded_mul_gemm16{,_simv}.log`,
`archived_guarded_mul_gemm16_repeat{,_simv}.log`, and
`archived_guarded_mul_gemm64{,_simv}.log`.
These are correctness results, not measured agreement with hardware.
Detailed Xprop instrumentation, remaining IP provenance, matched baseline,
hardware repeats and held-out performance cases remain open.

SHA-256 at this validation point:

- simv: `f059b5e84f413d2cd75ca424297b83cc7de84a5c1a863afb966d23d1f2516966`
- bridge: `71f8389c499be4ecca7c2148808ef43d29ebb0b991cc4a4183b6a49529b94c15`
- manifest: `0b343e4f8480682756655b43b6044d73c2734442d66379f3d63d13567fcd6acd`
- host app: `8f98e5af6f3680af703f2452847beaac7444341947020f27929aa26938273368`
- kernel.vxbin: `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`

## Status (2026-09-08 22:21 KST)

Archived reference GEMM16/QBLK32 still fails correctness; its 7344 cycles
must not enter hardware performance comparisons. Repo DP/SP RAM selection
and the FMA-only guarded exclusion are active. No archived DUT RTL changed.

## First observed corruption

Non-driving `reference_gemm_observer.sv` follows the actually elaborated
`VX_gemm_unit_v2.u_compute_core` path. The first observer attempt targeted
unused `VX_gemm_unit` and failed elaboration; the corrected build passed.

Lane zero:

- At 66615000 ps, integer-to-FP32 output is `42315400`; the output scaler
  accepts operands `42315400` and `3f800000` (multiplication by one).
- At 66625000 ps, the scaler's valid result is `42xxxxxx`.
- At 66845000 ps, output conversion receives `42xxxxxx` and emits `7c00`
  (positive infinity). Thus host Inf is not evidence of numeric overflow.

Host log: `build_hbm_reference_document/archived_gemm_stage_trace.log`.
Preserved simulator log:
`build_hbm_reference_document/archived_gemm_stage_trace_simv.log`.
The initial observer-free failure is preserved separately in
`archived_guarded_gemm16{,_simv}.log` in the same directory.

## Isolated vendor-IP experiment

`tb_reference_f32mul.sv` instantiates the same archived
`xil_f32mul_latency1` VHDL IP, with reset, known inputs, both ready checks,
and exactly one expected output. No HBM, RAM, core, or GEMM control exists
in this test. Testbench drivers change one ns after a falling edge.

Both builds use the same archived VHDL libraries in
`build_hbm_reference/sim/xrtsim_vcs/archived-document-guarded-fma`:

- `f32mul_tmerge.log`: result `42xxxxxx`, explicit mismatch fatal.
- `f32mul_scoped.log`: result `42315400`, `REFERENCE_F32MUL_PASS`.

Only Xprop configuration differs: `-xprop=tmerge` versus
`f32mul_probe_xprop.cfg`, excluding the `xil_f32mul_latency1` tree while
enabling SV tmerge. VCS returned zero even for the fatal case, so pass/fail
is determined from assertion and PASS markers, not exit status alone.

This isolates an IP/Xprop interaction for the captured transaction. It does
not prove all GEMM failures are resolved or all vendor IPs need exclusions.

## Next gate

Before enabling this exclusion in application reference builds, add and
negative-test boundary guards for accepted operands, handshake controls and
valid results. Keep all other DUT X checks active. Then rebuild a fresh
observer-free reference stage and rerun GEMM correctness and determinism.
The current guarded-FMA stage now includes diagnostic observers and must
not be presented as the final observer-free acceptance build.
