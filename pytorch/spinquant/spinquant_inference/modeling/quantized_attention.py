"""
LlamaQuantizedKVAttention — drop-in replacement for LlamaAttention
that always uses int4-quantized K/V and fp16_int4_attention kernel.

Two modes depending on whether kv_cache is wired in:

  kv_cache is not None  (normal generation)
    prefill (T > 1) → kv_cache.prefill()   store full prompt
    decode  (T == 1) → kv_cache.update()   append one token
    K/V retrieved from cache for attention

  kv_cache is None  (re-materialization, e.g. PPL eval)
    K/V are quantized on-the-fly every forward call — same int4 kernel,
    no caching.  No fp16 SDPA fallback; quantization error is always present.
"""
from typing import Optional, Tuple

import torch

from .modeling_llama import LlamaAttention, apply_rotary_pos_emb, repeat_kv
from .quantized_kv_cache import KVQuantizedCache
from ..kernels.fp16_int4_attention import fp16_int4_attention
from ..utils.quant_utils import quantize_per_token
from ..utils.pack_utils import pack_int4_to_int8
from transformers.models.llama.configuration_llama import LlamaConfig


class LlamaQuantizedKVAttention(LlamaAttention):
    """
    LlamaAttention that always routes through int4 KV quantization.

    kv_cache is None at construction and set by the loader before inference.
    When None, K/V are re-materialized (quantized fresh each call) instead
    of stored/retrieved — useful for single-pass evaluation.
    """

    def __init__(
        self,
        config:    LlamaConfig,
        layer_idx: int,
        k_mode:    str = "asym",   # "asym" | "sym"
        v_mode:    str = "sym",    # "sym"  | "asym"
    ):
        super().__init__(config, layer_idx)
        self.k_mode   = k_mode
        self.v_mode   = v_mode
        self.kv_cache: Optional[KVQuantizedCache] = None

    def forward(
        self,
        hidden_states:       torch.Tensor,
        attention_mask:      Optional[torch.Tensor] = None,
        position_ids:        Optional[torch.LongTensor] = None,
        position_embeddings: Optional[Tuple[torch.Tensor, torch.Tensor]] = None,
    ) -> torch.Tensor:
        B, T, _ = hidden_states.shape

        # ---- project --------------------------------------------------------
        q = self.q_proj(hidden_states).view(B, T, self.num_heads,    self.head_dim).transpose(1, 2)
        k = self.k_proj(hidden_states).view(B, T, self.num_kv_heads, self.head_dim).transpose(1, 2)
        v = self.v_proj(hidden_states).view(B, T, self.num_kv_heads, self.head_dim).transpose(1, 2)

        # ---- RoPE — K is quantized after rotation ---------------------------
        if position_embeddings is not None:
            cos, sin = position_embeddings
        else:
            cos, sin = self.rotary_emb(q, position_ids)
        q, k = apply_rotary_pos_emb(q, k, cos, sin)

        # ---- quantize K/V and (optionally) update cache ---------------------
        if self.kv_cache is not None:
            if T > 1:
                self.kv_cache.prefill(k, v, self.layer_idx)
            else:
                self.kv_cache.update(k, v, self.layer_idx)
            (qk, k_scale, k_zero), (qv, v_scale, v_zero) = self.kv_cache.get_kv(self.layer_idx)
        else:
            # re-materialization: quantize on-the-fly, no cache
            k_int, k_scale, k_zero = quantize_per_token(k, mode=self.k_mode)
            v_int, v_scale, v_zero = quantize_per_token(v, mode=self.v_mode)
            qk = pack_int4_to_int8(k_int)   # (B, H_kv, T, D//2)
            qv = pack_int4_to_int8(v_int)

        # ---- attention kernel -----------------------------------------------
        out = fp16_int4_attention(
            q, qk, k_scale, qv, v_scale,
            k_mode=self.k_mode,
            v_mode=self.v_mode,
            k_zero=k_zero,
            v_zero=v_zero,
            is_causal=(T > 1),
        )

        return self.o_proj(out.transpose(1, 2).reshape(B, T, -1))
