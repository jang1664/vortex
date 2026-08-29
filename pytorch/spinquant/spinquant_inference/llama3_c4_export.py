"""Backend-neutral Llama3 decoder-layer graphs for C4 compiler bring-up.

The modules in this file expose logical FP16-by-INT4 operations only.  They
never name a Vortex physical layout or invoke a C4 device kernel directly.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Mapping

import torch
import torch.nn.functional as F

from . import vortex_export_ops as _vortex_export_ops  # noqa: F401
from .utils.hadamard_utils import get_hadK


ALL_ASYMMETRIC_WKV4 = "signed_all_asymmetric_wkv4_v1"
WEIGHT_GROUP_SIZE = 32
KV_GROUP_SIZE = 128
PROJECTION_DIMS = {
    "q_proj": ("hidden_size", "hidden_size"),
    "k_proj": ("hidden_size", "kv_hidden_size"),
    "v_proj": ("hidden_size", "kv_hidden_size"),
    "o_proj": ("hidden_size", "hidden_size"),
    "gate_proj": ("hidden_size", "intermediate_size"),
    "up_proj": ("hidden_size", "intermediate_size"),
    "down_proj": ("intermediate_size", "hidden_size"),
}


@dataclass(frozen=True)
class Llama3ExportConfig:
    batch_size: int
    query_length: int
    cache_capacity: int
    hidden_size: int = 4096
    intermediate_size: int = 14336
    num_attention_heads: int = 32
    num_key_value_heads: int = 8
    head_dim: int = 128
    rms_norm_eps: float = 1e-5
    rope_theta: float = 500000.0
    weight_group_size: int = WEIGHT_GROUP_SIZE
    kv_group_size: int = KV_GROUP_SIZE
    quantization_policy: str = ALL_ASYMMETRIC_WKV4
    vocabulary_size: int = 128256

    def __post_init__(self) -> None:
        if min(self.batch_size, self.query_length, self.cache_capacity) <= 0:
            raise ValueError("batch, query length, and cache capacity must be positive")
        if self.query_length > self.cache_capacity:
            raise ValueError("query length must not exceed cache capacity")
        if self.hidden_size != self.num_attention_heads * self.head_dim:
            raise ValueError("hidden size must equal query heads times head dimension")
        if self.num_attention_heads % self.num_key_value_heads:
            raise ValueError("query heads must be divisible by key/value heads")
        if self.head_dim != self.kv_group_size:
            raise ValueError("C4 v1 requires one KV quantization group per head")
        if self.hidden_size % self.weight_group_size:
            raise ValueError("hidden size must be divisible by weight group size")
        if self.intermediate_size % self.weight_group_size:
            raise ValueError("intermediate size must be divisible by weight group size")
        if self.quantization_policy != ALL_ASYMMETRIC_WKV4:
            raise ValueError("the initial C4 Llama graph requires all-asymmetric W/K/V INT4")
        if self.vocabulary_size <= 0 or self.vocabulary_size % 2:
            raise ValueError("vocabulary size must be a positive even value")

    @property
    def kv_hidden_size(self) -> int:
        return self.num_key_value_heads * self.head_dim

    @property
    def query_heads_per_kv_head(self) -> int:
        return self.num_attention_heads // self.num_key_value_heads


def parameter_shapes(config: Llama3ExportConfig) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    shapes: dict[str, tuple[tuple[int, ...], torch.dtype]] = {
        "input_norm.weight": ((config.hidden_size,), torch.float16),
        "post_attention_norm.weight": ((config.hidden_size,), torch.float16),
    }
    for name, (input_field, output_field) in PROJECTION_DIMS.items():
        input_size = getattr(config, input_field)
        output_size = getattr(config, output_field)
        shapes[f"{name}.qweight"] = ((input_size, output_size // 2), torch.uint8)
        qparam_shape = (input_size // config.weight_group_size, output_size)
        shapes[f"{name}.scales"] = (qparam_shape, torch.float16)
        shapes[f"{name}.zeros"] = (qparam_shape, torch.int16)
    return shapes


def make_meta_parameters(config: Llama3ExportConfig) -> dict[str, torch.Tensor]:
    return {
        name: torch.empty(shape, dtype=dtype, device="meta")
        for name, (shape, dtype) in parameter_shapes(config).items()
    }


def stack_parameter_shapes(
    config: Llama3ExportConfig, num_layers: int
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    if num_layers <= 0:
        raise ValueError("number of decoder layers must be positive")
    return {
        f"layers.{layer_index}.{name}": specification
        for layer_index in range(num_layers)
        for name, specification in parameter_shapes(config).items()
    }


def make_meta_stack_parameters(
    config: Llama3ExportConfig, num_layers: int
) -> dict[str, torch.Tensor]:
    return {
        name: torch.empty(shape, dtype=dtype, device="meta")
        for name, (shape, dtype) in stack_parameter_shapes(config, num_layers).items()
    }


def full_model_parameter_shapes(
    config: Llama3ExportConfig, num_layers: int
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    shapes = stack_parameter_shapes(config, num_layers)
    shapes.update(
        {
            "token_embedding.weight": (
                (config.vocabulary_size, config.hidden_size),
                torch.float16,
            ),
            "final_norm.weight": ((config.hidden_size,), torch.float16),
            "lm_head.qweight": (
                (config.hidden_size, config.vocabulary_size // 2),
                torch.uint8,
            ),
            "lm_head.scales": (
                (
                    config.hidden_size // config.weight_group_size,
                    config.vocabulary_size,
                ),
                torch.float16,
            ),
            "lm_head.zeros": (
                (
                    config.hidden_size // config.weight_group_size,
                    config.vocabulary_size,
                ),
                torch.int16,
            ),
        }
    )
    return shapes


def make_meta_full_model_parameters(
    config: Llama3ExportConfig, num_layers: int
) -> dict[str, torch.Tensor]:
    return {
        name: torch.empty(shape, dtype=dtype, device="meta")
        for name, (shape, dtype) in full_model_parameter_shapes(
            config, num_layers
        ).items()
    }


def _layer_parameters(
    parameters: Mapping[str, torch.Tensor], layer_index: int
) -> dict[str, torch.Tensor]:
    prefix = f"layers.{layer_index}."
    return {
        tensor_name: parameters[f"{prefix}{tensor_name}"]
        for projection_name in PROJECTION_DIMS
        for tensor_name in (
            f"{projection_name}.qweight",
            f"{projection_name}.scales",
            f"{projection_name}.zeros",
        )
    } | {
        "input_norm.weight": parameters[f"{prefix}input_norm.weight"],
        "post_attention_norm.weight": parameters[
            f"{prefix}post_attention_norm.weight"
        ],
    }


def _rms_norm(hidden: torch.Tensor, weight: torch.Tensor, eps: float) -> torch.Tensor:
    normalized = hidden.float() * torch.rsqrt(
        hidden.float().pow(2).mean(dim=-1, keepdim=True) + eps
    )
    return (normalized * weight.float()).to(torch.float16)


def _rotate_half(hidden: torch.Tensor) -> torch.Tensor:
    half = hidden.shape[-1] // 2
    return torch.cat((-hidden[..., half:], hidden[..., :half]), dim=-1)


def _hadamard(hidden: torch.Tensor, base: torch.Tensor, base_size: int) -> torch.Tensor:
    width = hidden.shape[-1]
    work = hidden.float().reshape(-1, width, 1)
    while work.shape[1] > base_size:
        pairs = work.reshape(work.shape[0], work.shape[1] // 2, 2, work.shape[2])
        work = torch.cat(
            (pairs[:, :, 0, :] + pairs[:, :, 1, :],
             pairs[:, :, 0, :] - pairs[:, :, 1, :]),
            dim=-1,
        )
    if base_size > 1:
        work = torch.matmul(base.reshape(1, base_size, base_size), work)
    return (work.reshape(hidden.shape) / math.sqrt(width)).to(hidden.dtype)


class _Llama3LayerBase(torch.nn.Module):
    def __init__(
        self, config: Llama3ExportConfig, prepacked_weights: bool = False
    ) -> None:
        super().__init__()
        self.config = config
        self.prepacked_weights = prepacked_weights
        inv_freq = 1.0 / (
            config.rope_theta
            ** (torch.arange(0, config.head_dim, 2, dtype=torch.float32) / config.head_dim)
        )
        self.register_buffer("rope_inv_freq", inv_freq, persistent=False)
        r4, r4_base = get_hadK(config.intermediate_size)
        if r4_base == 1:
            r4 = torch.ones((1, 1), dtype=torch.float32)
        self.register_buffer("r4_base", r4.to(torch.float32), persistent=False)
        self.r4_base_size = int(r4_base)

    def _linear(
        self,
        name: str,
        hidden: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> torch.Tensor:
        packed = parameters[f"{name}.qweight"]
        input_size = hidden.shape[-1]
        output_size = getattr(self.config, PROJECTION_DIMS[name][1])
        flattened = hidden.reshape(-1, input_size)
        mm_op = (
            torch.ops.vortex.mm_w4a16_prepacked
            if self.prepacked_weights
            else torch.ops.vortex.mm_w4a16
        )
        output = mm_op(
            flattened,
            packed,
            parameters[f"{name}.scales"],
            parameters[f"{name}.zeros"],
            [input_size, output_size],
            self.config.weight_group_size,
            0,
            1,
            "signed_asymmetric_int4",
            False,
        )
        return output.reshape(*hidden.shape[:-1], output_size)

    def _split_heads(self, hidden: torch.Tensor, heads: int) -> torch.Tensor:
        return hidden.reshape(
            self.config.batch_size,
            hidden.shape[1],
            heads,
            self.config.head_dim,
        ).transpose(1, 2)

    def _rope(self, hidden: torch.Tensor, position_ids: torch.Tensor) -> torch.Tensor:
        frequencies = position_ids.float().unsqueeze(-1) * self.rope_inv_freq.reshape(1, 1, -1)
        embedding = torch.cat((frequencies, frequencies), dim=-1)
        cos = embedding.cos().to(torch.float16).unsqueeze(1)
        sin = embedding.sin().to(torch.float16).unsqueeze(1)
        return (hidden.float() * cos + _rotate_half(hidden).float() * sin).to(torch.float16)

    def _quantize_kv(
        self, hidden: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        logical_shape = hidden.shape
        flattened = hidden.reshape(-1, logical_shape[-1])
        packed, scale, zero = torch.ops.vortex.quantize_int4(
            flattened,
            1,
            self.config.kv_group_size,
            1,
            "signed_asymmetric_int4",
        )
        leading_shape = logical_shape[:-1]
        return (
            packed.reshape(*leading_shape, (logical_shape[-1] + 1) // 2),
            scale.reshape(
                *leading_shape,
                (logical_shape[-1] + self.config.kv_group_size - 1)
                // self.config.kv_group_size,
            ),
            zero.reshape(
                *leading_shape,
                (logical_shape[-1] + self.config.kv_group_size - 1)
                // self.config.kv_group_size,
            ),
        )

    def _attention(
        self,
        query: torch.Tensor,
        key_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        value_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        valid_length: torch.Tensor,
        position_ids: torch.Tensor,
    ) -> torch.Tensor:
        config = self.config
        groups = config.query_heads_per_kv_head
        query_grouped = query.reshape(
            config.batch_size,
            config.num_key_value_heads,
            groups,
            query.shape[-2],
            config.head_dim,
        )
        key_payload, key_scale, key_zero = (
            tensor.unsqueeze(2) for tensor in key_cache
        )
        key_shape = [
            config.batch_size,
            config.num_key_value_heads,
            1,
            config.cache_capacity,
            config.head_dim,
        ]
        scores = torch.ops.vortex.mm_w4a16(
            query_grouped,
            key_payload,
            key_scale,
            key_zero,
            key_shape,
            config.kv_group_size,
            4,
            4,
            "signed_asymmetric_int4",
            True,
        )
        scores = scores.float() / math.sqrt(config.head_dim)
        key_positions = torch.arange(
            config.cache_capacity, device=query.device, dtype=torch.int64
        )
        valid = key_positions.reshape(1, 1, 1, 1, -1) < valid_length.reshape(1, 1, 1, 1, 1)
        causal = key_positions.reshape(1, 1, 1, 1, -1) <= position_ids.reshape(
            config.batch_size, 1, 1, query.shape[-2], 1
        )
        valid = valid & causal
        scores = torch.where(valid, scores, torch.full_like(scores, float("-inf")))
        probabilities = torch.softmax(scores, dim=-1).to(torch.float16)

        value_payload, value_scale, value_zero = (
            tensor.unsqueeze(2) for tensor in value_cache
        )
        value_shape = [
            config.batch_size,
            config.num_key_value_heads,
            1,
            config.cache_capacity,
            config.head_dim,
        ]
        context = torch.ops.vortex.mm_w4a16(
            probabilities,
            value_payload,
            value_scale,
            value_zero,
            value_shape,
            config.kv_group_size,
            4,
            4,
            "signed_asymmetric_int4",
            False,
        )
        return context.reshape(
            config.batch_size,
            config.num_attention_heads,
            query.shape[-2],
            config.head_dim,
        )

    def _layer(
        self,
        hidden: torch.Tensor,
        attention_normalized: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
        key_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        value_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        valid_length: torch.Tensor,
    ) -> torch.Tensor:
        config = self.config
        residual = hidden
        query = self._split_heads(
            self._linear("q_proj", attention_normalized, parameters),
            config.num_attention_heads,
        )
        query = _hadamard(self._rope(query, position_ids), self.r4_base[:1, :1], 1)
        attention = self._attention(
            query, key_cache, value_cache, valid_length, position_ids
        )
        attention = attention.transpose(1, 2).reshape(
            config.batch_size, hidden.shape[1], config.hidden_size
        )
        attention = self._linear("o_proj", attention, parameters)
        residual = (residual.float() + attention.float()).to(torch.float16)
        normalized = _rms_norm(
            residual,
            parameters["post_attention_norm.weight"],
            config.rms_norm_eps,
        )
        gate = self._linear("gate_proj", normalized, parameters)
        up = self._linear("up_proj", normalized, parameters)
        mlp = (F.silu(gate.float()) * up.float()).to(torch.float16)
        mlp = _hadamard(mlp, self.r4_base, self.r4_base_size)
        mlp = self._linear("down_proj", mlp, parameters)
        return (residual.float() + mlp.float()).to(torch.float16)

    def _project_kv(
        self,
        attention_normalized: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> tuple[
        tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        tuple[torch.Tensor, torch.Tensor, torch.Tensor],
    ]:
        key = self._split_heads(
            self._linear("k_proj", attention_normalized, parameters),
            self.config.num_key_value_heads,
        )
        key = _hadamard(self._rope(key, position_ids), self.r4_base[:1, :1], 1)
        value = self._split_heads(
            self._linear("v_proj", attention_normalized, parameters),
            self.config.num_key_value_heads,
        )
        return self._quantize_kv(key), self._quantize_kv(value)


class Llama3LayerPrefill(_Llama3LayerBase):
    def forward(
        self,
        hidden: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> tuple[torch.Tensor, ...]:
        config = self.config
        attention_normalized = _rms_norm(
            hidden,
            parameters["input_norm.weight"],
            config.rms_norm_eps,
        )
        key_update, value_update = self._project_kv(
            attention_normalized, position_ids, parameters
        )
        packed_shape = (
            config.batch_size,
            config.num_key_value_heads,
            config.cache_capacity,
            config.head_dim // 2,
        )
        qparam_shape = (*packed_shape[:-1], 1)
        key_cache = (
            hidden.new_zeros(packed_shape, dtype=torch.uint8),
            hidden.new_zeros(qparam_shape, dtype=torch.float16),
            hidden.new_zeros(qparam_shape, dtype=torch.int16),
        )
        value_cache = tuple(tensor.clone() for tensor in key_cache)
        for position in range(config.query_length):
            key_cache = torch.ops.vortex.kv_cache_update(
                *key_cache,
                *(tensor[..., position : position + 1, :] for tensor in key_update),
                position,
                config.cache_capacity,
            )
            value_cache = torch.ops.vortex.kv_cache_update(
                *value_cache,
                *(tensor[..., position : position + 1, :] for tensor in value_update),
                position,
                config.cache_capacity,
            )
        length = torch.tensor(config.query_length, dtype=torch.int64, device=hidden.device)
        output = self._layer(
            hidden,
            attention_normalized,
            position_ids,
            parameters,
            key_cache,
            value_cache,
            length,
        )
        return (output, *key_cache, *value_cache, length)


class Llama3LayerDecode(_Llama3LayerBase):
    def __init__(
        self, config: Llama3ExportConfig, prepacked_weights: bool = False
    ) -> None:
        if config.query_length != 1:
            raise ValueError("decode specialization requires query_length=1")
        super().__init__(config, prepacked_weights)

    def forward(
        self,
        hidden: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
        key_payload: torch.Tensor,
        key_scale: torch.Tensor,
        key_zero: torch.Tensor,
        value_payload: torch.Tensor,
        value_scale: torch.Tensor,
        value_zero: torch.Tensor,
        cache_length: torch.Tensor,
    ) -> tuple[torch.Tensor, ...]:
        torch._assert_async(
            (cache_length >= 0) & (cache_length < self.config.cache_capacity),
            "cache_length must be within the allocated KV cache capacity",
        )
        attention_normalized = _rms_norm(
            hidden,
            parameters["input_norm.weight"],
            self.config.rms_norm_eps,
        )
        key_update, value_update = self._project_kv(
            attention_normalized, position_ids, parameters
        )
        key_cache = torch.ops.vortex.kv_cache_update_dynamic(
            key_payload,
            key_scale,
            key_zero,
            *key_update,
            cache_length,
            self.config.cache_capacity,
        )
        value_cache = torch.ops.vortex.kv_cache_update_dynamic(
            value_payload,
            value_scale,
            value_zero,
            *value_update,
            cache_length,
            self.config.cache_capacity,
        )
        updated_length = cache_length + 1
        output = self._layer(
            hidden,
            attention_normalized,
            position_ids,
            parameters,
            key_cache,
            value_cache,
            updated_length,
        )
        return (output, *key_cache, *value_cache, updated_length)


class Llama3StackPrefill(torch.nn.Module):
    """Backend-neutral decoder stack with layer-major persistent KV state."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
    ) -> None:
        super().__init__()
        if num_layers <= 0:
            raise ValueError("number of decoder layers must be positive")
        self.num_layers = num_layers
        self.layers = torch.nn.ModuleList(
            Llama3LayerPrefill(config, prepacked_weights) for _ in range(num_layers)
        )

    def forward(
        self,
        hidden: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> tuple[torch.Tensor, ...]:
        layer_states: list[tuple[torch.Tensor, ...]] = []
        for layer_index, layer in enumerate(self.layers):
            state = layer(
                hidden,
                position_ids,
                _layer_parameters(parameters, layer_index),
            )
            hidden = state[0]
            layer_states.append(state)
        return (
            hidden,
            *(torch.stack([state[index] for state in layer_states]) for index in range(1, 7)),
            torch.stack([state[7] for state in layer_states]),
        )


class Llama3StackDecode(torch.nn.Module):
    """One-token decoder stack consuming layer-major persistent KV state."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
    ) -> None:
        super().__init__()
        if num_layers <= 0:
            raise ValueError("number of decoder layers must be positive")
        self.num_layers = num_layers
        self.layers = torch.nn.ModuleList(
            Llama3LayerDecode(config, prepacked_weights) for _ in range(num_layers)
        )

    def forward(
        self,
        hidden: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
        key_payload: torch.Tensor,
        key_scale: torch.Tensor,
        key_zero: torch.Tensor,
        value_payload: torch.Tensor,
        value_scale: torch.Tensor,
        value_zero: torch.Tensor,
        cache_lengths: torch.Tensor,
    ) -> tuple[torch.Tensor, ...]:
        layer_states: list[tuple[torch.Tensor, ...]] = []
        cache_tensors = (
            key_payload,
            key_scale,
            key_zero,
            value_payload,
            value_scale,
            value_zero,
        )
        for layer_index, layer in enumerate(self.layers):
            state = layer(
                hidden,
                position_ids,
                _layer_parameters(parameters, layer_index),
                *(tensor[layer_index] for tensor in cache_tensors),
                cache_lengths[layer_index],
            )
            hidden = state[0]
            layer_states.append(state)
        return (
            hidden,
            *(torch.stack([state[index] for state in layer_states]) for index in range(1, 7)),
            torch.stack([state[7] for state in layer_states]),
        )


class _Llama3ModelBase(torch.nn.Module):
    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int,
        prepacked_weights: bool,
    ) -> None:
        super().__init__()
        self.config = config
        self.num_layers = num_layers
        self.prepacked_weights = prepacked_weights

    def _embed(
        self, token_ids: torch.Tensor, parameters: Mapping[str, torch.Tensor]
    ) -> torch.Tensor:
        return F.embedding(token_ids, parameters["token_embedding.weight"])

    def _finalize(
        self, hidden: torch.Tensor, parameters: Mapping[str, torch.Tensor]
    ) -> tuple[torch.Tensor, torch.Tensor]:
        normalized = _rms_norm(
            hidden,
            parameters["final_norm.weight"],
            self.config.rms_norm_eps,
        )
        flattened = normalized.reshape(-1, self.config.hidden_size)
        mm_op = (
            torch.ops.vortex.mm_w4a16_prepacked
            if self.prepacked_weights
            else torch.ops.vortex.mm_w4a16
        )
        logits = mm_op(
            flattened,
            parameters["lm_head.qweight"],
            parameters["lm_head.scales"],
            parameters["lm_head.zeros"],
            [self.config.hidden_size, self.config.vocabulary_size],
            self.config.weight_group_size,
            0,
            1,
            "signed_asymmetric_int4",
            False,
        )
        return logits.reshape(
            *hidden.shape[:-1], self.config.vocabulary_size
        ), normalized


class Llama3ModelPrefill(_Llama3ModelBase):
    """Token-to-logits Llama3 decoder boundary for prefill."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
    ) -> None:
        super().__init__(config, num_layers, prepacked_weights)
        self.decoder = Llama3StackPrefill(
            config, num_layers, prepacked_weights
        )

    def forward(
        self,
        token_ids: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> tuple[torch.Tensor, ...]:
        state = self.decoder(self._embed(token_ids, parameters), position_ids, parameters)
        logits, normalized = self._finalize(state[0], parameters)
        return (logits, normalized, *state[1:])


class Llama3ModelDecode(_Llama3ModelBase):
    """Token-to-logits Llama3 decoder boundary for one decode step."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
    ) -> None:
        super().__init__(config, num_layers, prepacked_weights)
        self.decoder = Llama3StackDecode(
            config, num_layers, prepacked_weights
        )

    def forward(
        self,
        token_ids: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
        key_payload: torch.Tensor,
        key_scale: torch.Tensor,
        key_zero: torch.Tensor,
        value_payload: torch.Tensor,
        value_scale: torch.Tensor,
        value_zero: torch.Tensor,
        cache_lengths: torch.Tensor,
    ) -> tuple[torch.Tensor, ...]:
        state = self.decoder(
            self._embed(token_ids, parameters),
            position_ids,
            parameters,
            key_payload,
            key_scale,
            key_zero,
            value_payload,
            value_scale,
            value_zero,
            cache_lengths,
        )
        logits, normalized = self._finalize(state[0], parameters)
        return (logits, normalized, *state[1:])


def exported_graph_has_physical_c4_ops(exported: torch.export.ExportedProgram) -> bool:
    physical_names = (
        "mm_w4a16_prepacked",
        "tile_input_a",
        "tile_weight_w4a16",
        "tile_scale_zp_w4a16",
        "mm_w4a16_gemm_core",
        "detile_output",
        "layout_fused",
    )
    graph_text = str(exported.graph_module.graph)
    return any(name in graph_text for name in physical_names)
