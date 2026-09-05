# MXU 16x16 support verification results

## Final status

Functional implementation is complete for the compile-time GEMM_IMPROVE
MXU16 profile. The HBM-facing DMA path remains 64 bytes, while the local
I/W/S/Z/O paths and physical TMEM banks are 32 bytes. DMA channel `c` accesses
physical banks `2*c` and `2*c+1` through the dedicated pair adapter. No generic
associative reorder was added at this boundary; fixed-lane depth-two FIFOs join
matching response heads. Existing tag-indexed reorder remains only where the
local-DMA read queues already require it.

Performance, synthesis utilization, timing, and throughput sign-off are
intentionally deferred to a separate phase.

## Milestone A: required MXU16 matrix

All cases ran from `build_mxu16_accept_final4` with `xrt-vcs-sim`, reference
checking enabled, and one final RTL image:

`simv sha256 = 42b6e97232df507abb75f362536ad4593b2bb24d40348cd0fee0aa38417573fa`

| Case | Arguments | Result | Application log | Wrapper log |
| ---: | --- | --- | --- | --- |
| 1 | `-m 2 -n 32 -k 128 -q 32 -t 0 -d 0 -r 1` | PASS | `logs/mxu16_final4_case01_app.log` | `logs/mxu16_final4_case01_wrapper.log` |
| 2 | `-m 1 -n 16 -k 16 -q 32 -t 1 -d 0 -r 1` | PASS | `logs/mxu16_final4_case02_app.log` | `logs/mxu16_final4_case02_wrapper.log` |
| 3 | `-m 3 -n 17 -k 17 -q 32 -t 0 -d 1 -r 1` | PASS | `logs/mxu16_final4_case03_app.log` | `logs/mxu16_final4_case03_wrapper.log` |
| 4 | `-m 31 -n 48 -k 80 -q 32 -t 1 -d 1 -r 1` | PASS | `logs/mxu16_final4_case04_app.log` | `logs/mxu16_final4_case04_wrapper.log` |
| 5 | `-m 129 -n 129 -k 129 -q 32 -t 0 -d 0 -r 1` | PASS | `logs/mxu16_final4_case05_app.log` | `logs/mxu16_final4_case05_wrapper.log` |

The application logs identify `MXU_KT=16`, `MXU_NT=16`, the requested logical
shape, QDIR, and WTRANS, then print `PASSED`. The retained RTL traces have no
fatal, assertion-failure, timeout, completion-hang, or numerical-mismatch
marker. Large RTL traces were preserved outside the source tree under
`/tmp/vortex-mxu16-support-rtl-logs-final/`; the task directory retains the
small wrapper and application evidence.

## Milestone B: compatibility and extended correctness

Fixed seed `0x16` cases, on the same MXU16 image:

| Arguments | Result | Application log |
| --- | --- | --- |
| `-m 18 -n 78 -k 22 -q 32 -t 1 -d 0 -r 1` | PASS | `logs/mxu16_final4_random_seed16_case01_app.log` |
| `-m 90 -n 46 -k 182 -q 32 -t 1 -d 0 -r 1` | PASS | `logs/mxu16_final4_random_seed16_case02_app.log` |
| `-m 30 -n 84 -k 28 -q 32 -t 1 -d 0 -r 1` | PASS | `logs/mxu16_final4_random_seed16_case03_app.log` |
| `-m 71 -n 126 -k 28 -q 32 -t 0 -d 1 -r 1` | PASS | `logs/mxu16_final4_random_seed16_case04_app.log` |

The first case initially exposed a nonzero-start-channel DMA wrap bug. A
576-byte output slot starting on channel 4 wraps through channels 0..3; the
decoder now adds the missing 64-byte bank-local quotient carry to those
channels. The reduced `M=18,N=32,K=22` reproducer and the original case both
pass after the fix.

The functional stress case
`-m 192 -n 160 -k 256 -q 32 -t 1 -d 1 -r 1` also passes on the same image;
see `logs/mxu16_final4_stress_app.log`.

Current-source MXU32 compatibility was rebuilt after the common DMA decoder
change. Both cases passed one rebuilt image with
`simv sha256 = f3fa06eaece942d535ab3e37882ff461225bc0d1a5ae249bba31522d6982bcf1`:

| Arguments | Result | Application log |
| --- | --- | --- |
| `-m 2 -n 32 -k 128 -q 32 -t 0 -d 0 -r 1` | PASS | `logs/mxu32_final4_qcol_rebuild_app.log` |
| `-m 31 -n 64 -k 96 -q 32 -t 1 -d 1 -r 1` | PASS | `logs/mxu32_final4_qrow_app.log` |

## Focused RTL verification

| Test | Result | Coverage evidence |
| --- | --- | --- |
| `tmem_dma_pair_adapter` | PASS | ready skew `01/10/11`, exact-once lane handshakes, R/W data and byte enables, response skew, FIFO full/recovery, ordered joins, back-to-back one aggregate beat/cycle |
| `tmem_switch_16bank` | PASS | 32-byte addresses select banks 0..15; byte 512 wraps to bank 0/local word 1; tags/data restored |
| `gemm_fsm` | PASS | QCOL `M=1,N=16,K=16,QBLK=32`; external I/W/SC/ZP/O = 64/128/64/64/64 B and local = 32/128/32/32/32 B |
| `gemm_tmem_dma_ctrl` | PASS | nine 64-byte words from start channel 4; wrapped channels 0..3 get `+64B`; marker `TMEM_START_CHANNEL_WRAP_PASS` |
| `gemm_unit_v2` | PASS | three-row d3 RAW hold and five-row single-port ACC read/write arbitration with ordered writeback |
| integrated `gemm_node_improve` smoke | PASS | `M=16,N=16,K=128,QDIR=0,WTRANS=0`, 256 numerical elements compared |

Focused logs are retained under `logs/focused/`.

## Milestone C: software, layout, and retained paths

Standalone MXU16 layout contract checks:

| Test | Arguments | Result |
| --- | --- | --- |
| input tiler | `-m 17 -k 17` | PASS, 1536 bytes match |
| output detiler | `-m 17 -n 17` | PASS, 578 bytes match |
| scale/ZP QCOL | `-k 16 -n 18 -q 32 -d 0` | PASS, 512 bytes match |
| scale/ZP QROW | `-k 17 -n 18 -q 32 -d 1` | PASS, 512 bytes match |
| weight general WTRANS=0 | `-k 17 -n 18 -t 0` | PASS |
| weight flat WTRANS=0 | `-k 128 -n 16 -t 0` | PASS |
| weight general WTRANS=1 | `-k 17 -n 18 -t 1` | PASS |
| weight source-transposed general | `-k 17 -n 18 -t 1 --source-transposed` | PASS |
| weight source-transposed flat | `-k 32 -n 16 -t 1 --source-transposed` | PASS |

The weight checks found and fixed two retained 16-byte MXU32 copies; MXU16 now
copies the correct `MXU_NT/2 = 8` packed bytes. The PyTorch launcher was also
aligned with the shared weight-kernel argument ABI and explicitly selects the
general 3-D mode. Active fused layout producers were statically parameterized
and audited for generated MXU dimensions and QCOL ceiling division.

The generated-geometry simx model builds and passes the differential
`M=18,N=78,K=22,WTRANS=1,QDIR=0` case; see
`logs/simx_mxu16_build.log` and
`logs/simx_mxu16_m18_n78_k22_t1_d0.log`.

The retained raw-command `kernel/src/fi_gemm.c` explicitly rejects MXU16 at
preprocess time with its intended diagnostic, while the MXU32 profile
preprocesses successfully. Evidence is in `logs/fi_gemm_mxu16_rejection.log`
and `logs/fi_gemm_mxu32_preprocess.log`.

`runtime/xrt/vortex.cpp` is unchanged. It still aligns allocation, upload, and
download to `CACHE_BLOCK_SIZE=64`, preserving the 64-byte physical XRT/HBM
mapping. Exact odd-shape and tail transfers are covered by the numerical
blackbox matrix above.
