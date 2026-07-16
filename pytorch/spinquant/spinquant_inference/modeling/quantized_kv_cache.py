"""
KVQuantizedCache — per-token int4 quantized KV cache.

Quantization scheme is configurable per tensor:
  K : default "asym"  (scale + zero_point)  — quantized after RoPE
  V : default "sym"   (scale only)          — quantized after v_proj

Storage per layer (T = accumulated sequence length, D = head_dim):
  K: qkey    (B, H, T, D//2) int8   — 2 × int4 packed into int8
     k_scale (B, H, T, 1)    fp16
     k_zero  (B, H, T, 1)    fp16   — only when k_mode="asym"

  V: qval    (B, H, T, D//2) int8
     v_scale (B, H, T, 1)    fp16
     v_zero  (B, H, T, 1)    fp16   — only when v_mode="asym"
"""

from __future__ import annotations
from typing import List, Optional, Tuple

import torch

from ..utils.quant_utils import quantize_per_token
from ..utils.pack_utils import pack_int4_to_int8


class KVQuantizedCache:
    """
    KV cache with configurable per-token int4 quantization.

    Args:
        k_mode: "asym" (default) or "sym" — quantization mode for keys
        v_mode: "sym"  (default) or "asym" — quantization mode for values
    """

    def __init__(self, k_mode: str = "asym", v_mode: str = "sym"):
        if k_mode not in ("sym", "asym"):
            raise ValueError(f"k_mode must be 'sym' or 'asym', got {k_mode!r}")
        if v_mode not in ("sym", "asym"):
            raise ValueError(f"v_mode must be 'sym' or 'asym', got {v_mode!r}")

        self.k_mode = k_mode
        self.v_mode = v_mode

        # K cache
        self.qkey_cache   : List[torch.Tensor]           = []
        self.k_scale_cache: List[torch.Tensor]           = []
        self.k_zero_cache : List[Optional[torch.Tensor]] = []  # None when k_mode="sym"

        # V cache
        self.qval_cache   : List[torch.Tensor]           = []
        self.v_scale_cache: List[torch.Tensor]           = []
        self.v_zero_cache : List[Optional[torch.Tensor]] = []  # None when v_mode="sym"

    # ------------------------------------------------------------------
    # Core API
    # ------------------------------------------------------------------

    def prefill(
        self,
        key_states:   torch.Tensor,   # (B, H, T, D)  fp16  — full prompt K after RoPE
        value_states: torch.Tensor,   # (B, H, T, D)  fp16  — full prompt V after v_proj
        layer_idx:    int,
    ) -> None:
        """
        Quantize and store the full prompt KV tensors for layer_idx.
        """
        qk, k_scale, k_zero = quantize_per_token(key_states,   mode=self.k_mode)
        qv, v_scale, v_zero = quantize_per_token(value_states, mode=self.v_mode)

        qk_packed = pack_int4_to_int8(qk)   # (B, H, T, D//2)
        qv_packed = pack_int4_to_int8(qv)

        if layer_idx >= len(self.qkey_cache):
            self.qkey_cache.append(qk_packed)
            self.k_scale_cache.append(k_scale)
            self.k_zero_cache.append(k_zero)
            self.qval_cache.append(qv_packed)
            self.v_scale_cache.append(v_scale)
            self.v_zero_cache.append(v_zero)
        else:
            self.qkey_cache[layer_idx]    = qk_packed
            self.k_scale_cache[layer_idx] = k_scale
            self.k_zero_cache[layer_idx]  = k_zero
            self.qval_cache[layer_idx]    = qv_packed
            self.v_scale_cache[layer_idx] = v_scale
            self.v_zero_cache[layer_idx]  = v_zero

    def update(
        self,
        key_states:   torch.Tensor,   # (B, H, 1, D)  fp16  — after RoPE
        value_states: torch.Tensor,   # (B, H, 1, D)  fp16  — after v_proj
        layer_idx:    int,
    ) -> None:
        """Quantize and append one decode step's key/value states."""
        qk, k_scale, k_zero = quantize_per_token(key_states,   mode=self.k_mode)
        qv, v_scale, v_zero = quantize_per_token(value_states, mode=self.v_mode)

        # scale / zero come out as (B, H, T, n_groups) from quantize_per_token.
        # With default groupsize (=D), n_groups=1, shape is (B, H, 1, 1) — ready to concat on dim=2.
        qk_packed = pack_int4_to_int8(qk)   # (B, H, 1, D//2)
        qv_packed = pack_int4_to_int8(qv)

        if layer_idx >= len(self.qkey_cache):
            self.qkey_cache.append(qk_packed)
            self.k_scale_cache.append(k_scale)
            self.k_zero_cache.append(k_zero)
            self.qval_cache.append(qv_packed)
            self.v_scale_cache.append(v_scale)
            self.v_zero_cache.append(v_zero)
        else:
            self.qkey_cache[layer_idx]    = torch.cat([self.qkey_cache[layer_idx],    qk_packed], dim=2)
            self.k_scale_cache[layer_idx] = torch.cat([self.k_scale_cache[layer_idx], k_scale],   dim=2)
            self.qval_cache[layer_idx]    = torch.cat([self.qval_cache[layer_idx],    qv_packed], dim=2)
            self.v_scale_cache[layer_idx] = torch.cat([self.v_scale_cache[layer_idx], v_scale],   dim=2)
            if k_zero is not None:
                self.k_zero_cache[layer_idx] = torch.cat([self.k_zero_cache[layer_idx], k_zero], dim=2)
            if v_zero is not None:
                self.v_zero_cache[layer_idx] = torch.cat([self.v_zero_cache[layer_idx], v_zero], dim=2)

    def get_kv(self, layer_idx: int) -> Tuple[
        Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]],
        Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]],
    ]:
        """
        Return quantized cache tensors for the given layer.

        Returns:
            k_cache : (qkey, k_scale, k_zero)
                qkey    (B, H, T, D//2)  int8
                k_scale (B, H, T, 1)     fp16
                k_zero  (B, H, T, 1)     fp16  — None when k_mode="sym"

            v_cache : (qval, v_scale, v_zero)
                qval    (B, H, T, D//2)  int8
                v_scale (B, H, T, 1)     fp16
                v_zero  (B, H, T, 1)     fp16  — None when v_mode="sym"
        """
        k_cache = (
            self.qkey_cache[layer_idx],
            self.k_scale_cache[layer_idx],
            self.k_zero_cache[layer_idx],
        )
        v_cache = (
            self.qval_cache[layer_idx],
            self.v_scale_cache[layer_idx],
            self.v_zero_cache[layer_idx],
        )
        return k_cache, v_cache

    # ------------------------------------------------------------------
    # Utility
    # ------------------------------------------------------------------

    def clear(self) -> None:
        """Reset all cached tensors. Call between sequences."""
        self.qkey_cache.clear()
        self.k_scale_cache.clear()
        self.k_zero_cache.clear()
        self.qval_cache.clear()
        self.v_scale_cache.clear()
        self.v_zero_cache.clear()

    def __len__(self) -> int:
        """Number of layers currently cached."""
        return len(self.qkey_cache)

    def seq_len(self, layer_idx: int = 0) -> int:
        """Current cached sequence length."""
        return self.qkey_cache[layer_idx].shape[2]

    def memory_bytes(self) -> int:
        """Total memory occupied by the cache in bytes."""
        total = 0
        for group in (
            self.qkey_cache, self.k_scale_cache,
            self.qval_cache, self.v_scale_cache,
            [t for t in self.k_zero_cache if t is not None],
            [t for t in self.v_zero_cache if t is not None],
        ):
            for t in group:
                total += t.element_size() * t.numel()
        return total

    def memory_summary(self) -> str:
        mb = self.memory_bytes() / 1024 ** 2
        layers = len(self.qkey_cache)
        seq = self.seq_len() if layers > 0 else 0
        return (
            f"KVQuantizedCache | k={self.k_mode} v={self.v_mode} | "
            f"layers={layers} | seq_len={seq} | {mb:.2f} MB"
        )
