# FlashAttention improvement — iteration 1

2026-11-02. Apply the three independently successful software techniques and
remeasure against separate QK + softmax + PV on the same FPGA image.

Interactive timing diagrams: [timing.html](timing.html). Open directly in Chrome;
the single file embeds all measurement data and works without a server. It
separates measured aggregate costs from the schematic execution order.

## Applied changes

- Use the supported `head_dim=128` constant in partial accumulation and final
  output address arithmetic. The main-entry dimension check uses the same constant.
- Specialize the existing online-softmax worker with a `Resident` template
  parameter. The resident instantiation has a constant 128-key tile; the legacy
  instantiation retains its progress polling, rescaling and original reductions.
  Worker launch/stub functions select the matching instantiation.
- Reuse `softmax_common/warp_reduce_full.h` for resident max/sum reductions.
- Retain the diagnostic phase counters for subsequent iterations. Track the new
  helper dependency in the standalone FlashAttention Makefile.

The failed wide-padding-copy experiment is excluded. K/V padding, exp placement,
publication/fences, DMA, MMIO protocol, RTL, image and numerical thresholds are
unchanged. These are software changes; no new synthesis or PnR was run.

## Matched performance comparison

Llama3-8B, batch 1, resident FP16 output. All attention heads are included.
Same rebuilt decoder ELF, fixtures, config, FPGA alias and board were used for
both backends. Core cycles are converted to milliseconds at 100 MHz; host launch
overhead is excluded. Each number is a median of three profile samples. The
separate baseline is the sum of QK, softmax and PV medians.

| Workload | Previous Flash (ms) | Improved Flash (ms) | Separate QK+softmax+PV (ms) | Flash time reduction | Improved Flash / separate |
|---|---:|---:|---:|---:|---:|
| Decode KV17, capacity32 | 17.05105 | 14.74399 | 2.32002 | 13.5% | 6.36x |
| Decode KV129, capacity256 | 12.86276 | 8.70796 | 2.93982 | 32.3% | 2.96x |
| Prefill128 | 533.54976 | 306.98817 | 151.82905 | 42.5% | 2.02x |

The previous column is the instrumented baseline from the preceding diagnosis.
The separate-kernel column was measured again with this iteration's decoder;
it is not copied from the historical comparison. In particular, its prefill
softmax measured 14,120,725 cycles rather than the historical 13,774,639, so the
current ratio uses the matched new measurement.

| Workload | QK cycles | Softmax cycles | PV cycles | Sum |
|---|---:|---:|---:|---:|
| Decode KV17 | 47,101 | 134,722 | 50,179 | 232,002 |
| Decode KV129 | 54,816 | 181,812 | 57,354 | 293,982 |
| Prefill128 | 526,612 | 14,120,725 | 535,568 | 15,182,905 |

## Remaining costs

Prefill128 phase medians:

| Phase | Before cycles | After cycles |
|---|---:|---:|
| Online softmax | 24,256,975 | 13,881,361 |
| Partial accumulation | 11,382,590 | 5,842,165 |
| Final normalization/output | 10,817,997 | 4,091,165 |
| SIMD initialization | 718,683 | 719,004 |
| GEMM wait including implicit DMA | 4,286,000 | 4,286,056 |
| Once-per-head OBUF initialization copy | 1,464,600 | 1,464,726 |

The improved online softmax now takes approximately the same time as the
separate softmax. Extra accumulation and normalization still cost 9,933,330
cycles (99.33 ms), and the serial GEMM/SRAM-copy path remains unchanged.

For KV17, input preparation still costs 980,359 cycles (9.80 ms), about 66.5%
of the improved attention operation. Its modest overall improvement is
consistent with deliberately preserving the original padding implementation.

The next bounded iteration can examine the extra passes for a single KV tile,
with numerical equivalence checks. Short-decode padding is a separate target;
the failed wide-copy experiment should not be reinstated as a proven fix.
No combined future speedup or universal deadlock-freedom is claimed here.

## Validation

- All six full-decoder timing runs completed with the existing final CPU-output
  gates: three workloads × resident/separate backends.
- The improved resident Q input, attention context and final output are
  byte-identical to the preceding instrumented baseline in all three workloads.
- Full CPU intermediate/reference checks and the existing cross-backend
  input/context/output checks are retained in the validation evidence.
- Standalone board checks cover legacy single tile, resident FP16/FP32 multiple
  tiles, and resident FP16/FP32 causal masks with a tail (`M16/N257/position0`).
- No hang was observed in these decoder and standalone tests. The old failed
  padding experiment was not run in this iteration.

Board: `0000:2a:00.1`. Config:
`configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`.
Alias:
`improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_unified_mmio_r1`.
Image SHA256:
`c330b5270631894e5462168aee7281e0d38bcfa1914cd5223d498b2977f239ff`.

Small evidence: [comparison.json](comparison.json), [checks.json](checks.json).
Large raw logs and outputs: `../runs/iteration1/` (ignored, preserved locally).
`comparison.json` records raw cycle samples, phase medians, ELF hashes, numerical
comparison results and exact-match checks. `compare.py` fails if required
correctness or matching-binary evidence is missing.

## Reproduce

From the repository root with this iteration's source:

```bash
bash agent-tasks/c4-attention-slowdown/run.sh iteration1/resident
bash agent-tasks/c4-attention-slowdown/run.sh iteration1/legacy --backend legacy
bash agent-tasks/c4-attention-slowdown/iteration1/validate.sh
python3 agent-tasks/c4-attention-slowdown/iteration1/compare.py
```

The run directories must not already exist. Preserve old evidence and use a
new iteration directory for subsequent work. `run.sh` sources the selected
config and uses the configured `build_c4_unified_mmio_hw` wrapper through Slurm.
The build was refreshed with `../configure --xlen=64 --tooldir=/opt/vortex
--prefix="$HOME/tools/vortex"` before the standalone checks.
