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
LINEAR_COMPUTE_MODES = ("w4", "fp16")
ATTENTION_COMPUTE_MODES = ("w4", "fp16")

_LAYER_CHECKPOINT_PREFIX = (
    "q_projection",
    "query_after_rope",
    "attention_scores",
    "attention_masked_scores",
    "attention_probabilities",
    "attention_context",
    "o_projection",
    "attention_residual",
    "post_attention_normalized",
    "gate_projection",
    "up_projection",
    "activated_mlp",
)


def layer_checkpoint_names(config: "Llama3ExportConfig") -> tuple[str, ...]:
    """Names matching the dense-Hadamard checkpoint tuple."""

    del config
    return (
        *_LAYER_CHECKPOINT_PREFIX,
        "transformed_mlp",
        "down_projection",
        "output",
    )


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
            raise ValueError(
                "the initial C4 Llama graph requires all-asymmetric W/K/V INT4"
            )
        if self.vocabulary_size <= 0 or self.vocabulary_size % 2:
            raise ValueError("vocabulary size must be a positive even value")

    @property
    def kv_hidden_size(self) -> int:
        return self.num_key_value_heads * self.head_dim

    @property
    def query_heads_per_kv_head(self) -> int:
        return self.num_attention_heads // self.num_key_value_heads


def parameter_shapes(
    config: Llama3ExportConfig,
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
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


def fp16_parameter_shapes(
    config: Llama3ExportConfig,
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    """Projection inputs after target-selected W4-to-FP16 materialization."""

    shapes: dict[str, tuple[tuple[int, ...], torch.dtype]] = {
        "input_norm.weight": ((config.hidden_size,), torch.float16),
        "post_attention_norm.weight": ((config.hidden_size,), torch.float16),
    }
    for name, (input_field, output_field) in PROJECTION_DIMS.items():
        shapes[f"{name}.weight"] = (
            (getattr(config, input_field), getattr(config, output_field)),
            torch.float16,
        )
    return shapes


def parameter_shapes_for_compute(
    config: Llama3ExportConfig, linear_compute: str
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    if linear_compute == "w4":
        return parameter_shapes(config)
    if linear_compute == "fp16":
        return fp16_parameter_shapes(config)
    raise ValueError(f"unsupported Llama3 linear compute mode: {linear_compute!r}")


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


def stack_parameter_shapes_for_compute(
    config: Llama3ExportConfig, num_layers: int, linear_compute: str
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    if num_layers <= 0:
        raise ValueError("number of decoder layers must be positive")
    return {
        f"layers.{layer_index}.{name}": specification
        for layer_index in range(num_layers)
        for name, specification in parameter_shapes_for_compute(
            config, linear_compute
        ).items()
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


def embedding_parameter_shapes(
    config: Llama3ExportConfig,
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    """Parameters owned by the independently compiled token embedding boundary."""

    return {
        "token_embedding.weight": (
            (config.vocabulary_size, config.hidden_size),
            torch.float16,
        )
    }


def final_head_parameter_shapes(
    config: Llama3ExportConfig,
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    """Parameters owned by the independently compiled final norm/LM-head boundary."""

    return {
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


def final_head_parameter_shapes_for_compute(
    config: Llama3ExportConfig, linear_compute: str
) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    if linear_compute == "w4":
        return final_head_parameter_shapes(config)
    if linear_compute != "fp16":
        raise ValueError(f"unsupported Llama3 linear compute mode: {linear_compute!r}")
    return {
        "final_norm.weight": ((config.hidden_size,), torch.float16),
        "lm_head.weight": (
            (config.hidden_size, config.vocabulary_size),
            torch.float16,
        ),
    }


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
    parameters: Mapping[str, torch.Tensor], layer_index: int, linear_compute: str = "w4"
) -> dict[str, torch.Tensor]:
    prefix = f"layers.{layer_index}."
    if linear_compute == "w4":
        projection_parameters = {
            tensor_name: parameters[f"{prefix}{tensor_name}"]
            for projection_name in PROJECTION_DIMS
            for tensor_name in (
                f"{projection_name}.qweight",
                f"{projection_name}.scales",
                f"{projection_name}.zeros",
            )
        }
    elif linear_compute == "fp16":
        projection_parameters = {
            f"{projection_name}.weight": parameters[
                f"{prefix}{projection_name}.weight"
            ]
            for projection_name in PROJECTION_DIMS
        }
    else:
        raise ValueError(f"unsupported Llama3 linear compute mode: {linear_compute!r}")
    return projection_parameters | {
        "input_norm.weight": parameters[f"{prefix}input_norm.weight"],
        "post_attention_norm.weight": parameters[f"{prefix}post_attention_norm.weight"],
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
    """Keep the complete mixed-radix transform as one logical export op."""

    return torch.ops.vortex.hadamard(hidden, base, base_size)


class _Llama3LayerBase(torch.nn.Module):
    def __init__(
        self,
        config: Llama3ExportConfig,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
        attention_compute: str = "w4",
    ) -> None:
        super().__init__()
        if linear_compute not in LINEAR_COMPUTE_MODES:
            raise ValueError(f"unsupported Llama3 linear compute mode: {linear_compute!r}")
        if attention_compute not in ATTENTION_COMPUTE_MODES:
            raise ValueError(
                f"unsupported Llama3 attention compute mode: {attention_compute!r}"
            )
        if prepacked_weights and linear_compute != "w4":
            raise ValueError("prepacked weights require W4 linear compute")
        self.config = config
        self.prepacked_weights = prepacked_weights
        self.linear_compute = linear_compute
        self.attention_compute = attention_compute
        inv_freq = 1.0 / (
            config.rope_theta
            ** (
                torch.arange(0, config.head_dim, 2, dtype=torch.float32)
                / config.head_dim
            )
        )
        self.register_buffer("rope_inv_freq", inv_freq, persistent=False)
        r4, r4_base = get_hadK(config.intermediate_size)
        if r4_base == 1:
            r4 = torch.ones((1, 1), dtype=torch.float32)
        self.register_buffer(
            "r3_base", torch.ones((1, 1), dtype=torch.float32), persistent=False
        )
        self.register_buffer("r4_base", r4.to(torch.float32), persistent=False)
        self.r4_base_size = int(r4_base)

    def _linear(
        self,
        name: str,
        hidden: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> torch.Tensor:
        input_size = hidden.shape[-1]
        output_size = getattr(self.config, PROJECTION_DIMS[name][1])
        flattened = hidden.reshape(-1, input_size)
        if self.linear_compute == "fp16":
            output = torch.ops.vortex.fp16_matmul(
                flattened, parameters[f"{name}.weight"], f"linear.{name}"
            )
            return output.reshape(*hidden.shape[:-1], output_size)
        packed = parameters[f"{name}.qweight"]
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
        frequencies = position_ids.float().unsqueeze(-1) * self.rope_inv_freq.reshape(
            1, 1, -1
        )
        embedding = torch.cat((frequencies, frequencies), dim=-1)
        cos = embedding.cos().to(torch.float16).unsqueeze(1)
        sin = embedding.sin().to(torch.float16).unsqueeze(1)
        return (hidden.float() * cos + _rotate_half(hidden).float() * sin).to(
            torch.float16
        )

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
        return self._attention_checkpoints(
            query, key_cache, value_cache, valid_length, position_ids
        )[-1]

    def _attention_checkpoints(
        self,
        query: torch.Tensor,
        key_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        value_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        valid_length: torch.Tensor,
        position_ids: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        """Return the attention GEMM and masking boundaries for debug exports."""

        config = self.config
        groups = config.query_heads_per_kv_head
        query_grouped = query.reshape(
            config.batch_size,
            config.num_key_value_heads,
            groups,
            query.shape[-2],
            config.head_dim,
        )
        key_payload, key_scale, key_zero = (tensor.unsqueeze(2) for tensor in key_cache)
        key_shape = [
            config.batch_size,
            config.num_key_value_heads,
            1,
            config.cache_capacity,
            config.head_dim,
        ]
        if self.attention_compute == "fp16":
            key = torch.ops.vortex.dequantize_int4(
                key_payload,
                key_scale,
                key_zero,
                key_shape,
                4,
                config.kv_group_size,
                4,
                "signed_asymmetric_int4",
            )
            scores = torch.ops.vortex.fp16_matmul(
                query_grouped, key.transpose(-2, -1), "attention.qk"
            )
        else:
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
        masked_scores, probabilities = torch.ops.vortex.causal_softmax(
            scores,
            position_ids,
            valid_length,
            config.head_dim,
        )

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
        if self.attention_compute == "fp16":
            value = torch.ops.vortex.dequantize_int4(
                value_payload,
                value_scale,
                value_zero,
                value_shape,
                4,
                config.kv_group_size,
                4,
                "signed_asymmetric_int4",
            )
            context = torch.ops.vortex.fp16_matmul(
                probabilities, value, "attention.pv"
            )
        else:
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
        context = context.reshape(
            config.batch_size,
            config.num_attention_heads,
            query.shape[-2],
            config.head_dim,
        )
        return scores, masked_scores, probabilities, context

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
        return self._layer_checkpoints(
            hidden,
            attention_normalized,
            position_ids,
            parameters,
            key_cache,
            value_cache,
            valid_length,
        )[-1]

    def _layer_checkpoints(
        self,
        hidden: torch.Tensor,
        attention_normalized: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
        key_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        value_cache: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
        valid_length: torch.Tensor,
    ) -> tuple[torch.Tensor, ...]:
        """Return Q/attention/MLP boundaries without changing their execution order."""

        config = self.config
        residual = hidden
        query_projection = self._linear("q_proj", attention_normalized, parameters)
        query = self._split_heads(query_projection, config.num_attention_heads)
        query = _hadamard(
            self._rope(query, position_ids),
            self.r3_base,
            1,
        )
        scores, masked_scores, probabilities, context = self._attention_checkpoints(
            query, key_cache, value_cache, valid_length, position_ids
        )
        attention = context.transpose(1, 2).reshape(
            config.batch_size, hidden.shape[1], config.hidden_size
        )
        attention = self._linear("o_proj", attention, parameters)
        attention_residual = (residual.float() + attention.float()).to(torch.float16)
        normalized = _rms_norm(
            attention_residual,
            parameters["post_attention_norm.weight"],
            config.rms_norm_eps,
        )
        gate = self._linear("gate_proj", normalized, parameters)
        up = self._linear("up_proj", normalized, parameters)
        activated_mlp = (F.silu(gate.float()) * up.float()).to(torch.float16)
        transformed_mlp = _hadamard(
            activated_mlp,
            self.r4_base,
            self.r4_base_size,
        )
        down_projection = self._linear("down_proj", transformed_mlp, parameters)
        output = (attention_residual.float() + down_projection.float()).to(
            torch.float16
        )
        return (
            query_projection,
            query,
            scores,
            masked_scores,
            probabilities,
            context,
            attention,
            attention_residual,
            normalized,
            gate,
            up,
            activated_mlp,
            transformed_mlp,
            down_projection,
            output,
        )

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
        key = _hadamard(
            self._rope(key, position_ids),
            self.r3_base,
            1,
        )
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
        length = torch.tensor(
            config.query_length, dtype=torch.int64, device=hidden.device
        )
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


class Llama3LayerPrefillCheckpoints(Llama3LayerPrefill):
    """Debug-only prefill boundary exposing every Q/attention/MLP checkpoint."""

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
        length = torch.tensor(
            config.query_length, dtype=torch.int64, device=hidden.device
        )
        checkpoints = self._layer_checkpoints(
            hidden,
            attention_normalized,
            position_ids,
            parameters,
            key_cache,
            value_cache,
            length,
        )
        return (*checkpoints, *key_cache, *value_cache, length)


class Llama3LayerDecode(_Llama3LayerBase):
    def __init__(
        self,
        config: Llama3ExportConfig,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
        attention_compute: str = "w4",
    ) -> None:
        if config.query_length != 1:
            raise ValueError("decode specialization requires query_length=1")
        super().__init__(
            config,
            prepacked_weights,
            linear_compute=linear_compute,
            attention_compute=attention_compute,
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


class Llama3LayerDecodeCheckpoints(Llama3LayerDecode):
    """Debug-only decode boundary exposing Q/attention/MLP checkpoints."""

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
        checkpoints = self._layer_checkpoints(
            hidden,
            attention_normalized,
            position_ids,
            parameters,
            key_cache,
            value_cache,
            updated_length,
        )
        return (*checkpoints, *key_cache, *value_cache, updated_length)


class Llama3StackPrefill(torch.nn.Module):
    """Backend-neutral decoder stack with layer-major persistent KV state."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
        attention_compute: str = "w4",
    ) -> None:
        super().__init__()
        if num_layers <= 0:
            raise ValueError("number of decoder layers must be positive")
        self.num_layers = num_layers
        self.linear_compute = linear_compute
        self.layers = torch.nn.ModuleList(
            Llama3LayerPrefill(
                config,
                prepacked_weights,
                linear_compute=linear_compute,
                attention_compute=attention_compute,
            )
            for _ in range(num_layers)
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
                _layer_parameters(parameters, layer_index, self.linear_compute),
            )
            hidden = state[0]
            layer_states.append(state)
        return (
            hidden,
            *(
                torch.stack([state[index] for state in layer_states])
                for index in range(1, 7)
            ),
            torch.stack([state[7] for state in layer_states]),
        )


class Llama3StackPrefillCheckpoints(torch.nn.Module):
    """One-layer stack ABI wrapper for the debug checkpoint boundary."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 1,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
        attention_compute: str = "w4",
    ) -> None:
        super().__init__()
        if num_layers != 1:
            raise ValueError("checkpoint stack currently supports exactly one layer")
        self.linear_compute = linear_compute
        self.layer = Llama3LayerPrefillCheckpoints(
            config,
            prepacked_weights,
            linear_compute=linear_compute,
            attention_compute=attention_compute,
        )

    def forward(
        self,
        hidden: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> tuple[torch.Tensor, ...]:
        return self.layer(
            hidden,
            position_ids,
            _layer_parameters(parameters, 0, self.linear_compute),
        )


class Llama3StackDecode(torch.nn.Module):
    """One-token decoder stack consuming layer-major persistent KV state."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
        attention_compute: str = "w4",
    ) -> None:
        super().__init__()
        if num_layers <= 0:
            raise ValueError("number of decoder layers must be positive")
        self.num_layers = num_layers
        self.linear_compute = linear_compute
        self.layers = torch.nn.ModuleList(
            Llama3LayerDecode(
                config,
                prepacked_weights,
                linear_compute=linear_compute,
                attention_compute=attention_compute,
            )
            for _ in range(num_layers)
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
                _layer_parameters(parameters, layer_index, self.linear_compute),
                *(tensor[layer_index] for tensor in cache_tensors),
                cache_lengths[layer_index],
            )
            hidden = state[0]
            layer_states.append(state)
        return (
            hidden,
            *(
                torch.stack([state[index] for state in layer_states])
                for index in range(1, 7)
            ),
            torch.stack([state[7] for state in layer_states]),
        )


class _Llama3ModelBase(torch.nn.Module):
    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int,
        prepacked_weights: bool,
        linear_compute: str = "w4",
    ) -> None:
        super().__init__()
        self.config = config
        self.num_layers = num_layers
        self.prepacked_weights = prepacked_weights
        self.linear_compute = linear_compute

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
        if self.linear_compute == "fp16":
            logits = torch.ops.vortex.fp16_matmul(
                flattened, parameters["lm_head.weight"], "linear.lm_head"
            )
            return (
                logits.reshape(*hidden.shape[:-1], self.config.vocabulary_size),
                normalized,
            )
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
        return (
            logits.reshape(*hidden.shape[:-1], self.config.vocabulary_size),
            normalized,
        )


class Llama3TokenEmbedding(torch.nn.Module):
    """Independently compilable token-ID to hidden-state model boundary."""

    def forward(
        self, token_ids: torch.Tensor, parameters: Mapping[str, torch.Tensor]
    ) -> tuple[torch.Tensor]:
        # Keep a tuple output because strict torch.export currently rejects a
        # pytree LeafSpec output for this otherwise scalar boundary.
        return (F.embedding(token_ids, parameters["token_embedding.weight"]),)


class Llama3FinalHead(_Llama3ModelBase):
    """Independently compilable final RMSNorm and asymmetric W4 LM head."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
    ) -> None:
        super().__init__(
            config,
            num_layers=0,
            prepacked_weights=prepacked_weights,
            linear_compute=linear_compute,
        )

    def forward(
        self, hidden: torch.Tensor, parameters: Mapping[str, torch.Tensor]
    ) -> tuple[torch.Tensor, torch.Tensor]:
        return self._finalize(hidden, parameters)


class Llama3ModelPrefill(_Llama3ModelBase):
    """Token-to-logits Llama3 decoder boundary for prefill."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
        attention_compute: str = "w4",
    ) -> None:
        super().__init__(config, num_layers, prepacked_weights, linear_compute)
        self.decoder = Llama3StackPrefill(
            config,
            num_layers,
            prepacked_weights,
            linear_compute,
            attention_compute,
        )

    def forward(
        self,
        token_ids: torch.Tensor,
        position_ids: torch.Tensor,
        parameters: Mapping[str, torch.Tensor],
    ) -> tuple[torch.Tensor, ...]:
        state = self.decoder(
            self._embed(token_ids, parameters), position_ids, parameters
        )
        logits, normalized = self._finalize(state[0], parameters)
        return (logits, normalized, *state[1:])


class Llama3ModelDecode(_Llama3ModelBase):
    """Token-to-logits Llama3 decoder boundary for one decode step."""

    def __init__(
        self,
        config: Llama3ExportConfig,
        num_layers: int = 32,
        prepacked_weights: bool = False,
        linear_compute: str = "w4",
        attention_compute: str = "w4",
    ) -> None:
        super().__init__(config, num_layers, prepacked_weights, linear_compute)
        self.decoder = Llama3StackDecode(
            config,
            num_layers,
            prepacked_weights,
            linear_compute,
            attention_compute,
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
