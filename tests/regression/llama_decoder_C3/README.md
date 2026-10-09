# C3 resident decoder regression

This application uses the shared row-major runner in `../llama_decoder_common`.
All seven linear projections and all per-head QK/PV products use the unchanged
`fpint_gemm_ffn_hw_naive` device kernel. Vector operations use the existing
standalone kernels, with explicit device head split/concatenation. Intermediates
remain on the FPGA; all query heads execute rather than multiplying one head's
latency afterward.

The default test uses real Llama3-8B dimensions (H=4096, F=14336, Q=32, KV=8,
D=128), batch 1 and 32 input tokens. `--model llama2-7b` selects F=11008, KV=32
and RoPE theta=10000; the implementation is shared.

The hardware alias is
`naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_axi_fix`.
Use a separately configured build directory and its `ci/run_black.sh hw` wrapper.
The fixture generator is `../llama_decoder_common/reference.py`, run in the
existing TVM Python environment with `--candidate C3`.

The CPU oracle retains signed asymmetric W4/KV4, FP16 KV quantization arithmetic,
separate FP16 SiLU output and the 16-lane RMS reduction order. The default gate
checks only the final output, using the previously agreed 0.005 plus the unchanged
fraction/L2/cosine/nonfinite guards. Optional intermediate diagnostics check
saved boundaries, exact packed KV bytes, and same-input operations at 0.002;
these diagnostics do not override a passing final-output gate.

Decode is a fixed first-step replay, B1/query1/past1024, with capacity1056. The
naive ABI does not separate physical stride from effective K/N; QK/PV compute
1056 lanes while softmax uses only 1025 valid positions. This is not a dynamic
cache growth implementation. Setup transfers, validation and output downloads
are excluded from timing, while cache quantization and append are included.

See the shared README and results for verified execution status; creating the
fixture or compiling the app is not a functionality PASS.
