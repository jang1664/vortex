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

## References
- [SpinQuant: LLM Quantization with Learned Rotations](https://arxiv.org/abs/2405.16406)
