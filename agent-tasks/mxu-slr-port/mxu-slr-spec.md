# MXU-only SLR port

Status: confirmed by the user's implementation request on 2026-09-29.

## Scope

Port only the MXU transport from feat/gemv (18626179d, 542443870 and latest
naive weight TX preservation) into the current VX_gemm_unit. Preserve DMA,
TMEM, the selectable naive ACC restoration, and its actual-write drain logic.
Do not import compute-core/metadata/ownership refactors. Do not commit work.

## RTL contract

- GEMM_SLR_PIPELINE presence enables two unconditional TX/RX registers for
  activation/control, weight/control, and result/valid. Undefined keeps the
  original behavior. Initially require MXU_ROW=MXU_COL=MXU_COL_TILE=32.
- Increase MXU flight, correction, and exponent delays by four cycles; retain
  the existing one-cycle local block-index pipe and preserve it separately.
- Keep direct TX Q to RX D connectivity, USER_SLL_REG, SHREG_EXTRACT=NO,
  selective DONT_TOUCH, and dedicated reset mapping. Clear validity on reset.
- Preserve current weight interlocks and WLOAD_AT_ONCE buffering. Keep public
  interfaces unchanged. Check installation/use order and alignment in simulation.

## Floorplan contract

GEMM_MXU_SLR_FLOORPLAN=1 is opt-in, defaults to zero, and requires the RTL
macro. SLR2 owns u_mxu and input_rx/weight_rx/output_tx. SLR1 owns input_tx,
weight_tx/output_rx and the preserved local block-index bank. Other logic
remains unconstrained; SLR2 is not exclusively reserved. Check hierarchy,
direct FF connectivity, and ownership. Post-place checks must work even when
congestion fail-fast is disabled. Test hooks with Tcl fixtures; no PnR now.

## Verification

Use run-bb-common and ci/run_black.sh xrt-vcs-sim from configured build dirs.
Configure with --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex;
host compilers are /usr/bin/gcc and /usr/bin/g++. Reuse compatible Xilinx
libraries/IP but not simulator binaries across configurations.

Baseline: fixed 73664e653 source, M16/K256/N256/q32/t0/d0/r1 for naive ACC
ON, naive ACC OFF, and improve. Configs are th32_c1_naive_m32_tcol32.sh
(OFF removes GEMM_NAIVE_USE_ACC_MEM only) and th32_c1_improve_m32_tcol32.sh.
Apps are fpint_gemm_ffn_hw_naive and fpint_gemm_ffn_hw respectively.

Final: each backend with SLR OFF/ON, seven cases per variant (42 total):
- M1, M16, M256 / K=N=256 / q32 / t0 / d0 / r1.
- M16 / K=N=256 / q32 / (t,d)=(1,0),(0,1),(1,1) / r1.
- M33 / K=N=256 / q32 / t0 / d0 / r2.

Directed VCS tests cover reset flush, bubbles/consecutive inputs, first use
after weight installation, bank alternation, WLOAD_AT_ONCE ON/OFF, correction
and exponent alignment, and OFF/ON equivalence with expected added latency.
Start with 300-second run timeout; retry demonstrably progressing runs at
1800 seconds. Retain configs, source hashes, commands, logs and reports.
PASS requires exit zero, PASSED, no assertion/fatal, unchanged numerical
tolerances and preserved ACC copy/STORE drain checks. Reproduce OFF failures
on baseline and distinguish existing bugs from regressions; do not hide failures.

## User-authorized QROW reference correction

The user subsequently requested fixing the preexisting QROW host reference
and rerunning tests, superseding its temporary deferral. Both hardware GEMM
host apps must round activation times scale to FP16 RNE before multiplying
by (weight - zero-point), matching the RTL input scaler. Preserve QCOL
arithmetic and the existing 1% tolerance. Rerun QROW with both weight layouts
and a QCOL control for all three backends with SLR OFF/ON (18 cases); retain
the original 42-case results as evidence of the pre-correction behavior.
