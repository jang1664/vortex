# MXU16 DMA launch elastic buffer

## Goal

Break the routed combinational path from GEMM completion/dependency logic to
the TMEM DMA datapath by adding one registered ready/valid stage at the GEMM
controller to TMEM DMA controller command boundary. Measure the functional
cycle impact for the M=4, K=256, N=256 fpint GEMM case in xrt-vcs-sim.

## Scope

- Modify `hw/rtl/core/gemm/VX_gemm_node.sv`.
- Buffer the normal DMA command launch bundle: valid/start, command, and tag.
- Preserve the separate DMA prepare/lookahead interface.
- Preserve ready/valid backpressure and DMA inflight tag accounting.
- Run `fpint_gemm_ffn_hw -m 4 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1` with the
  `improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem` configuration.

## Design decisions

- Use the repository's `VX_elastic_buffer` primitive with one registered entry.
- Place it in `VX_gemm_node` where `gemm_ctrl_if.dma_ctrl` is currently wired
  directly to `gemm_dma_ctrl_if`.
- Feed buffer input readiness back as `gemm_ctrl_if.dma_flag.cmd_ready` so the
  GEMM child queue pops only when the complete command bundle is captured.
- Feed TMEM DMA `cmd_ready` to the buffer output handshake.
- Drive both downstream `start` and `cmd_valid` from the registered valid.

## Constraints and assumptions

- One cycle of DMA command latency is expected; steady-state command throughput
  must remain one command per cycle when downstream is ready.
- `cmd` and `cmd_tag` must be registered together with valid.
- Existing untracked task directories and unrelated worktree changes are not
  modified.
- Baseline for the exact case is functional PASS with `PERF cycles=7524`.

## Final agreed spec

Confirmed from the user's explicit request on 2026-09-05.
