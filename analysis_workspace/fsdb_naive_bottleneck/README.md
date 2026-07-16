# GEMM_NAIVE FSDB analysis

Primary comparison configuration:
`configs/naive_gemm_simd_th16_tcol32_hwexp_dcache.sh`, one core, 16 threads,
QBLK=32, WTRANS=0, and QDIR=0.

## Exact comparison

| Workload | WLOAD1 baseline | WLOAD4 interleaved | Reduction |
|---|---:|---:|---:|
| generation: M=1, K=256, N=256 | 41,866 cycles | 39,991 cycles | 4.48% |
| prefill: M=1024, K=256, N=256 | 868,441 cycles | 860,716 cycles | 0.89% |

All four runs passed the xrt-vcs result check. The modified design also passed
generation with WTRANS=1 in 39,991 cycles and QDIR=1 in 75,241 cycles.

| Run | Waveform |
|---|---|
| WLOAD1 generation | `th16_wload1_baseline/generation/vcs_cosim.fsdb` |
| WLOAD1 prefill | `th16_wload1_baseline/prefill/vcs_cosim.fsdb` |
| WLOAD4 generation | `th16_wload4/generation/vcs_cosim.fsdb` |
| WLOAD4 prefill | `th16_wload4/prefill/vcs_cosim.fsdb` |

Keep every `vcs_cosim.fsdb*` sidecar in the same directory. Some focused
waveforms remain as a bundle rather than a single finalized file.

## Pipelined global DMA result

`VX_dma_unit_misal` now overlaps 3-D read-address generation, physical read
issue, tagged response capture/packing, and destination write issue. The target
configuration uses an eight-slot cap. Source tag widths provide eight slots for
G2L and two slots for L2G without widening the shared memory interfaces.

| Workload | WLOAD4 before DMA pipeline | Pipelined DMA | Reduction |
|---|---:|---:|---:|
| generation: M=1, K=256, N=256 | 39,991 cycles | 14,791 cycles | 63.01% |
| prefill: M=1024, K=256, N=256 | 860,716 cycles | 206,863 cycles | 75.97% |

Both final runs passed xrt-vcs result checking. Their waveforms are under
`th16_dma_pipeline/generation/` and `th16_dma_pipeline/prefill/`. The prefill
waveform uses `FSDB_DMA_ONLY`; preserve all of its `vcs_cosim.fsdb*` sidecars.

Key FSDB measurements:

| Metric | Generation | Prefill |
|---|---:|---:|
| DMA `S_RUN` | 4,186 cycles | 144,058 cycles |
| Slot occupancy = 8 | 2,938 cycles | 78,194 cycles |
| Read-generation/pack overlap | 476 cycles | 20,540 cycles |
| Pack movement | 2,656 cycles | 118,784 cycles |

The request queues drain quickly, while the prefill pack stage is active for
82.46% of DMA `S_RUN`. The old response-wait bottleneck is hidden; the remaining
critical stage is the 16-byte pack/write assembly path.

### Outstanding-slot sensitivity

| Slots | Generation cycles | Increase vs 8 | Prefill cycles | Increase vs 8 |
|---:|---:|---:|---:|---:|
| 2 | 24,841 | 67.95% | 430,061 | 107.90% |
| 4 | 17,866 | 20.79% | 248,556 | 20.15% |
| 8 | 14,791 | baseline | 206,863 | baseline |

See `th16_dma_pipeline/slot_sweep/README.md` and the per-run `result.txt`
files for the experiment record.

## Analyze

```bash
python3 analysis_workspace/fsdb_naive_bottleneck/analyze_naive_gemm.py \
  analysis_workspace/fsdb_naive_bottleneck/th16_wload4/generation/vcs_cosim.fsdb

python3 analysis_workspace/fsdb_naive_bottleneck/analyze_naive_gemm.py \
  analysis_workspace/fsdb_naive_bottleneck/th16_wload4/prefill/vcs_cosim.fsdb

python3 analysis_workspace/fsdb_naive_bottleneck/analyze_dma_pipeline.py \
  analysis_workspace/fsdb_naive_bottleneck/th16_dma_pipeline/generation/vcs_cosim.fsdb

python3 analysis_workspace/fsdb_naive_bottleneck/analyze_dma_pipeline.py \
  analysis_workspace/fsdb_naive_bottleneck/th16_dma_pipeline/prefill/vcs_cosim.fsdb
```

Use `--partial` only for a checkpoint or a live, periodically flushed FSDB.

## Key measurements

| Metric | Generation WLOAD1 | Generation WLOAD4 | Prefill WLOAD1 | Prefill WLOAD4 |
|---|---:|---:|---:|---:|
| Complete FSM window | 32,867 | 30,931 | 853,314 | 845,874 |
| GEMM busy cycles | 3,234 | 3,234 | 388,675 | 135,792 |
| GEMM busy / FSM window | 9.84% | 10.46% | 45.55% | 16.05% |
| Old weight 16B valid stall | 50.2% | N/A | 56.8% | N/A |
| Old weight lane-0 valid stall | 0.6% | N/A | 15.6% | N/A |
| Gather logical-lane valid stall | N/A | 0.4-1.2% | N/A | 0.4-0.9% |

The baseline serializes each 16-byte weight item into two 8-byte requests on
LMEM lane 0. The modified path gathers eight strided 8-byte lane responses into
one 64-byte GEMM weight write and allows four groups in flight. This removes
the single-lane serialization and substantially shortens the time for which
the GEMM unit remains busy loading weights.

The prefill E2E reduction is smaller because weight loading is overlapped with
other tile preparation. After the weight path is widened, the largest FSM
residencies are `S_PRE_NEXT_LD_DONE_NTF`, scale loading, and the remaining
next-weight notification wait, so the removed GEMM-side weight occupancy is
not all on the end-to-end critical path.

## Retained debug data

`th16_wload4/debug_m128_final_slot_loss/` captures the depth-four output-DMA
failure that issued 511 of 512 destination writes. It is retained with all
sidecars as a regression record. The older root-level generation and
`prefill_checkpoint/` data use the earlier eight-thread configuration and are
not directly comparable to the exact 16-thread runs above.
