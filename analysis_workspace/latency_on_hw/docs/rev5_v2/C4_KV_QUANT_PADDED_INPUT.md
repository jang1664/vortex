# C4 decode KV quant: padded source measurement

2026-10-09. Code and CPU/build validation complete. FPGA latency/power
remeasurement completed through the Rev5 v2 workflow: 36/36 cases passed.
See [measurement results](kv_quant_padded/SUMMARY.md). Generated suites were
backed up and regenerated; see `kv_quant_padded/run.sh` and `selection.json`.
Output-value functionality checks on FPGA remain separate from the benchmark.

## Implemented scope

| Item | Previous benchmark | Updated measurement |
|---|---|---|
| Logical token count | K=1 | K=1 |
| Physical source rows, B1 | Forced to1 | `--source-total-k 8`, passed as `src_total_K=8` |
| K source | Compact GEMM-A first row | Padded GEMM-A first row |
| V source | Compact GEMM-C first row | Padded GEMM-C first row, retaining full projection width and head column offset |
| Append execution | Compact-only fast path | Shared compact/padded specializations; padded loads use the decoder's first-row formula |
| Power repetitions | Compact path | Same padded path inside the existing repeat dispatcher |
| Reuse identity | Historical compact args | New physical-source argument changes the execution key |

`tools/workload/gen_kernel_cfgs.py` emits physical source rows for tiled C4
decode quantization. K uses one padded per-head row; V uses the projection's
padded batch-row extent. At B1 both use8 rows. Prefill workload arguments and
quantization policies are unchanged. The CLI option defaults to the logical row
count when omitted, preserving compact invocation semantics.

Both `main.cpp` and `bench_main.cpp` allocate and pack the physical source extent.
The correctness runner now honors the supplied source layout, width and head
offset for append too. Unused padded rows are filled with FP16 NaNs to reveal
accidental reads. Quantization uses only the active row. The ABI is unchanged.

The previous decoder-only load adapter is replaced by the common kernel
implementation, selected with the same single-warp/first-row/tile checks.
Quantization arithmetic and packed output layout are shared. No RTL changed.
The new binary has not been measured; historical decoder/benchmark timings
remain records of their original binaries.

## Validation

- 51 Python/C++ CPU tests passed: workload variants, quant reference/padded
  addressing, and canonicalization. Source rows1/8/16/128, both tiled layouts,
  four head offsets, NaN padding, and distinct old/new execution keys covered.
- Correctness host, benchmark host, and device kernel built with TH16/MXU16
  `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`.
- C4 decoder host and device kernel built against the shared implementation.
- Configured isolated build: `build_kv_quant_padded_20261009`.
- Logs, pre-change source snapshots and generated sample arguments:
  `build_decoder_compare_20261009/kv_quant_pipeline_fix/`.

These premeasurement checks establish buildability and address/argument
correctness. Hardware measurement status and results are recorded separately in
`kv_quant_padded/`. No RTL simulation was run for this change.

## Applying new measurements to rev5_v2

Regenerate the C4 suites from source before measuring; old serialized suite
snapshots still describe compact inputs. Preserve the completed QK/reorder rows
and select only the new decode KV quant cases. For the full suite (B1/B4/B64), the selected filter is:

```text
stage=generation & app=kv_cache_quant_layout_fused_w4a16 & (shape.source_total_k=8 | shape.source_total_k=64)
```

The shape filter matters: `selective_rerun` may otherwise add historical compact
cases from the raw DB back into its selection. After the new rows are measured,
compose and plot with the regenerated suite. Old compact rows may remain in the
database as historical records; their different argument key cannot satisfy the
new measurement. Do not copy an old latency/power value onto the new key.

Representative Llama3 V append arguments (capacity should match the chosen suite):

```text
-k 1 -n 128 -q 128 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled
--quant-mode spinquant_signed_symmetric --source-total-n 1024 --head-col-offset 0
--cache-update append --cache-capacity 1152 --cache-position 1024 --source-total-k 8
```

K uses `--source-transposed -t 1 --gemm-qdir 0 --layout-from gemm_a_tiled`,
`--quant-mode spinquant_signed_asymmetric`, and `--source-total-n 128`.
This correction matches physical input layout; it retains the suite's existing
quantization policy and does not silently replace it with a different policy.
