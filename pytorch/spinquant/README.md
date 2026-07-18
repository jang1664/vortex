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

`spinquant_inference.layer_accuracy` is a separate, explicit decoder-layer
harness. It does not use the generation model's monkey patches. Its v1 contract
is one Llama-2-7B prefill decoder layer with W4 group size 32, asymmetric K4,
symmetric V4, online R3 after RoPE, and exact online R4 before `down_proj`.
It does not yet model incremental decode or a persistent KV cache.

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

The fused full-layer integration tests are opt-in hardware tests and run on the
real C4/U55C path; they do not use simx. Case generation and the CUDA reference
accept any positive batch size and sequence length. Both C4 physical plans
currently enforce these kernel-layout limits during preflight:

- `align8(B * S) <= 128` and `align8(S) <= 128`, because the fused kernels
  currently support one 128-row M tile.
- `S` must be a multiple of the 32-column GEMM micro-tile.
- Each grouped QK output stride must remain 512-byte aligned.

The fused plan additionally requires the Llama2-7B `H=4096`, `I=11008`,
32-head shape and canonical score scale and causal mask.

`B=2`, `S=32` is covered by the real-C4 full-layer test for both standalone and
fused plans. Removing the single-M-tile restriction requires multi-tile layout
addressing and output assembly in the fused kernels and is planned separately.

## References
- [SpinQuant: LLM Quantization with Learned Rotations](https://arxiv.org/abs/2405.16406)
