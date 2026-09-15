# ACC selection results

All listed runs passed numerical checks with no RTL/config/app source changes during execution.

Baseline: L32 D256 all_bram, MXU16, K=N512, q32, transpose=0, qdir=0, repeat=1. Only ACC selection differs between naive ON and OFF.

| M | OFF GEMM | ON GEMM | OFF core | ON core | Core delta |
|---|---:|---:|---:|---:|---:|
| 4 | 14,759 | 14,953 | 21,381 | 21,531 | +0.70% |
| 256 | 411,384 | 295,631 | 417,981 | 302,256 | -27.69% |

The explicit ACC-to-LMEM output copy is part of the ON measurement. There is no claim that removing PSUM LMEM traffic must reduce total cycles.

| M | OFF PSUM reads/writes | ON PSUM reads/writes | ON ACC writes | ON copy + drain cycles | ON output LMEM stall cycles |
|---|---:|---:|---:|---:|---:|
| 4 | 3,968/3,968 | 0/0 | 4,096 | 296 | 0 |
| 256 | 253,952/253,952 | 0/0 | 262,144 | 16,464 | 0 |

PSUM counts are wide requests, 64 bytes each for MXU16. Waveform checks prove final ACC writes = ACC output reads = final LMEM writes, and every output STORE allocation follows local DMA completion and physical LMEM write drain.

## Additional correctness coverage

| Case | GEMM cycles | Core cycles |
|---|---:|---:|
| m1 | 1,010 | 7,567 |
| m3_tail | 3,328 | 9,892 |
| n150 | 1,810 | 8,390 |
| qrow | 2,869 | 9,442 |
| transpose | 1,151 | 7,717 |
| qrow_transpose | 2,797 | 9,367 |

Exact workload tuples are defined in `run.py`. All five final unit checks passed. Existing DMA tests cover reorder/backpressure; blackbox output tests cover unequal source/destination strides.

## ACC ON BW64 topology extension (2026-09-15)

Existing L16/L32 all_bram configs plus GEMM_NAIVE_USE_ACC_MEM; no RTL changes. K=N512, q32, transpose=0, qdir=0, repeat=1. Cache num_req=2, DMA cache ports=1, L1 memory ports=2, DMA outstanding=32.

| LMEM ports / banks | M | GEMM cycles | Core cycles |
|---|---:|---:|---:|
| 16/16 | 4 | 13,502 | 20,079 |
| 16/16 | 256 | 304,956 | 311,529 |
| 32/32 | 4 | 13,053 | 19,629 |
| 32/32 | 256 | 299,334 | 305,904 |

These four additional runs validate numerical output and cycle counts. Detailed ACC-copy waveform assertions above refer to the original BW256 runs.

## M4 response-depth control experiment

ACC ON BW256 with only DMA_SPLIT_RSP_DEPTH changed from 8 to 16: GEMM 12,563, core 19,131; numerical PASS and no source changes during execution.

The depth parameter applies to both DMA splitters. Cache-context blocking and zero DMA LMEM wait identify the cache request path as the observed bottleneck. See [root-cause waveform counters](verification/m4_bandwidth_root_cause.json). M256 was not rerun at BUF16.

## Preservation

Naive OFF and improve reproduce both historical M4/M256 GEMM and core cycles exactly. All 12 edited-translation-unit preprocessing comparisons pass (OFF/improve, debug/NDEBUG). All other RTL is unchanged; internal ACC, common compute and DMA wrapper SHA256 values are recorded in `results.json`.

No synthesis was run. HBM timings are from the existing simulation model.
