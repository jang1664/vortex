"""Typed semantic and physical tensor contracts used by all backends."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from functools import reduce
from operator import mul
from typing import Mapping, Optional, Protocol, Tuple


LLAMA2_MODEL = "llama2-7b"
LLAMA3_MODEL = "llama3-8b"
SUPPORTED_MODELS = (LLAMA2_MODEL, LLAMA3_MODEL)


@dataclass(frozen=True)
class LayerConfig:
    model: str = LLAMA2_MODEL
    hidden_size: int = 4096
    intermediate_size: int = 11008
    num_attention_heads: int = 32
    head_dim: int = 128
    batch_size: int = 1
    sequence_length: int = 32
    weight_group_size: int = 32
    kv_group_size: int = 128
    rms_norm_eps: float = 1e-6
    rope_theta: float = 10000.0
    # Appended to preserve the positional constructor used before GQA support.
    num_key_value_heads: int | None = None

    def __post_init__(self) -> None:
        if self.num_key_value_heads is None:
            object.__setattr__(self, "num_key_value_heads", self.num_attention_heads)
        if self.hidden_size != self.num_attention_heads * self.head_dim:
            raise ValueError("hidden_size must equal num_attention_heads * head_dim")
        if self.num_key_value_heads <= 0:
            raise ValueError("num_key_value_heads must be positive")
        if self.num_attention_heads % self.num_key_value_heads != 0:
            raise ValueError("num_attention_heads must be divisible by num_key_value_heads")
        if self.batch_size <= 0:
            raise ValueError("batch_size must be positive")
        if self.sequence_length <= 0:
            raise ValueError("sequence_length must be positive")
        if self.hidden_size % self.weight_group_size != 0:
            raise ValueError("hidden_size must be divisible by weight_group_size")
        if self.intermediate_size % self.weight_group_size != 0:
            raise ValueError("intermediate_size must be divisible by weight_group_size")
        if self.head_dim != self.kv_group_size:
            raise ValueError("v1 uses one KV quantization group per attention head")

    def to_dict(self) -> dict:
        return asdict(self)

    @property
    def num_key_value_groups(self) -> int:
        return self.num_attention_heads // self.num_key_value_heads

    @property
    def kv_hidden_size(self) -> int:
        return self.num_key_value_heads * self.head_dim

    @classmethod
    def for_model(cls, model: str, **overrides) -> "LayerConfig":
        presets = {
            LLAMA2_MODEL: {},
            LLAMA3_MODEL: {
                "hidden_size": 4096,
                "intermediate_size": 14336,
                "num_attention_heads": 32,
                "num_key_value_heads": 8,
                "head_dim": 128,
                "rms_norm_eps": 1e-5,
                "rope_theta": 500000.0,
            },
        }
        if model not in presets:
            raise ValueError(f"unsupported model preset {model!r}")
        values = {"model": model, **presets[model], **overrides}
        return cls(**values)

    @classmethod
    def from_dict(cls, value: dict) -> "LayerConfig":
        return cls(**value)


@dataclass(frozen=True)
class DecodeConfig:
    """Logical prompt/decode geometry for one persistent-cache test case."""

    layer: LayerConfig
    prompt_length: int
    decode_steps: int
    max_sequence_length: int

    def __post_init__(self) -> None:
        if self.prompt_length <= 0:
            raise ValueError("prompt_length must be positive")
        if self.decode_steps <= 0:
            raise ValueError("decode_steps must be positive")
        total_length = self.prompt_length + self.decode_steps
        if self.layer.sequence_length != total_length:
            raise ValueError(
                "layer sequence_length must equal prompt_length + decode_steps"
            )
        if total_length > self.max_sequence_length:
            raise ValueError(
                f"prompt and decode length {total_length} exceeds max_sequence_length "
                f"{self.max_sequence_length}"
            )

    @property
    def total_sequence_length(self) -> int:
        return self.prompt_length + self.decode_steps

    def to_dict(self) -> dict:
        return {
            "layer": self.layer.to_dict(),
            "prompt_length": self.prompt_length,
            "decode_steps": self.decode_steps,
            "max_sequence_length": self.max_sequence_length,
        }

    @classmethod
    def from_dict(cls, value: dict) -> "DecodeConfig":
        return cls(
            layer=LayerConfig.from_dict(value["layer"]),
            prompt_length=value["prompt_length"],
            decode_steps=value["decode_steps"],
            max_sequence_length=value["max_sequence_length"],
        )


@dataclass(frozen=True)
class CacheGeometry:
    """Immutable address geometry shared by semantic and physical caches."""

    batch_size: int
    num_kv_heads: int
    head_dim: int
    max_sequence_length: int
    padded_sequence_length: int

    def __post_init__(self) -> None:
        if min(self.batch_size, self.num_kv_heads, self.head_dim) <= 0:
            raise ValueError("cache batch, head count, and head dimension must be positive")
        if self.max_sequence_length <= 0:
            raise ValueError("max_sequence_length must be positive")
        if self.padded_sequence_length < self.max_sequence_length:
            raise ValueError("padded_sequence_length must cover max_sequence_length")


@dataclass
class CacheState:
    """Mutable commit metadata for an already allocated cache."""

    geometry: CacheGeometry
    allocation_id: str
    logical_length: int = 0
    cache_generation: int = 0
    lifecycle: str = "empty"

    def __post_init__(self) -> None:
        if not self.allocation_id:
            raise ValueError("allocation_id must be non-empty")
        if self.logical_length != 0 or self.lifecycle != "empty":
            raise ValueError("new cache state must start empty")

    def require_generation(self, generation: int) -> None:
        if generation != self.cache_generation:
            raise ValueError(
                f"stale cache generation {generation}; current generation is "
                f"{self.cache_generation}"
            )

    def commit_prefill(self, prompt_length: int) -> None:
        self.validate_prefill(prompt_length)
        self.publish_prefill(prompt_length)

    def validate_prefill(self, prompt_length: int) -> None:
        if self.lifecycle != "empty":
            raise ValueError("prefill requires an empty cache")
        if prompt_length <= 0:
            raise ValueError("prefill length must be positive")
        if prompt_length > self.geometry.max_sequence_length:
            raise ValueError("prefill length exceeds cache capacity")

    def publish_prefill(self, prompt_length: int) -> None:
        self.logical_length = prompt_length
        self.lifecycle = (
            "full" if prompt_length == self.geometry.max_sequence_length else "valid_prefix"
        )

    def commit_append(self, *, position: int) -> None:
        self.validate_append(position=position)
        self.publish_append()

    def validate_append(self, *, position: int) -> None:
        if self.lifecycle == "empty":
            raise ValueError("append requires prefill")
        if self.lifecycle == "full" or self.logical_length >= self.geometry.max_sequence_length:
            raise ValueError("cache is full")
        if position != self.logical_length:
            raise ValueError(
                f"append position {position} must equal logical length {self.logical_length}"
            )

    def publish_append(self) -> None:
        self.logical_length += 1
        if self.logical_length == self.geometry.max_sequence_length:
            self.lifecycle = "full"

    def reset(self) -> None:
        self.logical_length = 0
        self.cache_generation += 1
        self.lifecycle = "empty"


class PersistentCache(Protocol):
    """Storage-neutral cache contract consumed by the decode graph."""

    @property
    def logical_length(self) -> int: ...

    def descriptor(self) -> dict: ...

    def prefill_quantized(
        self, qkey: object, k_scale: object, k_zero: object, qvalue: object, v_scale: object
    ) -> None: ...

    def append_quantized(
        self,
        qkey: object,
        k_scale: object,
        k_zero: object,
        qvalue: object,
        v_scale: object,
        *,
        position: int,
    ) -> None: ...

    def get_kv(self) -> tuple[tuple[object, ...], tuple[object, ...]]: ...

    def dequantized_kv(self) -> tuple[object, object]: ...


@dataclass(frozen=True)
class QuantSpec:
    bits: int
    signed: bool
    mode: str
    group_size: int
    group_axis: str
    scale_dtype: str
    zero_dtype: Optional[str]
    nibble_order: str = "low_first"

    def __post_init__(self) -> None:
        if self.bits != 4:
            raise ValueError("only 4-bit quantization is supported")
        if self.mode not in ("sym", "asym"):
            raise ValueError("quantization mode must be 'sym' or 'asym'")
        if self.mode == "asym" and self.zero_dtype is None:
            raise ValueError("asymmetric quantization requires a zero dtype")
        if self.nibble_order != "low_first":
            raise ValueError("only low-nibble-first packing is supported")


@dataclass(frozen=True)
class PhysicalSpec:
    layout: str
    padded_shape: Tuple[int, ...]
    strides: Tuple[int, ...]
    base_offset: int
    buffer_extent: int
    grouping: Optional[str] = None
    parameters: Tuple[Tuple[str, int], ...] = ()

    def __post_init__(self) -> None:
        if len(self.padded_shape) != len(self.strides):
            raise ValueError("padded_shape and strides must have equal rank")
        if any(dim <= 0 for dim in self.padded_shape):
            raise ValueError("physical dimensions must be positive")
        if any(stride <= 0 for stride in self.strides):
            raise ValueError("physical strides must be positive")
        addressed = self.base_offset + 1
        addressed += sum((dim - 1) * stride for dim, stride in zip(self.padded_shape, self.strides))
        if addressed > self.buffer_extent:
            raise ValueError(
                f"buffer extent {self.buffer_extent} is smaller than addressed extent {addressed}"
            )
        if len({name for name, _ in self.parameters}) != len(self.parameters):
            raise ValueError("physical parameter names must be unique")

    @classmethod
    def contiguous(
        cls,
        layout: str,
        shape: Tuple[int, ...],
        grouping: Optional[str] = None,
        parameters: Optional[Mapping[str, int]] = None,
    ):
        stride = 1
        strides = []
        for dim in reversed(shape):
            strides.append(stride)
            stride *= dim
        return cls(
            layout,
            shape,
            tuple(reversed(strides)),
            0,
            stride,
            grouping,
            tuple(sorted((parameters or {}).items())),
        )

    def parameter(self, name: str, default: Optional[int] = None) -> int:
        for key, value in self.parameters:
            if key == name:
                return value
        if default is None:
            raise KeyError(f"physical parameter {name!r} is not present")
        return default


@dataclass(frozen=True)
class TensorSpec:
    name: str
    axes: Tuple[str, ...]
    shape: Tuple[int, ...]
    dtype: str
    quant: Optional[QuantSpec] = None
    physical: Optional[PhysicalSpec] = None

    def __post_init__(self) -> None:
        if len(self.axes) != len(self.shape):
            raise ValueError("semantic axes and shape must have equal rank")
        if len(set(self.axes)) != len(self.axes):
            raise ValueError("semantic axes must be unique")

    def require_compatible(self, other: "TensorSpec") -> None:
        semantic = (self.axes, self.shape, self.dtype, self.quant)
        other_semantic = (other.axes, other.shape, other.dtype, other.quant)
        if semantic != other_semantic:
            raise ValueError(
                f"semantic tensor mismatch for {self.name}: {semantic!r} != {other_semantic!r}"
            )


@dataclass
class TensorHandle:
    spec: TensorSpec
    value: object
    producer: str
    attachments: dict[str, object] = field(default_factory=dict, repr=False)
