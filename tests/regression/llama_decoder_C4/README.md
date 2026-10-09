# C4 handwritten C++ decoder layer

One real decoder layer, using the existing regression kernels and one C4 FPGA
image throughout. The first validated shape is batch 1, prefill 32. Llama3-8B
uses hidden 4096 / FFN 14336 / Q32 / KV8 / D128; Llama2-7B uses FFN11008 and
KV32. Every QK/PV head runs: each model has 71 GEMM launches. This app does not
perform embedding, LM head, autoregressive generation, or power measurement.

`ops/device_*.cpp` compiles the original device sources in separate translation
units. `kernel.cpp` dispatches one resident binary; `decoder.cpp` builds original
argument structs and connects device buffers. All intermediate allocations are
distinct, allowing independent per-operation replay without restoring data.

## Build and fixtures

Use a configured build directory, the repository toolchain environment, and:

```bash
mkdir -p build_llama_decoder_c4
cd build_llama_decoder_c4
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh
make -C tests/regression/llama_decoder_C4 check-host
```

The hardware wrapper builds the app and sources the alias config. Tested alias:
`improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update`.
Its image is `xrt_hw_u55c_c1_f100_fpint_L2cache_96c0f69b12`, TH16/MXU16,
one core, layout ABI3, GEMM ABI3, 100 MHz.

Generate fixtures and compile TVM **outside** the allocation. Use a built TVM
environment exposing `tvm`, `vortex_llama3`, PyTorch, and the Vortex runtime.
The tested environment is the sibling TVM tree's
`build/c4_nodsp_fsm_update_20261007_220215/environment.sh`. That file changes
the working directory; use absolute paths afterward.

```bash
repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
build="$repo/build_llama_decoder_c4"
source /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
for entry in llama3:llama3-8b llama2:llama2-7b; do
  short="${entry%%:*}"
  model="${entry#*:}"
  fixture="$build/fixtures/${short}_b1_s32_cpp"
  "$py" "$repo/tests/regression/llama_decoder_C4/reference.py" generate \
    --model "$model" --batch 1 --seq-len 32 --fixture "$fixture"
  "$py" "$repo/tests/regression/llama_decoder_C4/reference.py" compile-tvm \
    --fixture "$fixture"
done
```

The fixed seed is 20260831. `fixture.json` records configuration and tensor hashes;
`canonical.npz` and `parameters/` retain canonical and prepacked weights.
`tensors.tsv` is the C++ fixture inventory. Large artifacts remain in the build.
Random weights validate execution and numerical agreement, not model quality.

## Complete validation and measurement

```bash
bash "$repo/tests/regression/llama_decoder_C4/run_validation.sh" "$build" \
  /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
```

The script requests one Slurm FPGA allocation and records BDF, job, image hash,
and device-binary hash in `results/final`. For each model it runs C++ verification,
CPU intermediate comparison, TVM FPGA output comparison, then isolated and
connected latency measurements. Any failing gate stops subsequent stages.
Both models and both latency modes use the same allocation and board.

Individual C++ run, from the configured build:

```bash
./ci/run_black.sh hw \
  --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update \
  --app llama_decoder_C4 \
  --args "--model llama3-8b --batch 1 --seq-len 32 --mode verify --fixture $build/fixtures/llama3_b1_s32_cpp --output $build/results/manual"
```

Then run `reference.py compare --fixture ... --output ...`. The host's final
output PASS does not certify every intermediate by itself. `--stop-after N`
produces only a partial diagnostic, never a full decoder PASS. `--checkpoints`
on TVM compile/run exports diagnostic intermediate tensors. `quant-check-tvm`
tests positive/negative halfway rounding on the allocated FPGA.

## Numerical policy and gates

- Linear weights: signed asymmetric INT4, group32. K/V: signed asymmetric INT4,
  group128 along head dimension. This differs from rev5's recorded symmetric V
  policy and is explicitly shared with the TVM fixture.
- C++ KV quantization rounds range, scale, and division through FP16, then rounds
  INT4 codes to nearest even. The opt-in TVM scheme is
  `signed_asymmetric_int4_fp16`; its Vortex C lowering must use `nearbyintf`, not
  `roundf`. A CPU LLVM test alone does not detect that backend difference.
- SiLU is materialized as FP16 before multiplication. QDIR=0 MXU does not first
  materialize a dequantized FP16 weight. QDIR=1 rounds activation times scale
  to FP16. These are also the standalone GEMM reference rules.
- `rms_reduction_width` selects lane-strided partial sums and a binary tree
  matching the C++ warp reduction structure. Its width comes from the selected
  profile; the existing model default remains unchanged.
- Local operation tolerance: atol/rtol 0.002. User-selected whole-output
  tolerance: atol/rtol 0.005. Both use magnitude split0.25, at most2% violating
  elements, relative L2≤0.01, cosine≥0.999, and no NaN/Inf.
- `intermediate_comparison.json` preserves chain metrics, even when they fail.
  Same-input reference replays distinguish propagation across INT4 boundaries
  from a local operation error. KV packed bytes and qparams must match exactly
  on identical inputs. Local replays never override the final-output gate.

## Latency meaning

`isolated/isolated.csv` has one warmup and three measurements **per actual
operation**, using retained real inputs. `timing/timings.csv` has three connected
whole-layer wall times following one warmup. `timing/profile.csv` has three
separate profiling passes, so counter queries do not enter wall timing.

Compare the sum of per-operation median cycles with connected profile cycles.
Keep host wall time separate: code/weight upload, allocation, tensor dumps,
verification, and final download are excluded, but launch/wait overhead remains.
Independent replay has warmer per-operation cache state than a connected graph;
a cycle difference alone is not proof of host-launch overhead.

Rev5 prefill suites contain 512/1024/2048/4096 tokens, not32. Do not scale their
1K latency linearly to invent a32-token baseline. This experiment's matched
baseline is its own independent C++ per-operation measurement.

Generate the summary after both models finish:

```bash
python3 "$repo/tests/regression/llama_decoder_C4/summarize.py" "$build/results/final"
```

This refuses missing/failed correctness gates or incomplete measurement sets.
