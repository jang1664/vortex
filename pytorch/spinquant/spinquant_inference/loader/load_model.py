"""
SpinQuant W4A16 quantized LLaMA-2 model loader

Checkpoint format (consolidated.00.pth):
  model.embed_tokens.weight                  (32000, 4096)    fp16
  model.layers.X.self_attn.q_proj.qweight    (4096,  2048)    int8
  model.layers.X.self_attn.q_proj.scales     (128,   4096)    fp16
  ...
  model.layers.X.mlp.down_proj.qweight       (11008, 2048)    int8
  model.layers.X.mlp.down_proj.scales        (344,   4096)    fp16
  model.layers.X.input_layernorm.weight      (4096,)          fp16
  model.norm.weight                          (4096,)          fp16
  lm_head.weight                             (32000, 4096)    fp16

Loading procedure:
  1. LlamaForCausalLM initialization
  2. nn.Linear → QuantizedLinear / HadamardQuantizedLinear replacement
  3. LlamaAttention → LlamaQuantizedKVAttention replacement
  4. checkpoint load
  5. wire KVQuantizedCache into each attention layer
  6. eval mode, tokenizer load
"""

import torch
import torch.nn as nn
from transformers import AutoConfig, AutoTokenizer
from accelerate import init_empty_weights

from ..modeling.modeling_llama import LlamaForCausalLM
from ..modeling.quantized_linear import QuantizedLinear, HadamardQuantizedLinear
from ..modeling.quantized_attention import LlamaQuantizedKVAttention
from ..modeling.quantized_kv_cache import KVQuantizedCache


# ---------------------------------------------------------------------------
# Layer replacement
# ---------------------------------------------------------------------------

def _replace_linears(model: LlamaForCausalLM, groupsize: int = 32) -> None:
    """
    Replace linear layers in QuantizedLinear or HadamardQuantizedLinear.
    - Attention (q/k/v/o_proj), MLP (gate/up_proj) → QuantizedLinear
    - MLP down_proj → HadamardQuantizedLinear (Onlie Hadamard Rotation + QuantizedLinear)
    """
    for layer in model.model.layers:
        attn = layer.self_attn

        for proj_name in ("q_proj", "k_proj", "v_proj", "o_proj"):
            linear: nn.Linear = getattr(attn, proj_name)
            setattr(attn, proj_name, QuantizedLinear(
                in_features=linear.in_features,
                out_features=linear.out_features,
                groupsize=groupsize,
                bias=linear.bias is not None,
            ))

        mlp = layer.mlp

        for proj_name in ("gate_proj", "up_proj"):
            linear: nn.Linear = getattr(mlp, proj_name)
            setattr(mlp, proj_name, QuantizedLinear(
                in_features=linear.in_features,
                out_features=linear.out_features,
                groupsize=groupsize,
                bias=linear.bias is not None,
            ))

        linear: nn.Linear = mlp.down_proj
        mlp.down_proj = HadamardQuantizedLinear(
            in_features=linear.in_features,
            out_features=linear.out_features,
            groupsize=groupsize,
            bias=linear.bias is not None,
        )


def _replace_attention(model: LlamaForCausalLM, k_mode: str = "asym", v_mode: str = "sym") -> None:
    """Replace every LlamaAttention with LlamaQuantizedKVAttention (kv_cache=None)."""
    for layer in model.model.layers:
        old = layer.self_attn
        new = LlamaQuantizedKVAttention(old.config, old.layer_idx, k_mode=k_mode, v_mode=v_mode)
        # copy projection weights + RoPE (buffers are empty at this point;
        # load_state_dict with assign=True will overwrite them from the checkpoint)
        new.q_proj     = old.q_proj
        new.k_proj     = old.k_proj
        new.v_proj     = old.v_proj
        new.o_proj     = old.o_proj
        new.rotary_emb = old.rotary_emb
        layer.self_attn = new


def _wire_kv_cache(model: LlamaForCausalLM, kv_cache: KVQuantizedCache) -> None:
    """Attach a shared KVQuantizedCache to every LlamaQuantizedKVAttention layer."""
    for layer in model.model.layers:
        layer.self_attn.kv_cache = kv_cache


def load_quantized_model(
    base_model_path: str,
    checkpoint_path: str,
    groupsize: int = 32,
    device: str = "cuda",
    k_mode: str = "asym",
    v_mode: str = "sym",
):
    """
    Load SpinQuant W4A16 quantized LLaMA-2 7B model.

    Args:
        base_model_path : HuggingFace model or local directory path
        checkpoint_path : consolidated.00.pth checkpoint file path
        groupsize       : weight quantization group size (default: 32)
        device          : target device
        k_mode          : KV cache key quantization mode ("asym" or "sym")
        v_mode          : KV cache value quantization mode ("sym" or "asym")

    Returns:
        (model, tokenizer, kv_cache)
    """

    print(f"[1/5] Loading config from {base_model_path}")
    config = AutoConfig.from_pretrained(base_model_path)

    print("[2/5] Building model structure ...")
    with init_empty_weights():
        model = LlamaForCausalLM(config)
    _replace_linears(model, groupsize=groupsize)
    _replace_attention(model, k_mode=k_mode, v_mode=v_mode)

    print(f"[3/5] Loading checkpoint from {checkpoint_path}")
    state_dict = torch.load(checkpoint_path, map_location=device, weights_only=False)
    model.load_state_dict(state_dict, strict=False, assign=True)

    print(f"[4/5] Wiring KV cache ...")
    kv_cache = KVQuantizedCache(k_mode=k_mode, v_mode=v_mode)
    _wire_kv_cache(model, kv_cache)

    print(f"[5/5] Eval mode ...")
    model.eval()

    tokenizer = AutoTokenizer.from_pretrained(base_model_path)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    print("Finished loading quantized model.")
    return model, tokenizer, kv_cache