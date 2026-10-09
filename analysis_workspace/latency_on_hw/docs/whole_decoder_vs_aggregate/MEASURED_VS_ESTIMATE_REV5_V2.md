# Decoder measured vs Rev5_v2 estimate

2026-10-09. Llama3-8B, batch 1, one decoder layer, all heads.
Prefill: S1024. Decode: first generated token, past KV1024 / valid KV1025.

Measured is the fixed decoder wall time with KV dequant excluded. Estimate uses
Rev5_v2 device cycles at 100 MHz. Error = `(estimate - measured) / measured * 100`.

| Stage | Candidate | Measured (s) | Rev5_v2 estimate (s) | Error (%) |
|---|---|---:|---:|---:|
| Prefill | C1 | 285.319981 | 280.534557 | **-1.68%** |
| Prefill | C2 | 46.042892 | 45.264144 | **-1.69%** |
| Prefill | C3 | 31.832401 | 31.454269 | **-1.19%** |
| Prefill | C4 | 31.060445 | 30.299684 | **-2.45%** |
| Decode first step | C1 | 4.087995 | 4.064528 | **-0.57%** |
| Decode first step | C2 | 0.499419 | 0.515983 | **+3.32%** |
| Decode first step | C3 | 0.272474 | 0.278294 | **+2.14%** |
| Decode first step | C4 | 0.113003 | 0.118120 | **+4.53%** |

Rev5_v2 includes the QK/reorder rerun and C4 decode padded-source KV-quant
remeasurement. Other operation results and decoder measurements are preserved.
Decode timings remain diagnostic because the recorded final-output checks failed;
C4 retains the FPGA image difference described in the detailed report.

Sources: [exact values](../rev5_v2/decoder_comparison.json) and
[detailed comparison](C1_C3_B1_S1024_MATCHED_VS_REV5.md).
