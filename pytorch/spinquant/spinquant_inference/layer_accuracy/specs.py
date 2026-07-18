"""Typed semantic and physical tensor contracts used by all backends."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from functools import reduce
from operator import mul
from typing import Mapping, Optional, Tuple


@dataclass(frozen=True)
class LayerConfig:
    model: str = "llama2-7b"
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

    def __post_init__(self) -> None:
        if self.hidden_size != self.num_attention_heads * self.head_dim:
            raise ValueError("hidden_size must equal num_attention_heads * head_dim")
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

    @classmethod
    def from_dict(cls, value: dict) -> "LayerConfig":
        return cls(**value)


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
