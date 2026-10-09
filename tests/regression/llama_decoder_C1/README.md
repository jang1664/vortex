# C1 decoder regression

This application selects FP16 TCU for every GEMM and standalone row-major vector kernels from [the shared decoder implementation](../llama_decoder_common/README.md).

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
