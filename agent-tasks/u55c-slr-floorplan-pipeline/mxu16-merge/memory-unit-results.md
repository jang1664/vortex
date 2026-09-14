# MXU16 merge: U4 memory transport verification

Completed: 2026-09-06 22:53 KST. The supported U4 unit configurations below pass.

## Environment

- Fresh configured build: `build/experiment-archive/build_mxu16_merge_u4_verify`.
- Configuration command: `../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`.
- VCS W-2024.09-SP1; host compilers `/usr/bin/gcc` and `/usr/bin/g++`.
- Tests invoked through `tools/verify_rtl.py unittest --sim vcs --timeout 300`, with `MAKEFLAGS=-B` to prevent stale executables when compile-time parameters change.
- Each invocation sources `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh` (primary MXU32/W4), except the supported paired32 subsystem fixture, which sources the MXU16/W4 `tcol16` configuration.
- Parameter values are exported before the runner. Its `--params` option is not used to configure compilation because it applies only to the run command.
- Raw JSON reports, copied simulation/compile logs, source hashes and result hashes are retained in `build/experiment-archive/build_mxu16_merge_u4_verify/verification-results/`.
- No RTL was changed by verification. No blackbox test, synthesis, OOC or PnR was run in this unit-verification task.

The verification-agent references `harness/rules/testbench.md`, `harness/skills/run-test/SKILL.md` and `harness/skills/add-test-case/SKILL.md` are absent in this checkout. Available project-context/RTL verification instructions, existing unit Makefiles and the deterministic runner were used instead; the missing references were reported to the parent agent.

## Results

| Test | Variants | Result | Evidence prefix |
| --- | --- | --- | --- |
| Shared memory bus transport | 32/64 B, local/SLR, request launch depth 0/2: eight concurrent cases | PASS | `slr-mem-bus` |
| Existing SLR stream suite, unchanged | 32/64 B; 4,000 ordered transactions, backpressure, sustained rate and drain | PASS | `slr-stream` |
| Initial legacy reservation characterization | Local, 64 B, minimal UUID configuration; handshake-accounting replacement only | PASS | `reservation-initial` |
| Extended read-request reservation | 32/64 B, local/SLR: four separate runs, NDEBUG=0 | 4 PASS | `reservation-<bytes>-slr<mode>` |
| Actual subsystem direct64 write-ACK filtering | Eight 64-KiB physical TMEM arrays/eight DMA channels, local/SLR, C2 0/1, NDEBUG=0 | 4 PASS | `ack-64-slr<mode>-cuts<mode>` |
| Actual subsystem paired32 write-ACK filtering | Two 64-KiB physical TMEM arrays/one paired DMA channel, MXU16, local/SLR, C2 0/1, NDEBUG=0 | 4 PASS | `ack-32-mxu16-slr<mode>-cuts<mode>` |

There are 15 successful runner reports (including the initial characterization). Four unsuitable fixture/configuration attempts are separately retained as failures, not counted as passes. All successful simulation logs were additionally scanned for plain VCS `Error:`, `Fatal:`, `Error-`, `TEST FAILED` and assertion-failure text; none matched.

## Coverage and test changes

### Shared memory bus

The parent-provided eight-case test checks full request data/tags/sidebands, response reordering and backpressure, reset with epoch-distinct request data, request drain, and sustained one-beat-per-cycle throughput. Empty-path/steady-state request latency is checked as 0/1 cycles locally and 2/3 cycles with SLR transport for launch depth 0/2 respectively. It asserts that `request_idle` cannot indicate drain while accepted writes remain uncommitted at the physical downstream request interface.

### Read-request reservation

The old test directly inspected removed `dut.occupancy_r`. It now computes occupancy from accepted requests minus issued requests, independent of the implementation hierarchy. The local directed checks are retained: one-cycle non-fallthrough request latency, two-entry capacity, stable stalled head metadata, no same-cycle full-drain credit bypass, recovery to one enqueue/dequeue per cycle, final drain and direct response backpressure.

The test adds parameterized 32/64-byte and local/SLR runs. SLR cases verify six accepted-but-unissued request credits (EB2 plus four crossing credits), no credit at full occupancy, reset while an accepted request is outstanding, variable downstream backpressure, twelve ordered requests and complete drain. A reverse response with full UUID/tag and data must remain unchanged while the source stalls, then disappear after one consumption. Request constants and arbitration provenance are checked at every valid downstream cycle by the existing scoreboard.

`TAG_WIDTH` now includes `UP(UUID_WIDTH)` so debug-enabled tag widths are legal. The reservation Makefile adds the shared stream transport and its elastic/pipe primitive dependencies, exposes `TB_SLR_ENABLE`, `TB_DATA_SIZE` and `NDEBUG`, and defaults `NDEBUG` to zero. Both source and configure-generated Makefiles were refreshed before the extended matrix.

### Actual subsystem and coverage boundary

The existing ACK fixture exercises the actual subsystem's G2L-to-L2G transition, delayed write acknowledgements, reused read tags, high physical rows, stalled read responses and reset. All eight supported U4 runs use NDEBUG=0 and report UUID width 44. Paired32 exercises rows through 2047; direct64 uses the production eight-array geometry.

These tests do not issue output-local-DMA descriptors through the actual subsystem. The generic memory-bus test establishes the transport `request_idle`/physical-acceptance contract, but it does **not** independently prove the subsystem's `output_done_pending_q` descriptor-completion integration. That integration is covered separately by the later [full-node results](compute-unit-results.md) with physical enqueue/commit assertions active. No full-system performance or setup-timing claim follows from these unit results.

## Retained fixture failures

The first four paired32 attempts incorrectly combined the primary MXU32 configuration with the fixture's `WEIGHT_DATA_SIZE=32`. They stopped at time zero in `VX_lmem_dma_misal.sv` with `Weight queue requires complete logical Weight beats`: MXU32 needs a 64-byte logical Weight beat. The failure occurs for both SLR modes and both C2 settings; no RTL was changed or assertion disabled.

Those reports/logs remain under `ack-32-slr<mode>-cuts<mode>`. The corrected matrix sources the MXU16 configuration, whose logical Weight beat is 32 bytes, and all four runs pass under `ack-32-mxu16-slr<mode>-cuts<mode>`. These are fixture-configuration corrections, not suppressed functional failures.

## Reproduction

After configuring the build, from the repository root:

```bash
source configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh
export CC=/usr/bin/gcc CXX=/usr/bin/g++ MAKEFLAGS=-B
python3 tools/verify_rtl.py unittest \
  --path build/experiment-archive/build_mxu16_merge_u4_verify/hw/unittest/slr_mem_bus --sim vcs --timeout 300
```

Use the same command shape for `slr_stream` and `tmem_read_req_reservation`. For reservation runs export `TB_SLR_ENABLE=0|1 TB_DATA_SIZE=32|64 NDEBUG=0` before invoking the runner.

For the ACK fixture export `TMEM_BYTES=64 TMEM_BANKS=8 TMEM_BANK_SIZE=65536 NDEBUG=0`. Remove the exact `-DGEMM_SLR_PIPELINE` token for local mode; its presence-based `ifdef` is **not** disabled by assigning it zero. Append `-DGEMM_TIMING_CUTS=0|1` to `CONFIGS`. For paired32 first source `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`, remove its existing `GEMM_TIMING_CUTS=1` token, select the desired C2 value, add `-DGEMM_SLR_PIPELINE` only for SLR mode, and export `TMEM_BYTES=32 TMEM_BANKS=2`.

`source-sha256.txt` identifies final test and transport sources used for the extended matrix; the earlier reservation characterization predates that test extension. `result-sha256.txt` identifies the archived JSON/compile/simulation evidence. Generated logs and executables remain build artifacts, not commit content.
