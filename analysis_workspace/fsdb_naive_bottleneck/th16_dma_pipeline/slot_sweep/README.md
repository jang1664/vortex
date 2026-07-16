# DMA outstanding-slot sweep

Configuration: `configs/naive_gemm_simd_th16_tcol32_hwexp_dcache.sh`, with
`DMA_RD_OUTSTANDING_SLOT` rebuilt separately for each value. Every run used
xrt-vcs-sim and passed result checking.

| Slots | Generation cycles | Increase vs 8 | Prefill cycles | Increase vs 8 |
|---:|---:|---:|---:|---:|
| 2 | 24,841 | 67.95% | 430,061 | 107.90% |
| 4 | 17,866 | 20.79% | 248,556 | 20.15% |
| 8 | 14,791 | baseline | 206,863 | baseline |

Increasing from two to four slots reduces generation cycles by 28.08% and
prefill cycles by 42.20%. Increasing from four to eight slots still reduces
generation cycles by 17.21% and prefill cycles by 16.77%, so eight slots remain
performance-relevant for both workloads.

The slot-2 and slot-4 `result.txt` files are authoritative. Their simv logs
show that an existing build-directory FSDB lock prevented new sweep waveforms
from being created. Files copied from the stale slot-8 waveform were moved
under `invalid_stale_slot8_fsdb/` and must not be used for slot-depth analysis.
