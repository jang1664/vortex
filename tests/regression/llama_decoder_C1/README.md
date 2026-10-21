# C1 decoder regression

This application selects FP16 TCU or FPFP naive MXU for every GEMM, with standalone row-major vector kernels from [the shared decoder implementation](../llama_decoder_common/README.md).

FPGA alias: `tcu_th16_c1_v3_axi_fix`.
Config: `configs/tcu_th16_c1_v3.sh`.

Build independently in `build_llama_decoder_c1_parallel_20261009`, configured with `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`. Source the config before building `hw`, `runtime`, `runtime/xrt TARGET=hw`, `kernel`, and `tests/regression/llama_decoder_C1`.

Generate candidate-specific fixtures with `llama_decoder_common/reference.py generate --candidate C1`; the Python environment must expose the sibling TVM/SpinQuant project, as for C4's reference. A C1 fixture contains predequantized FP16 column-major linear weights in addition to canonical quantized weights. Fixture candidate metadata is checked before executing any operator.

From the configured build directory:

```sh
./ci/run_black.sh hw --fpga-bin tcu_th16_c1_v3_axi_fix \
  --app llama_decoder_C1 --run-only \
  --args "--model llama3-8b --seq-len 32 --fixture $PWD/fixtures/llama3_b1_s32 --output $PWD/results/llama3_b1_s32 --mode verify"
```

Then run `reference.py compare --fixture ... --output ...` with the same directories. For Llama2 use `--model llama2-7b` and its own fixtures.

For decode, first generate a matching C1 B1/S1024 CPU prefix fixture, then generate a fixture with `--decoder-stage decode --seq-len 1 --past-kv-len 1024 --cache-capacity 1056 --past-fixture ...`. The application arguments are `--stage decode --seq-len 1 --past-kv-len 1024 --cache-capacity 1056`.

See [RESULTS.md](RESULTS.md) for measured correctness and outstanding failures. No timing is accepted for a failing decode.

## FPFP MXU selection

The existing application builds `C1_GEMM_BACKEND=auto` by default: a config
with `GEMM_NAIVE_FP16_ENABLE` selects FPFP, otherwise TCU. Override with the make
variable `C1_GEMM_BACKEND=tcu|fpfp` when both capabilities exist. Keep separate
configured build directories for different images. The executable option
`--c1-gemm-backend auto|tcu|fpfp` checks the compiled engine; it does not switch
hardware at runtime.

Generate an FPFP fixture with:

```sh
python tests/regression/llama_decoder_common/reference.py generate \
  --candidate C1 --c1-gemm-backend fpfp --model llama3-8b \
  --seq-len 32 --fixture /absolute/path/fixtures/llama3_fpfp
```

Run from the configured build directory:

```sh
ci/run_black.sh hw --fpga-bin fpfp_th16_m8_n16_wload1_all_bram_acc \
  --app llama_decoder_C1 \
  --args "--c1-gemm-backend fpfp --model llama3-8b --seq-len 32 --fixture /absolute/path/fixtures/llama3_fpfp --output /absolute/path/results/llama3_fpfp --mode verify"
```

FPFP linear weights are row-major `[K,N]`. Prefill converts dequantized K
from `[S,D]` to `[D,S]` once per KV head. Decode retains a `[D,capacity]` K
buffer and dequantizes/transposes only the new row into its fixed position.
Restoring the fixture's previous cache is a one-time setup operation outside
`decoder.run()` timing. PV uses dequantized `[capacity,D]` directly. All heads
execute in the real decoder. FP32 accumulation and final FP16 output are
provided by the FPFP GEMM hardware; no quantization parameters go to that unit.
Cache quantization/dequantization policy and the CPU logical reference remain
the same as C1 TCU. M executes without TCU row rounding.

Old C1 fixtures without a backend field remain TCU fixtures. A fixture for the
wrong backend is rejected because its physical weight orientation differs.
For decode, use the same backend for both prefix and decode fixture generation.
See [rev8 validation](../../../analysis_workspace/latency_on_hw/docs/rev8_c1_fpfp/VALIDATION.md)
for the tested Llama2/Llama3 prefill and one-step decode cases.
The subsequent [incremental-cache validation](../../../analysis_workspace/latency_on_hw/docs/rev8_v2/SUMMARY.md)
also checks preservation of the previous cache and unused tail.

`llama_decoder_common/run_validation.sh --candidate C1 --c1-gemm-backend auto`
also selects the FPFP alias from fixture metadata. `--fpga-bin ALIAS` overrides
the image explicitly; the application still checks fixture/build compatibility.
