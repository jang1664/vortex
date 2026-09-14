# MXU16 merge: U2 unit verification

Completed: 2026-09-06 22:39 KST. U2 verification gate passed for the supported configurations below.

## Environment and scope

- Configured build: `build/experiment-archive/build_mxu16_merge_u2_verify`.
- Configure command: `../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`.
- Simulator: VCS W-2024.09-SP1; host compilers `/usr/bin/gcc` and `/usr/bin/g++`.
- Every run sources a repository configuration before invoking `tools/verify_rtl.py unittest --sim vcs`.
- Compile-time parameters are exported environment variables. The runner's `--params` only affects its run command, not its initial compilation.
- `MAKEFLAGS=-B` prevents stale executable reuse when test parameters change.
- Raw logs are under `build/experiment-archive/build_mxu16_merge_u2_verify/verification-results/`; generated artifacts are not committed.
- This document records U2 only. It does not establish U3/U4 transport compatibility, full-system performance, synthesis, or physical timing.

## Queue characterization and extensions

Primary sourced configuration: `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh` (MXU32/W4, SLR enabled).

| Test | Result | Evidence |
| --- | --- | --- |
| Inherited combined queue TB, unchanged, 30 cases | PASS | Deterministic runner returned `pass` before test extensions |
| Extended combined queue TB, 46 cases | PASS | `verification-results/queue-positive.log` |

The inherited cases cover command depths 1/2/4, FF and registered-read RAM, ring and non-ring allocation, held request identity, out-of-order responses, writer fence, descriptor/slot turnover, sequence wrap, elastic backpressure, and reset with buffered data. Legacy FF/RAM registered-sink cycle comparison remains enabled at 512 and 1024 bits.

The extension adds:

- Twelve 512-bit elastic cases matching the inherited twelve 256-bit elastic cases, all with eight response slots.
- Four early-release RAM cases: DATAW 256/512, response bypass disabled/enabled, eight response slots, command depth two.
- A nine-beat directed transaction that reuses and overwrites the physical RAM slot of the held first beat while the writer fence is closed. Stage capture/slot reuse must not cause a physical write or command completion; the held payload must remain correct after the overwrite.
- Final physical-write completion checks after releasing that fence. The two bypass-enabled cases each exercised eight direct response-to-stage captures.
- Distinct deterministic patterns across every 32-bit lane rather than zero-extending a low 32-bit word.

The Weight wrapper's existing overlap test explicitly assumes non-SLR, next-cycle slot recycle. Its expectations are not modified. The generic queue early-release tests above provide direct U2 evidence for the SLR Weight queue mode; actual SLR system behavior still requires the later blackbox gate.

## Parameter-negative tests

The dedicated `tb_VX_gemm_stream_dma_queue_invalid` top must fail in the DUT's time-zero parameter check. The runner is expected to report `sim_fail`; acceptance additionally requires the exact intended DUT diagnostic and rejects `INVALID_CONFIGURATION_WAS_ACCEPTED`.

| Mode | Illegal configuration | Expected diagnostic | Result |
| --- | --- | --- | --- |
| 1 | Early release plus sink elasticity | `early slot release and sink elasticity cannot be combined` | PASS, intended rejection at time zero |
| 2 | Response bypass without early release | `response-stage bypass requires early RAM-slot release` | PASS, intended rejection at time zero |
| 3 | Early release/bypass with FF response storage | `early slot release requires registered RAM and ring ordering` | PASS, intended rejection at time zero |
| 4 | Early release/bypass with non-ring allocation | `early slot release requires registered RAM and ring ordering` | PASS, intended rejection at time zero |

## U2 integration matrix

- Weight overlap: 32/64-byte RAM modes with SLR define removed from the sourced primary config, preserving the inherited wrapper contract.
- Scale and zero-point overlap: 32/64-byte, RAM, sink elasticity disabled/enabled.
- HBM write-pair elasticity: EB disabled/enabled and padding disabled/enabled, including pending-write reset and physical drain.
- Actual TMEM subsystem: write-ACK filtering, tag reuse, direct64/paired32 geometry and high physical rows; selected-bank DMA4/TMEM8 routing and stalled response lock.
- Controller directed scoreboard tests: baseline and incoming C2 flags; backend DMA controller completion/prepare regression.

| Test | Variants | Result | Raw log prefix |
| --- | --- | --- | --- |
| Weight overlap | RAM, 32/64-byte bus, non-SLR | 2 PASS | `weight-` |
| Scale/zero-point overlap | RAM, 32/64-byte bus, elastic 0/1, scale/zero-point | 8 PASS | `qparam-` |
| DMA write pair | EB 0/1, padding 0/1 | 4 PASS | `write-pair-` |
| GEMM controller directed | MXU16, C2 0/1, `+SCHED_DIRECTED` | 2 PASS | `controller-cuts-` |
| Backend TMEM DMA controller | Primary MXU32/W4 config, pending depth four | PASS | `tmem-dma-controller` |
| Selected-bank subsystem | DMA4/TMEM8, 64-byte physical banks, NDEBUG 0/1 | 2 PASS | `bank-select-` |
| Paired32 ACK filter | Two 64-KiB banks, NDEBUG 0/1, rows 1023/2047 | 2 PASS | `ack-filter-32-` |
| Initial direct64 ACK fixture | One physical bank, NDEBUG 0/1 | 2 compile errors; unsuitable fixture geometry | `ack-filter-64-` |
| Production direct64 ACK filter | Eight 64-KiB banks/eight DMA channels, NDEBUG 0/1 | 2 PASS | `ack-filter-64-banks8-` |

The initial direct64 fixture used a single physical bank. Compilation rejected zero-width `BANK_SEL_BITS` casts in `VX_tmem_switch.sv` and `VX_tmem_wide_read_switch.sv`. No RTL was changed to accommodate this artificial geometry. The parent implementation agent approved rerunning the fixture with the primary eight-bank/eight-channel geometry, and both debug-tag variants passed. The failed JSON records are retained and are not counted as passes. The copied `ack-filter-64-0.log` and `ack-filter-64-1.log` files came from the preceding successful paired32 simulation because compilation never started a new simulation; **only the JSON error report is evidence for these two failures**.

All completed positive logs were additionally scanned for plain VCS `Error:`, `Fatal:`, assertion-failure text and `TEST FAILED`, since a success banner alone can hide nonfatal assertion messages. Only the four intentionally negative queue logs matched the strict scan.

In total, the archived reports contain 24 positive runner passes, four expected negative rejections, and two retained unsupported-fixture compilation failures. The initial unchanged 30-case characterization additionally passed before extending the queue test. No RTL fixes were needed during U2 verification.

## Reproduction notes

Run from the repository root after configuring the build above:

```bash
source configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh
export CC=/usr/bin/gcc CXX=/usr/bin/g++ MAKEFLAGS=-B
python3 tools/verify_rtl.py unittest \
  --path build/experiment-archive/build_mxu16_merge_u2_verify/hw/unittest/gemm_stream_dma_queue \
  --sim vcs --timeout 300
```

For negative queue tests export `TOP_MODULE=tb_VX_gemm_stream_dma_queue_invalid` and `NEGATIVE_MODE=1`, `2`, `3`, or `4` before the same runner invocation. Unset those two variables before positive tests.

For 32-byte wrappers source `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`; for 64-byte wrappers source the primary config above and remove the exact `-DGEMM_SLR_PIPELINE` token from `CONFIGS` (defining it as zero does not disable an `ifdef`). Set `TB_RESPONSE_DATA_RAM=1`, `TB_BUS_BYTES=32|64`; qparam tests additionally use `TB_SINK_ELASTIC=0|1` and `TEST_ZP=0|1`.

The paired32 ACK test uses `TMEM_BYTES=32 TMEM_BANKS=2 TMEM_BANK_SIZE=65536`; production direct64 uses `TMEM_BYTES=64 TMEM_BANKS=8 TMEM_BANK_SIZE=65536`. Both use `NDEBUG=0|1`. The selected-bank TB fixes DMA4/TMEM8 internally. DMA write-pair tests use `EB=0|1 PAD=0|1`; its Makefile deliberately fixes module-level defines rather than consuming all primary `CONFIGS`.

Controller tests source the MXU16 config, replace its existing `GEMM_TIMING_CUTS=1` token with `GEMM_TIMING_CUTS=0|1`, and pass `--extra-sim-args '+SCHED_DIRECTED'`. The backend controller test uses the primary config without additional parameters.
