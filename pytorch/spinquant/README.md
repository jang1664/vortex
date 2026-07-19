# SpinQuant W4A16+KV4 Inference Engine

A from-scratch PyTorch inference engine for SpinQuant-quantized LLaMA-2-7B, implementing W4A16 weight quantization and KV4 cache quantization.

## Features

- **W4A16**: weights packed as int4 (8 values per int32), activations in fp16
- **KV4**: per-token int4 KV cache quantization (K: asymmetric, V: symmetric)
- **SpinQuant Rotation**: online Walsh-Hadamard Transform on `down_proj` inputs (`had172 ⊗ H_64`), matching the R4 rotation baked into weights at quantization time
- **Explicit kernel interfaces**: `fp16_int4_linear` and `fp16_int4_attention` as single entry points for future CUDA kernel replacement

## Installation

```bash
# Install PyTorch separately to match your CUDA version
pip install -r requirement.txt
source venv/bin/activate
```

## Project Structure

```
spinquant_inference/
├── generate.py                # Greedy generation CLI
├── eval.py                    # PPL evaluation CLI
├── loader/
│   └── load_model.py          # load_quantized_model() → (model, tokenizer, kv_cache)
├── modeling/
│   ├── modeling_llama.py      # Lightweight LlamaForCausalLM (~250 lines)
│   ├── quantized_linear.py    # QuantizedLinear, HadamardQuantizedLinear
│   ├── quantized_attention.py # LlamaQuantizedKVAttention
│   └── quantized_kv_cache.py  # KVQuantizedCache
├── kernels/
│   ├── fp16_int4_linear.py    # W4A16 GEMM kernel interface
│   └── fp16_int4_attention.py # KV4 attention kernel interface
└── utils/
    ├── quant_utils.py         # Quantize / dequantize (per-token, per-channel)
    ├── pack_utils.py          # int4 ↔ int32 packing
    ├── hadamard_utils.py      # hadamard_transform()
    ├── data_utils.py          # WikiText-2 data loading
    ├── eval_utils.py          # PPL evaluator
    └── debug_utils.py         # Streaming / tracing utilities for generation
```

## Usage

### Loading the model

```python
from spinquant_inference.loader.load_model import load_quantized_model

model, tokenizer, kv_cache = load_quantized_model(
    base_model_path="meta-llama/Llama-2-7b-hf",
    checkpoint_path="bin/consolidated.00.pth",
    device="cuda",
)
```

### Text generation

```bash
# Stream tokens as they are generated (GPT-style)
python -m spinquant_inference.generate \
    --model      meta-llama/Llama-2-7b-hf \
    --checkpoint bin/consolidated.00.pth \
    --prompt     "Once upon a time" \
    --max_new_tokens 200 \
    --debug 1    # 0=silent  1=stream tokens  2=stream + layer trace
```

```python
from spinquant_inference.generate import generate

text = generate(model, tokenizer, kv_cache, "Once upon a time", max_new_tokens=200)
```

### Perplexity evaluation (W4A16+KV4)

```bash
python -m spinquant_inference.eval \
    --model      meta-llama/Llama-2-7b-hf \
    --checkpoint bin/consolidated.00.pth
```

```python
from spinquant_inference.utils.data_utils import get_wikitext2
from spinquant_inference.utils.eval_utils  import evaluator

testenc = get_wikitext2(tokenizer=tokenizer, seqlen=2048, eval_mode=True)
ppl = evaluator(model, testenc, device="cuda", kv_cache=kv_cache)
```

## Quantization Details

### Weight Quantization (W4)

| Field | Shape | dtype | Description |
|-------|-------|-------|-------------|
| `qweight` | `(in, out // 2)` | int8  | 2 × int4 packed (low nibble first), range [-8, 7] |
| `scales` | `(in // groupsize, out)` | fp16 | Per-group symmetric scale |

Default `groupsize=32`, matching the checkpoint (e.g. 128 groups for `q_proj` with `in=4096`).

### KV Cache Quantization (KV4)

| | Mode | Parameters | Quantized after |
|-|------|------------|-----------------|
| K | asymmetric | scale + zero\_point | RoPE |
| V | symmetric  | scale only          | `v_proj` |

Storage per layer: `(B, H, T, D//2)` int8 for packed values, `(B, H, T, 1)` fp16 for scale/zero.

### Online Hadamard Rotation

Applied to `down_proj` inputs (`intermediate_size=11008`).
Decomposition: `had172 ⊗ H_64` (K=172, had\_K=64) — identical to SpinQuant's `matmul_hadU`.
The inverse rotation is pre-absorbed into `down_proj` weights at quantization time; only the forward transform is applied at inference.

## Results

| Configuration | WikiText-2 PPL |
|---------------|---------------|
| SpinQuant reference (W4A16+KV4) | 5.624 |
| This implementation | **5.647** |

The +0.023 gap (~0.4%) comes from floating-point ordering differences in the PyTorch fallback (dequantize → fp32 matmul) vs. SpinQuant's fused CUDA kernels. The result confirms correct W4A16+KV4 quantization.

## Single-layer GPU versus FPGA accuracy

For a complete description of the logical decoder graph, CUDA and Vortex
backend split, capture/compare contract, test layers, current C4 coverage, and
the latency-workload generator relationship, see [TESTING.md](TESTING.md).

`spinquant_inference.layer_accuracy` is a separate, explicit decoder-layer
harness. It does not use the generation model's monkey patches. Its v1 contract
is one Llama-2-7B decoder layer with W4 group size 32, asymmetric K4,
symmetric V4, online R3 after RoPE, and exact online R4 before `down_proj`.
It supports both prefill-only execution and prompt prefill followed by ordered
one-token decode steps with a fixed-capacity persistent KV cache.

Create one deterministic case and run the CUDA reference:

```bash
conda activate vortex
cd pytorch/spinquant
python -m spinquant_inference.layer_accuracy make-case \
  --source random --seed 1 --batch-size 2 --seq-len 32 \
  --output /shared/path/spinquant-layer-case
python -m spinquant_inference.layer_accuracy run \
  --case /shared/path/spinquant-layer-case --backend cuda \
  --stop-after qk --capture both --output /shared/path/spinquant-layer-cuda
```

Use a path visible from both the login and Slurm FPGA nodes; node-local `/tmp`
is not suitable for the hardware handoff.

Run exactly the same case on the allocated FPGA, then compare every captured
stage through the requested stop point:

```bash
./run_layer_accuracy_hw.sh \
  /shared/path/spinquant-layer-case /shared/path/spinquant-layer-fpga qk
python -m spinquant_inference.layer_accuracy compare \
  --reference /shared/path/spinquant-layer-cuda \
  --candidate /shared/path/spinquant-layer-fpga \
  --output /shared/path/spinquant-layer-report.json
```

The optional fourth wrapper argument selects the physical plan. `standalone`
keeps each layout transform as its own kernel and remains the default;
`fused` keeps compatible GEMM layouts across adjacent operations and uses the
fused layout kernels:

```bash
./run_layer_accuracy_hw.sh \
  /shared/path/spinquant-layer-case /shared/path/spinquant-layer-fused \
  final_residual fused
```

### Persistent tile-major decode

Create one portable decode case, run the CUDA semantic reference, and then run
the exact same bytes on C4. The wrapper's fifth argument is the zero-based
decode step containing the stop point:

```bash
cd pytorch/spinquant
python -m spinquant_inference.layer_accuracy make-decode-case \
  --source random --model llama2-7b --seed 17 --batch-size 1 \
  --prompt-len 31 --decode-steps 2 --max-seq-len 64 \
  --output /shared/path/spinquant-decode-case

python -m spinquant_inference.layer_accuracy run \
  --case /shared/path/spinquant-decode-case --backend cuda \
  --decode-step 1 --stop-after final_residual --capture semantic \
  --output /shared/path/spinquant-decode-cuda

./run_layer_accuracy_hw.sh \
  /shared/path/spinquant-decode-case /shared/path/spinquant-decode-c4 \
  final_residual fused 1

python -m spinquant_inference.layer_accuracy compare \
  --reference /shared/path/spinquant-decode-cuda \
  --candidate /shared/path/spinquant-decode-c4 \
  --include-auxiliary \
  --output /shared/path/spinquant-decode-report.json
```

The fused C4 decode backend allocates K and V payload/qparam buffers once for
`max-seq-len`. K remains in the transposed packed GEMM-W layout consumed by QK;
V remains in the packed GEMM-W layout consumed by PV. Prefill and append update
the final buffers in place, then publish the new logical length only after both
K and V writes finish. Saved decode artifacts include a cache descriptor after
prefill and every decode step, so allocation identity, device addresses,
generation, capacity, and logical length can be audited.

### Llama3-8B GQA prefill and decode

For prefill, create a normal layer case with the Llama3 model preset. Each
query head remains an independent `M=S` attention matrix, while four query
heads select the same KV-head payload. K/V projection and cache-side tensors
therefore use 8 heads and 1024 features, while QK, softmax, PV, and head concat
preserve the semantic 32 query heads:

```bash
python -m spinquant_inference.layer_accuracy make-case \
  --source random --model llama3-8b --seed 59 --batch-size 1 --seq-len 32 \
  --output /shared/path/spinquant-llama3-prefill-case
python -m spinquant_inference.layer_accuracy run \
  --case /shared/path/spinquant-llama3-prefill-case --backend cuda \
  --stop-after final_residual --capture semantic \
  --output /shared/path/spinquant-llama3-prefill-cuda
./run_layer_accuracy_hw.sh \
  /shared/path/spinquant-llama3-prefill-case \
  /shared/path/spinquant-llama3-prefill-c4 final_residual fused
python -m spinquant_inference.layer_accuracy compare \
  --reference /shared/path/spinquant-llama3-prefill-cuda \
  --candidate /shared/path/spinquant-llama3-prefill-c4 \
  --profile llama_fp16_w4kv4_v1 \
  --output /shared/path/spinquant-llama3-prefill-report.json
```

The `batch=1`, `seq=32`, seed-59 prefill case has been validated through all
25 semantic stages on a real C4 with no ATen fallback. QK and PV each launch
32 `M=32` GEMMs; the K/V quantizers launch only 8 head cases. The C4/CUDA
final residual comparison passed with relative L2 `0.01042` and cosine
`0.99994`.

Select the Llama3 geometry when creating the portable case:

```bash
python -m spinquant_inference.layer_accuracy make-decode-case \
  --source random --model llama3-8b --seed 53 --batch-size 1 \
  --prompt-len 1 --decode-steps 1 --max-seq-len 32 \
  --output /shared/path/spinquant-llama3-decode-case
```

The semantic graph keeps 32 query heads and 8 KV heads. K/V projections emit
1024 features, and the persistent cache allocates only 8 head groups per batch.
During one-token decode, `hadamard_layout_fused` groups the four query heads
sharing each KV head as four M rows. QK and PV therefore launch 8 M=4 GEMMs
instead of 32 GEMVs. `head_concat_layout_fused` consumes this grouped physical
layout directly and restores the semantic 32-head order.

Llama3-8B also selects its canonical `I=14336`, RMSNorm epsilon `1e-5`, RoPE
theta `500000`, and SpinQuant's exact 28x28 R4 basis (`14336 = 28 * 512`). The
same CUDA/run/compare commands shown above apply to this case.

The `prompt=1`, one-token decode case has been validated through every stage
and `final_residual` on a real C4 with no ATen fallback. The decode QK and PV
placement records each show 8 launches with M=4; the C4/CUDA final residual
comparison passed with relative L2 `0.01114` and cosine `0.99994` for seed 53.

An irregular `batch=3`, `prompt=32`, one-token case has also been validated on
a real C4, making the generation KV length 33. QK and PV each launch 24 grouped
`M=4` GEMMs, PV reports logical `K=33` with `K_pad=64`, and the persistent cache
keeps 8 KV heads per batch. All 72 semantic and auxiliary comparisons passed
with no fallback; the final residual relative L2 was `0.00751` with cosine
`0.99997`. Set `RUN_VORTEX_TESTS=1` and
`RUN_SPINQUANT_LLAMA3_IRREGULAR_FULL=1` to enable the longer irregular-shape
execution regression below.

A separate `batch=3`, `prompt=3`, `decode_steps=33` run reached logical KV
length 36 on a real C4 with no fallback. Every step completed through
`final_residual`; the last QK, softmax, PV, and final residual comparisons all
passed, with final residual relative L2 `0.00761` and cosine `0.99997`. Across
the strict full-run profile, 1193 of 1224 semantic and auxiliary comparisons
passed. The 31 misses were 24 scaled-score exceed-fraction checks, 3 QK
exceed-fraction checks, 2 packed-V quantization checks, and 2 prefill-stage
checks; every PV, softmax, and final residual comparison passed.

The initial correctness implementation has these intentional limits:

- persistent decode requires the `fused` physical plan, a supported
  Llama2-7B/Llama3-8B head dim of 128, and a fixed capacity divisible by 32;
- the grouped head-concat kernel argument ABI is shared by the PyTorch
  extension and its `head_concat_layout_fused` vxbin, so both must be rebuilt
  from the same source revision when changing GQA support;
- storage is preallocated for the test's maximum sequence length; dynamic
  growth, paging, eviction, and multi-request scheduling are not implemented;
- prompt initialization currently launches one update per token and head;
  batching those updates is a later performance optimization;
- the current GEMM register ABI cannot express an independent persistent-weight
  stride, so QK/PV compute the capacity-padded storage extent. Softmax receives
  the true logical key length and emits a zero tail, keeping unused capacity out
  of PV and all semantic captures.

The tile-crossing `31 -> 32 -> 33` case above has been compared through both
decode steps and `final_residual` on a real C4. Focused C4 coverage also consumes
logical prefixes 1, 31, 32, 33, 127, 128, and 129 from one capacity allocation.

In the fused plan, each R3/R4 rotation is executed by
`hadamard_layout_fused`, which writes the transformed values directly in
GEMM-A layout. The K-cache quantizer, QK asymmetric correction, and downstream
GEMM consume that layout directly, so the fused path does not launch
`hadamard_butterfly`, `hadamard_base`, or the corresponding `tile_input_a`.
The standalone plan retains those separate kernels for comparison.

For a direct invocation, pass `--physical-plan standalone|fused` to the `run`
subcommand. Both plans emit the same 25 semantic stages, so their saved runs
can be compared directly. Physical captures and placement metadata expose the
different layout transitions and kernel launch counts.

`--capture semantic` writes decoded tensors for numerical comparison.
`--capture physical` writes raw backend buffers plus
`physical_descriptors.json`; `--capture both` writes both sets and is the
hardware wrapper default. Physical-only runs are diagnostic artifacts and are
not accepted by the semantic `compare` command.

The hardware wrapper uses the C4 alias configuration and bitstream by default
(`improve_th16_tcol32_hwexp_dcache`). `--include-auxiliary` is an optional
diagnostic for packed INT4/scale/zero artifacts; normal end-to-end acceptance
uses semantic captures because sparse code changes are expected when tiny
pre-quantization FP16 differences cross an INT4 bin boundary.

To isolate the PyTorch↔Vortex connection from device layout kernels, run one
pre-tiled GEMM core directly on C4:

```bash
srun -p fpga --gres=fpga:u55c:1 --cpus-per-task=4 --mem=32G --time=0:20:00 \
  bash pytorch/run_hw_test.sh mm_w4a16_gemm_core_hw
```

Useful stop points include `input_norm`, `q_proj`, `q_r3`, `k_quant`, `qk`,
`softmax`, `pv`, `attn_residual`, `r4`, and `final_residual`. The Vortex
command requires `--strict-native`; any unregistered ATen fallback is an error.
Each run writes semantic captures, hashes, placement information, and a physical
layout plan. Use `--source checkpoint --checkpoint ... --checkpoint-profile
spinquant-w4a16-r3r4 --layer-index N` to replace random weights with a strict
layer checkpoint.

The workload generator remains advisory rather than a runtime dependency. Check
that the harness still agrees with both SpinQuant physical plans using:

```bash
python -m spinquant_inference.layer_accuracy check-generator
```

The fused full-layer and decode integration tests are opt-in hardware tests and run on the
real C4/U55C path; they do not use simx. Case generation and the CUDA reference
accept any positive batch size and sequence length. Prefill on both C4 physical plans now
support multiple 128-row M tiles and enforce these remaining kernel-layout
limits during preflight:

- `S` must be a multiple of the 32-column GEMM micro-tile.
- Each grouped QK output stride must remain 512-byte aligned.
- An attention GEMM K dimension above 128 is physically padded to a complete
  128-column DMA tile. For example, logical `S=160` uses `K_pad=256`; the input,
  weight, scale, and zero padding is zero-filled and excluded from semantic
  captures.

The fused plan accepts the canonical Llama2-7B (`H=4096`, `I=11008`, 32 Q/KV
heads) and Llama3-8B (`H=4096`, `I=14336`, 32 query heads, 8 KV heads) shapes,
with canonical score scale and causal mask.

`B=2`, `S=32` and the multi-M-tile case `B=1`, `S=160` have been validated in
real-C4 full-layer runs for both standalone and fused plans.

## References
- [SpinQuant: LLM Quantization with Learned Rotations](https://arxiv.org/abs/2405.16406)
