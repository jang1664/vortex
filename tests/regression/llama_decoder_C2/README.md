# C2 connected Llama decoder regression

This application runs one full Llama2 or Llama3 decoder layer on the C2 image.
Linear projections use the existing naive FP16 x INT4 GEMM hardware kernel;
QK and PV use the existing FP16 TCU kernel. Vector operations and intermediate
activations use row-major layout. Every query and KV head is executed on device.

Implementation is shared with C1 and C3 in `../llama_decoder_common`.
The existing standalone regression kernels and latency_on_hw measurements are
not modified. Quantization/dequantization and attention transposes must execute
on device inside the connected graph; fixtures only prepare initial inputs and
static weights.

Hardware alias:
`naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_axi_fix`.
The alias selects `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3.sh`.

Validation starts with batch 1, 32 prefill tokens, real model dimensions, followed
by one decode input token with 1024 existing KV entries. A successful build does
not imply numerical or timing validation; measured results are recorded separately.

## Physical interfaces

Naive GEMM consumes FP16 row-major A and produces FP16 row-major C, including
M=1. Each row has exactly K or N elements; it does not use C4's tiled 8-row pitch.
Static INT4 weights are packed along N (`WTRANS=0`) with QCOL scale/zero arrays
of shape `[K/QBLK, N]`. The decoder obtains the original device ABI from
`fpint_gemm_ffn_hw_naive/common.h` and includes the original device implementation
in its own translation unit. LMEM scratch uses the original regression allocation
order and 64-byte alignment; insufficient local memory fails before launch.

TCU attention is a different boundary: its column-major B operand requires
explicit device-side reordering/dequantization. Those operations are part of the
connected decoder and its timing, not host preprocessing of intermediate data.

## Reproduce a prepared fixture

Configure and build this application in an isolated build directory after sourcing
the C2 config. Generate fixtures with `../llama_decoder_common/reference.py`
using `--candidate C2`. Source the existing TVM Python environment first; its
`py` variable selects the interpreter and its PYTHONPATH provides the reference
model. Use absolute paths because that environment changes the working directory.

```bash
bash tests/regression/llama_decoder_common/run_validation.sh \
  --candidate C2 --build "$PWD/build_llama_decoder_c2_parallel_20261009" \
  --fixture "$PWD/build_llama_decoder_c2_parallel_20261009/fixtures/llama3_b1_s32" \
  --output "$PWD/build_llama_decoder_c2_parallel_20261009/results/recheck_llama3" \
  --python /home/jaeyongjang/.conda/envs/vortex/bin/python
```

Run this command from the repository root with the reference Python environment
already set. The script invokes `ci/run_black.sh hw --fpga-bin ... --run-only`
from the specified build directory. It obtains prefill/decode dimensions from
fixture metadata and uses the existing C++ final-output gate. Optional `--timing`
runs timing mode directly, using that mode's built-in preflight/final checks
instead of an additional verify graph. `--profile-repetitions 0` uses the mandatory
preflight's `warmup_profile.csv` without extra counter passes.
`--check-intermediates` adds diagnostic comparisons whose
results do not override a passing final-output check.

See [RESULTS.md](RESULTS.md) for the current PASS/FAIL status and decode TCU
subnormal diagnosis; the recorded decode cases also fail the final-output gate.
Older prefill reports used the stricter local-operation acceptance policy. New
runs use final-output-only acceptance without changing any numeric tolerance.

The later [B1/S1024 measurement](B1_S1024_RESULTS.md) records three connected
Llama3 prefill wall-time samples, per-operation cycle profiles, and the remaining
local PV numerical failure. Its comparison limits list adapter variants that
differ from the frozen latency_on_hw benchmark defaults.

The subsequent [matched-variant measurement](MATCHED_B1_S1024_RESULTS.md) uses
the benchmark defaults and the requested final-output-only acceptance policy.
It reports both the original wall time and the requested postprocessing correction
that subtracts measured KV dequantization host time.
