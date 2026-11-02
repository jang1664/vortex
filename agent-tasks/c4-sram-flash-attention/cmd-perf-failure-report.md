# CMD_PERF resident verification failure

Status: FAIL, process exit 2. No RTL edits or assertion suppression were made.

## Reproduction

Configured build: `build_c4_sram_perf`, XLEN64, tooldir `/opt/vortex`.

```bash
cd build_c4_sram_perf
source ../configs/c4_sram_fusion.sh
export PATH="/usr/bin:$PATH" CC=/usr/bin/gcc CXX=/usr/bin/g++ MAKEFLAGS='DEBUG=3'
timeout --signal=TERM --kill-after=20s 1800s ci/run_black.sh xrt-vcs-sim \
  --app flash_attn --args '-r -f -m 4 -n 256' \
  --configs-extra '-DDISABLE_FSDB -DDBG_TRACE_AFU -DDBG_TRACE_MEM -DDBG_TRACE_CACHE -DDBG_TRACE_GEMM -DDBG_TRACE_GEMM_CMD_PERF'
```

The wrapper omits `--debug` to avoid automatically enabling PIPELINE trace. `MAKEFLAGS=DEBUG=3` keeps NDEBUG absent, retaining assertions and UUIDs. The Xilinx-IP VLOGAN branch uses the default DEBUG_LEVEL=3 in VX_config.vh. Both kernel.elf and kernel.vxbin were byte-identical to the previous passing FP32 M4/N256 production case.

## Failure

At 217515000ps, `VX_gemm_ctrl.sv:2148` fails `!dbg_active_uid_valid[child]`:

> cluster0-socket0-core0-gemm: non-DMA child 0 has two active UIDs

The trace at 217505000ps shows child0 work_seq1 dispatch=1, done=0. The simulation-only lifecycle ledger stores one active UID per non-DMA child. The production controller has per-child inflight queues. This mismatch is a suspected instrumentation defect; the implementation agent must verify the intended completion/issue ordering and preserve ledger completeness checks. No numerical completion was reached.

## Preserved evidence

Paths below are relative to `agent-tasks/c4-sram-flash-attention/logs/`:

- `blackbox_perf_fp32_m4_n256.log`: full wrapper/build/app log, terminal BLACKBOX_EXIT=2.
- `simv_perf_fp32_m4_n256_fail.log`: complete failed RTL trace and fatal.
- `selective_trace_source_provenance.json`: source and failed binary hashes.
- `perf_failed_simv_config.stamp`: exact simulator configuration stamp.

Process session 87707 has terminated. No verification process remains live.

## Corrected-test request

After instrumentation is repaired, rerun this unchanged workload with CMD_PERF enabled and all assertions retained. Require normal app PASSED plus exit0, complete command-ledger summaries, and unchanged numerical/DMA traffic audits. Extract compute_pipeline_cycles separately from the software GEMM wait interval; compute activity can overlap memory commands.

Remaining matrix is held pending root dispatch: resident FP16 M8/N128 and M128/N128; FP32 M1/N257 tail; extreme-logits, alpha-underflow, fp32-state numerical stresses; FP16 pv-rounding diagnostic export; FP32 qk-overflow diagnostic export. Diagnostic export cases are excluded from production traffic claims.

`build_c4_sram_matrix` was configured as a possible isolated matrix build, but no simulator compile or run was launched there.
