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
from dataclasses import asdict
from typing import List, Optional, Tuple

import torch

from ..utils.quant_utils import dequantize_per_token, quantize_per_token
from ..utils.pack_utils import pack_int4_to_int8, unpack_int8_to_int4
from ..layer_accuracy.specs import CacheGeometry, CacheState


class FixedCapacityKVQuantizedCache:
    """Preallocated row-major semantic oracle for persistent decode tests."""

    def __init__(
        self,
        *,
        batch_size: int,
        num_kv_heads: int,
        head_dim: int,
        max_sequence_length: int,
        device: str | torch.device,
        k_mode: str = "asym",
        v_mode: str = "sym",
    ) -> None:
        if head_dim % 2 != 0:
            raise ValueError("head_dim must be even for INT4 packing")
        if k_mode != "asym" or v_mode != "sym":
            raise ValueError("persistent decode v1 requires asymmetric K and symmetric V")
        self.device = torch.device(device)
        if self.device.type == "cuda" and self.device.index is None:
            self.device = torch.device("cuda", torch.cuda.current_device())
        self.k_mode = k_mode
        self.v_mode = v_mode
        self.geometry = CacheGeometry(
            batch_size=batch_size,
            num_kv_heads=num_kv_heads,
            head_dim=head_dim,
            max_sequence_length=max_sequence_length,
            padded_sequence_length=max_sequence_length,
        )
        self.state = CacheState(self.geometry, allocation_id=f"semantic:{id(self)}")
        packed_shape = (
            batch_size,
            num_kv_heads,
            max_sequence_length,
            head_dim // 2,
        )
        qparam_shape = (batch_size, num_kv_heads, max_sequence_length, 1)
        self.qkey = torch.zeros(packed_shape, dtype=torch.int8, device=self.device)
        self.k_scale = torch.zeros(qparam_shape, dtype=torch.float16, device=self.device)
        self.k_zero = torch.zeros(qparam_shape, dtype=torch.float16, device=self.device)
        self.qvalue = torch.zeros(packed_shape, dtype=torch.int8, device=self.device)
        self.v_scale = torch.zeros(qparam_shape, dtype=torch.float16, device=self.device)

    @property
    def logical_length(self) -> int:
        return self.state.logical_length

    @property
    def cache_generation(self) -> int:
        return self.state.cache_generation

    def buffer_addresses(self) -> tuple[int, ...]:
        return tuple(tensor.data_ptr() for tensor in self.storage_tensors())

    def descriptor(self) -> dict:
        return {
            "geometry": asdict(self.geometry),
            "allocation_id": self.state.allocation_id,
            "buffer_addresses": list(self.buffer_addresses()),
            "logical_length": self.state.logical_length,
            "cache_generation": self.state.cache_generation,
            "lifecycle": self.state.lifecycle,
        }

    def storage_tensors(self) -> tuple[torch.Tensor, ...]:
        return self.qkey, self.k_scale, self.k_zero, self.qvalue, self.v_scale

    def _validate_sources(
        self,
        key_states: torch.Tensor,
        value_states: torch.Tensor,
        *,
        expected_length: int,
    ) -> None:
        expected = (
            self.geometry.batch_size,
            self.geometry.num_kv_heads,
            expected_length,
            self.geometry.head_dim,
        )
        for name, tensor in (("key", key_states), ("value", value_states)):
            if tuple(tensor.shape) != expected:
                raise ValueError(
                    f"{name} source expected shape {expected}, got {tuple(tensor.shape)}"
                )
            if tensor.device != self.device:
                raise ValueError(
                    f"{name} source device {tensor.device} does not match cache {self.device}"
                )
            if not tensor.dtype.is_floating_point:
                raise ValueError(f"{name} source must be floating point")

    @staticmethod
    def _quantize(
        values: torch.Tensor, mode: str
    ) -> tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]]:
        quantized, scale, zero = quantize_per_token(values, mode=mode)
        return pack_int4_to_int8(quantized), scale, zero

    def prefill(self, key_states: torch.Tensor, value_states: torch.Tensor) -> None:
        prompt_length = key_states.shape[2] if key_states.ndim == 4 else -1
        self._validate_sources(key_states, value_states, expected_length=prompt_length)
        qkey, k_scale, k_zero = self._quantize(key_states, self.k_mode)
        qvalue, v_scale, _ = self._quantize(value_states, self.v_mode)
        assert k_zero is not None
        self.prefill_quantized(qkey, k_scale, k_zero, qvalue, v_scale)

    def prefill_quantized(
        self,
        qkey: torch.Tensor,
        k_scale: torch.Tensor,
        k_zero: torch.Tensor,
        qvalue: torch.Tensor,
        v_scale: torch.Tensor,
    ) -> None:
        prompt_length = qkey.shape[2] if qkey.ndim == 4 else -1
        self.state.validate_prefill(prompt_length)
        self._validate_quantized(
            qkey, k_scale, k_zero, qvalue, v_scale, expected_length=prompt_length
        )
        self.qkey[:, :, :prompt_length].copy_(qkey)
        self.k_scale[:, :, :prompt_length].copy_(k_scale)
        self.k_zero[:, :, :prompt_length].copy_(k_zero)
        self.qvalue[:, :, :prompt_length].copy_(qvalue)
        self.v_scale[:, :, :prompt_length].copy_(v_scale)
        self.state.publish_prefill(prompt_length)

    def append(
        self,
        key_states: torch.Tensor,
        value_states: torch.Tensor,
        *,
        position: int,
        generation: Optional[int] = None,
    ) -> None:
        self._validate_sources(key_states, value_states, expected_length=1)
        qkey, k_scale, k_zero = self._quantize(key_states, self.k_mode)
        qvalue, v_scale, _ = self._quantize(value_states, self.v_mode)
        assert k_zero is not None
        self.append_quantized(
            qkey,
            k_scale,
            k_zero,
            qvalue,
            v_scale,
            position=position,
            generation=generation,
        )

    def append_quantized(
        self,
        qkey: torch.Tensor,
        k_scale: torch.Tensor,
        k_zero: torch.Tensor,
        qvalue: torch.Tensor,
        v_scale: torch.Tensor,
        *,
        position: int,
        generation: Optional[int] = None,
    ) -> None:
        if generation is not None:
            self.state.require_generation(generation)
        self.state.validate_append(position=position)
        self._validate_quantized(
            qkey, k_scale, k_zero, qvalue, v_scale, expected_length=1
        )
        target = slice(position, position + 1)
        self.qkey[:, :, target].copy_(qkey)
        self.k_scale[:, :, target].copy_(k_scale)
        self.k_zero[:, :, target].copy_(k_zero)
        self.qvalue[:, :, target].copy_(qvalue)
        self.v_scale[:, :, target].copy_(v_scale)
        self.state.publish_append()

    def _validate_quantized(
        self,
        qkey: torch.Tensor,
        k_scale: torch.Tensor,
        k_zero: torch.Tensor,
        qvalue: torch.Tensor,
        v_scale: torch.Tensor,
        *,
        expected_length: int,
    ) -> None:
        packed_shape = (
            self.geometry.batch_size,
            self.geometry.num_kv_heads,
            expected_length,
            self.geometry.head_dim // 2,
        )
        qparam_shape = (*packed_shape[:-1], 1)
        expected = (
            ("qkey", qkey, packed_shape, torch.int8),
            ("k_scale", k_scale, qparam_shape, torch.float16),
            ("k_zero", k_zero, qparam_shape, torch.float16),
            ("qvalue", qvalue, packed_shape, torch.int8),
            ("v_scale", v_scale, qparam_shape, torch.float16),
        )
        for name, tensor, shape, dtype in expected:
            if tuple(tensor.shape) != shape or tensor.dtype != dtype:
                raise ValueError(
                    f"{name} expected shape={shape}, dtype={dtype}; "
                    f"got shape={tuple(tensor.shape)}, dtype={tensor.dtype}"
                )
            if tensor.device != self.device:
                raise ValueError(
                    f"{name} device {tensor.device} does not match cache {self.device}"
                )

    def get_kv(
        self, *, generation: Optional[int] = None
    ) -> Tuple[
        Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]],
        Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]],
    ]:
        if generation is not None:
            self.state.require_generation(generation)
        active = slice(0, self.logical_length)
        return (
            self.qkey[:, :, active],
            self.k_scale[:, :, active],
            self.k_zero[:, :, active],
        ), (
            self.qvalue[:, :, active],
            self.v_scale[:, :, active],
            None,
        )

    def dequantized_kv(self) -> tuple[torch.Tensor, torch.Tensor]:
        key, value = self.get_kv()
        qkey, k_scale, k_zero = key
        qvalue, v_scale, _ = value
        return (
            dequantize_per_token(
                unpack_int8_to_int4(qkey), k_scale, k_zero, mode=self.k_mode
            ),
            dequantize_per_token(
                unpack_int8_to_int4(qvalue), v_scale, None, mode=self.v_mode
            ),
        )

    def reset(self) -> None:
        self.state.reset()


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
