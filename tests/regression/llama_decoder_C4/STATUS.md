# Implementation status

Completed 2026-10-09; see [RESULTS.md](RESULTS.md) and [README.md](README.md).

- One resident dispatcher reuses ten original handwritten kernel implementations.
- Real-size Llama3-8B and Llama2-7B, batch1/prefill32/one layer, all heads: PASS.
- Final CPU and actual FPGA TVM comparisons: PASS at user-approved 0.005 tolerance.
- Local checks retain 0.002; chain discrepancies and same-input diagnostics remain recorded.
- Packed KV weights/scales/zeros: exact identical-input agreement for all heads.
- Independent operator measurements and connected wall/profile passes: three repeats each.
- Same allocation5750 and BDF0000:2a:00.1 for both models and measurement modes.
- Cycle differences: Llama3 +0.3887%; Llama2 -0.7320%.
- Host layout/TMEM check PASS; original GEMM three cases PASS; TVM unit tests13+17 PASS.
- Artifacts: `build_llama_decoder_c4/results/final`, fixtures under `fixtures/*_b1_s32_cpp`.
- Earlier failing numerical-policy runs remain outside final/ as diagnostic evidence.
- Decoder implementation and validation required no RTL changes or 1K expansion.
- Unrelated pre-existing analysis/RTL/paper edits are preserved.
