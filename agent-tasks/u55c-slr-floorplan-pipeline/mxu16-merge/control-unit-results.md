# U3 Common DMA Transport Unit Verification

Recorded: 2026-09-06 22:42 KST. Result: PASS with GEMM tracing disabled and enabled.

## Environment and command

- Dedicated build: `build_mxu16_merge_u3_verify`.
- Configured using `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex` before testing.
- Sourced `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`: TH16, MXU32, WLOAD_NUM=4, DMA8, SLR enabled at the top-level config.
- VCS: `/tool/Program/synopsys/vcs/W-2024.09-SP1/amd64/bin/vcs`.
- Host compiler selection: `CC=/usr/bin/gcc`, `CXX=/usr/bin/g++`.
- Unit instances explicitly select local launch depth 1, local launch depth 2, and SLR launch depth 2, independently of the config's presence-based SLR macro.

From the configured build directory:

```sh
source ../configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh
export CC=/usr/bin/gcc CXX=/usr/bin/g++
python3 ../tools/verify_rtl.py unittest \
    --path hw/unittest/gemm_dma_slr_bridge --sim vcs --timeout 120

# Repeat with trace statements compiled and actually emitted.
CONFIGS+=" -DDBG_TRACE_GEMM -DDEBUG_LEVEL=1"
export CONFIGS
python3 ../tools/verify_rtl.py unittest \
    --path hw/unittest/gemm_dma_slr_bridge --sim vcs --timeout 120
```

## Results and covered contracts

| Instance | Trace off | Trace on | Empty forward latency | Completion latency |
|---|---|---|---|---|
| Local, launch depth 1 | PASS | PASS | 1 cycle | 0 cycles |
| Local, launch depth 2 | PASS | PASS | 1 cycle | 0 cycles |
| SLR, launch depth 2 | PASS | PASS | 3 cycles | 2 cycles |

These are assertions on observed handshakes, not latency estimates. Local completion is also checked combinationally before the next clock edge. Both executions finished at simulation time 1,655,000 ps with the aggregate `TEST PASSED: common DMA transport local1/local2/SLR2` marker.

The scoreboard checks full command payload and tag identity, PREPARE/release ordering behind older commands, independent backend command/PREPARE stalls, all-tag outstanding overlap, reverse-order completion tags and store flags, one-completion-per-cycle bursts, sync backpressure and payload order, completed-tag reuse, reset with queued commands and unreleased PREPARE ownership, a subsequent clean invocation, and drain/idle conservation. RTL runtime assertions remain enabled.

The trace-enabled simulation emitted 72 `GEMM_DMA_TRANSPORT` records and 115 `GEMM_TIMING_STREAM_LAUNCH` records. Full-launch stalls occurred in all three instances, including 9 SLR full-stall records. No VCS `Warning-`, `Error-`, or `Fatal:` entries were found in the successful compile/simulation logs.

This focused test uses a controlled backend interface, not the real DMA scheduler. It does not independently establish scheduler chaining behavior, blackbox performance, TMEM data correctness, or synthesis timing. Unsupported-parameter negative tests were not added or run in this bounded verification task.

## Initial failure and test-only fix

The first deterministic run returned `compile_error`: `VX_pipe_register.sv:34` could not bind `VX_shift_register`. The new common launch buffer introduced this source-list dependency. Added `hw/rtl/libs/VX_shift_register.sv` to `hw/unittest/gemm_dma_slr_bridge/Makefile` and refreshed the configured build's copy. Both subsequent runs passed. No RTL or test assertions were changed by the verification worker.

The verification-agent document references `harness/rules/testbench.md` and `harness/skills/{run-test,add-test-case}/SKILL.md`; these files are absent in this checkout. Testing followed the current repository configuration instructions and `tools/verify_rtl.py` instead.

## Evidence and source fingerprint

Retained generated logs, relative to the repository:

- `build_mxu16_merge_u3_verify/hw/unittest/gemm_dma_slr_bridge/logs/compile_trace_off.log`
- `build_mxu16_merge_u3_verify/hw/unittest/gemm_dma_slr_bridge/logs/sim_trace_off.log`
- `build_mxu16_merge_u3_verify/hw/unittest/gemm_dma_slr_bridge/logs/compile_trace_on.log`
- `build_mxu16_merge_u3_verify/hw/unittest/gemm_dma_slr_bridge/logs/sim_trace_on.log`

SHA-256 after both successful runs:

```text
29e0e0d6152dd2e9611cf19a6f3517deadefb96d9bc4896e0df8986e285e584d  hw/unittest/gemm_dma_slr_bridge/Makefile
263426a838eaa3308465001a4c148f1bfcf94a04ba2c9546645adc0be6fca8a6  hw/unittest/gemm_dma_slr_bridge/tb_gemm_dma_slr_bridge.sv
f73e592ce284f7b5ddfa9d73fc7727423a6c417a34ac96da2826aef1dff55a31  hw/rtl/core/gemm/VX_gemm_dma_transport.sv
201955fcf1a70aa88e2a35b28408447bd3de7004e48ab3394f0bde8a26f2653e  hw/rtl/libs/VX_stream_transport.sv
eb3923ed860b0ad62e816492bef86e1e5a650f7de8a589ee5a48c6e27f819255  hw/rtl/libs/VX_slr_stream.sv
```

No blackbox run, synthesis, or Git mutation was performed by this verification worker.
