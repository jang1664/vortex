# C1–C3 decoder verification and C4 KV quant optimization

Date: 2026-10-09. No latency_on_hw pipeline was rerun and no historical database
was modified. No RTL was changed. All runs used TH16/MXU16 candidate images.

## Candidate graph and coverage

The new `tests/regression/llama_decoder_C1`, `llama_decoder_C2`, and
`llama_decoder_C3` applications share `llama_decoder_common`. Existing standalone
vector, TCU and naive MXU kernels are included unchanged. A decoder-local device
reorder connects row-major head layouts. All heads execute on one candidate's
FPGA; host transfers do not supply intermediate operator inputs.

| Candidate | Linear projections | QK/PV | FPGA alias |
|---|---|---|---|
| C1 | FP16 TCU | FP16 TCU | `tcu_th16_c1_v3_axi_fix` |
| C2 | Naive MXU | FP16 TCU | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_axi_fix` |
| C3 | Naive MXU | Naive MXU | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_axi_fix` |
| C4 | Improve MXU | Improve MXU | `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update` |

One full decoder layer uses deterministic random inputs/weights and real model
dimensions: hidden 4096, 32 query heads, head dimension 128; Llama3 has 8 KV heads
and FFN 14336, Llama2 has 32 KV heads and FFN 11008.

| Candidate | Llama3 B1/S32 prefill | Llama2 B1/S32 prefill | First decode, B1/past1024/query1, both models |
|---|---|---|---|
| C1 | PASS | PASS | FAIL: TCU PV numerical error |
| C2 | PASS | PASS | FAIL: TCU PV numerical error |
| C3 | PASS | PASS | FAIL: MXU PV numerical error |
| C4, final quant adapter | PASS | PASS | Existing PV failure unchanged |

Prefill PASS includes independent final-output checks, all 22 same-input local
checks, and exact packed KV checks. Propagated intermediate differences are
retained in reports; they are not all individually PASS. Existing numeric
thresholds were preserved. Decode cache weights/scales/zeros are exact for every
candidate, and all local operations except PV pass. Failed decode timings are
not accepted as validated end-to-end latency.

C1–C3 use physical capacity 1056 for active length 1025. This validates a fixed
first decode step/replay, not arbitrary growing-capacity support in the naive
ABI. C4 uses capacity 1152 with a 1056-aligned execution prefix. C1 static weight
dequantization is outside execution; C1/C2 dynamic KV dequantization and device
reorders remain inside the graph. These are not interchangeable with historical
mixed-image aggregate latency without matching the operation inventory.

Detailed results and reproduction instructions:

- [C1 results](../../../../tests/regression/llama_decoder_C1/RESULTS.md)
- [C2 results](../../../../tests/regression/llama_decoder_C2/RESULTS.md)
- [C3 results](../../../../tests/regression/llama_decoder_C3/RESULTS.md)
- [Shared runner](../../../../tests/regression/llama_decoder_common/README.md)

## Decode numerical failures

C1/C2: the DSP TCU's FP16 input converter in
`hw/rtl/tcu/VX_tcu_fedp_dsp.sv` uses exponent
`127 - 14 - leading_zeros + 1` for nonzero subnormals. With its 10-bit leading
zero count, the IEEE exponent is `127 - 15 - leading_zeros`. The current circuit
therefore multiplies each subnormal input by four. Modeling this error explains
4085–4089 of 4096 PV outputs bit-exactly, with small remaining differences from
the diagnostic reduction path. The unmodified IEEE reference still fails.

C3/C4: the previously documented QROW scaler/subnormal and output conversion
model reproduces all 4096 PV outputs exactly for both models. This is an
arithmetic defect diagnosis, not a layout failure or a correctness waiver.
No converter or tolerance changes were included in this decoder work.

## C4 quant input optimization

Only the source reads of the existing append fast path are specialized in the
C4 decoder. It reads row zero with physical M=8 pitch directly; no LMEM gather,
host copy, extra launch, or duplicated quantization arithmetic is required.
Width comes from `MXU_COL`; the dispatcher checks matching geometry, first row,
one warp, one appended token, and a whole-row quantization group. Other shapes
retain the existing dispatcher.

Median device cycles per head, three isolated repetitions per head, same C4
image and B1/query1/past1024/capacity1152 fixtures:

| Model | Quant | Previous generic padded path | Final direct-load fast path | Change |
|---|---|---:|---:|---:|
| Llama3 | K | 41,244 | 35,158.5 | -14.75% |
| Llama3 | V | 40,700 | 36,175.5 | -11.12% |
| Llama2 | K | 41,408.5 | 35,232.5 | -14.91% |
| Llama2 | V | 40,597 | 36,180 | -10.88% |

Medians pool 24 samples for Llama3 and 96 for Llama2 (8/32 KV heads × 3).
An LMEM gather variant gave little benefit and was discarded. A general
address-helper variant reached roughly 35.5K/36.5K cycles; the final first-row
formula removes unnecessary address calculations.

Every packed cache byte/scale/zero matches the reference, and both complete
decoder output buffers are byte-identical to the old padded-path run. The known
PV failure remains. B1/S32 prefill was rerun for both models after the final
adapter and passed. No claim is made that these quant cycles equal the old
standalone 29K-cycle cases: layout, quantization policy and measurement context
still differ.

The shared quant source adds a compile-time load hook, defaulting to its old
`token[index]` expression. Its default standalone binary is **byte-identical**
to the pre-change binary under the tested C4 config:

`b8b3a16b422fa0070991f313cc3da24194ea0ee0a3d5eabc3e2981811c658514`

Thus this specialization does not alter the tested historical standalone
implementation. Evidence and reproducible scripts are in
`build_llama_decoder_c4/results/quant_first_row_20261009/`:
`run.sh`, `smoke.sh`, `summary.json`, `standalone_identity.json`, source snapshot,
per-model verification reports and isolated CSVs. Baseline artifacts remain in
`results/decode_b1_p1024_20261009/`.

## Why GEMM still has a separate cost

KV quant output already matches the MXU's packed W/scale/zero layout. Fixing its
input reads requires no downstream GEMM change for correctness.

However, the decoder's fused FP16 producers/consumers use an eight-row physical
pitch at logical M=1. Its GEMMs therefore use `origin_M=8, target_M=1`, whereas
the compact standalone M=1 GEMM uses `origin_M=1`. Transfers/preservation of that
physical padding remain a separate source of latency. Optimizing quant reads
does not change the physical A/C layout of QKV or FFN projections. This task
preserves those interfaces; matching compact standalone GEMM costs would need
a broader, coordinated producer/consumer layout change.
