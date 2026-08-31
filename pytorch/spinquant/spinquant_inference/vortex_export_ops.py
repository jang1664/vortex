"""Functional logical Vortex INT4 operators for eager execution and export.

These operators intentionally describe tensor meaning, not a Vortex physical
layout.  TVM selects the naive row-major or improved hierarchical backend
after importing the exported program.
"""

from __future__ import annotations

import math

import torch


_SCHEMES = {"signed_symmetric_int4", "signed_asymmetric_int4"}


def _normalize_axis(axis: int, ndim: int, name: str) -> int:
    normalized = axis + ndim if axis < 0 else axis
    if normalized < 0 or normalized >= ndim:
        raise ValueError(f"{name}={axis} is out of range for rank-{ndim} tensor")
    return normalized


def _validate_scheme(scheme: str) -> None:
    if scheme not in _SCHEMES:
        raise ValueError(f"unsupported INT4 quantization scheme {scheme!r}")


def _qparam_shape(
    shape: tuple[int, ...], quant_axis: int, group_size: int
) -> tuple[int, ...]:
    result = list(shape)
    result[quant_axis] = math.ceil(shape[quant_axis] / group_size)
    return tuple(result)


def _packed_shape(shape: tuple[int, ...], pack_axis: int) -> tuple[int, ...]:
    result = list(shape)
    result[pack_axis] = math.ceil(shape[pack_axis] / 2)
    return tuple(result)


def _validate_quant_args(
    x: torch.Tensor, quant_axis: int, group_size: int, pack_axis: int, scheme: str
):
    if x.dtype not in (torch.float16, torch.float32, torch.bfloat16):
        raise TypeError(f"quantize_int4 input must be floating point, got {x.dtype}")
    if x.ndim == 0:
        raise ValueError("quantize_int4 input must have rank at least one")
    if group_size <= 0:
        raise ValueError(f"group_size must be positive, got {group_size}")
    quant_axis = _normalize_axis(quant_axis, x.ndim, "quant_axis")
    pack_axis = _normalize_axis(pack_axis, x.ndim, "pack_axis")
    _validate_scheme(scheme)
    return quant_axis, pack_axis


def _pack_signed_int4(values: torch.Tensor, pack_axis: int) -> torch.Tensor:
    values = values.movedim(pack_axis, -1)
    if values.shape[-1] % 2:
        values = torch.nn.functional.pad(values, (0, 1))
    pairs = values.to(torch.int16).reshape(*values.shape[:-1], -1, 2) & 0xF
    packed = (pairs[..., 0] | (pairs[..., 1] << 4)).to(torch.uint8)
    return packed.movedim(-1, pack_axis)


def _unpack_signed_int4(
    packed: torch.Tensor, logical_shape: list[int], pack_axis: int
) -> torch.Tensor:
    if packed.dtype != torch.uint8:
        raise TypeError(
            f"packed INT4 payload must use uint8 storage, got {packed.dtype}"
        )
    shape = tuple(int(value) for value in logical_shape)
    if any(value <= 0 for value in shape):
        raise ValueError(f"logical_shape must be positive, got {shape}")
    if packed.ndim != len(shape):
        raise ValueError("packed payload rank does not match logical_shape")
    pack_axis = _normalize_axis(pack_axis, len(shape), "pack_axis")
    if tuple(packed.shape) != _packed_shape(shape, pack_axis):
        raise ValueError(
            f"packed payload shape {tuple(packed.shape)} does not match logical shape {shape}"
        )
    payload = packed.movedim(pack_axis, -1).to(torch.int16)
    low = payload & 0xF
    high = (payload >> 4) & 0xF
    low = low - (low >= 8).to(torch.int16) * 16
    high = high - (high >= 8).to(torch.int16) * 16
    unpacked = torch.stack((low, high), dim=-1).flatten(-2)
    unpacked = unpacked[..., : shape[pack_axis]].to(torch.int8)
    return unpacked.movedim(-1, pack_axis)


def _quantize_reference(
    x: torch.Tensor,
    quant_axis: int,
    group_size: int,
    pack_axis: int,
    scheme: str,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    quant_axis, pack_axis = _validate_quant_args(
        x, quant_axis, group_size, pack_axis, scheme
    )
    if not torch.isfinite(x).all():
        raise ValueError("quantize_int4 v1 requires finite input values")
    moved = x.float().movedim(quant_axis, -1)
    logical_extent = moved.shape[-1]
    group_count = math.ceil(logical_extent / group_size)
    padded_extent = group_count * group_size
    if padded_extent != logical_extent:
        moved = torch.nn.functional.pad(moved, (0, padded_extent - logical_extent))
    groups = moved.reshape(*moved.shape[:-1], group_count, group_size)
    real = torch.arange(padded_extent, device=x.device).reshape(group_count, group_size)
    real = real < logical_extent
    positive_inf = torch.tensor(float("inf"), device=x.device)
    negative_inf = torch.tensor(float("-inf"), device=x.device)
    minimum = torch.where(real, groups, positive_inf).amin(dim=-1)
    maximum = torch.where(real, groups, negative_inf).amax(dim=-1)

    if scheme == "signed_symmetric_int4":
        scale = torch.maximum(minimum.abs(), maximum.abs()) / 7.0
        scale = torch.where(scale == 0, torch.ones_like(scale), scale)
        zero = torch.zeros_like(scale, dtype=torch.int16)
    else:
        minimum = torch.minimum(minimum, torch.zeros_like(minimum))
        maximum = torch.maximum(maximum, torch.zeros_like(maximum))
        scale = (maximum - minimum) / 15.0
        constant = scale == 0
        scale = torch.where(constant, torch.ones_like(scale), scale)
        zero = torch.where(
            constant,
            torch.zeros_like(scale),
            (torch.round(-minimum / scale) - 8.0).clamp(-8, 7),
        ).to(torch.int16)

    # FP16 scale is the physical contract.  Freeze rounding against the value
    # that is actually stored and consumed, rather than an unobservable FP32
    # temporary that can select a different INT4 code at a tie boundary.
    scale = scale.to(torch.float16)
    quantized = torch.round(
        groups / scale.float().unsqueeze(-1)
    ) + zero.float().unsqueeze(-1)
    quantized = quantized.clamp(-8, 7).reshape(*moved.shape[:-1], padded_extent)
    quantized = quantized[..., :logical_extent].to(torch.int8).movedim(-1, quant_axis)
    scale = scale.movedim(-1, quant_axis)
    zero = zero.movedim(-1, quant_axis)
    return _pack_signed_int4(quantized, pack_axis), scale, zero


def _dequantize_reference(
    packed: torch.Tensor,
    scale: torch.Tensor,
    zero_point: torch.Tensor,
    logical_shape: list[int],
    quant_axis: int,
    group_size: int,
    pack_axis: int,
    scheme: str,
) -> torch.Tensor:
    shape = tuple(int(value) for value in logical_shape)
    if group_size <= 0:
        raise ValueError(f"group_size must be positive, got {group_size}")
    quant_axis = _normalize_axis(quant_axis, len(shape), "quant_axis")
    pack_axis = _normalize_axis(pack_axis, len(shape), "pack_axis")
    _validate_scheme(scheme)
    expected_qparams = _qparam_shape(shape, quant_axis, group_size)
    if scale.dtype != torch.float16 or tuple(scale.shape) != expected_qparams:
        raise ValueError("scale must be FP16 with the logical grouped shape")
    if zero_point.dtype != torch.int16 or tuple(zero_point.shape) != expected_qparams:
        raise ValueError("zero_point must be INT16 with the logical grouped shape")
    if scheme == "signed_symmetric_int4" and torch.count_nonzero(zero_point):
        raise ValueError("symmetric INT4 requires explicit zero INT16 zero-points")
    values = _unpack_signed_int4(packed, list(shape), pack_axis).float()
    groups = torch.div(
        torch.arange(shape[quant_axis], device=packed.device),
        group_size,
        rounding_mode="floor",
    )
    expanded_scale = torch.index_select(scale.float(), quant_axis, groups)
    expanded_zero = torch.index_select(zero_point.float(), quant_axis, groups)
    return ((values - expanded_zero) * expanded_scale).to(torch.float16)


@torch.library.custom_op("vortex::quantize_int4", mutates_args=())
def quantize_int4(
    x: torch.Tensor,
    quant_axis: int,
    group_size: int,
    pack_axis: int,
    quant_scheme: str,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    return _quantize_reference(x, quant_axis, group_size, pack_axis, quant_scheme)


@quantize_int4.register_fake
def _quantize_int4_fake(x, quant_axis, group_size, pack_axis, quant_scheme):
    quant_axis, pack_axis = _validate_quant_args(
        x, quant_axis, group_size, pack_axis, quant_scheme
    )
    packed = x.new_empty(_packed_shape(tuple(x.shape), pack_axis), dtype=torch.uint8)
    qparam_shape = _qparam_shape(tuple(x.shape), quant_axis, group_size)
    scale = x.new_empty(qparam_shape, dtype=torch.float16)
    zero = x.new_empty(qparam_shape, dtype=torch.int16)
    return packed, scale, zero


@torch.library.custom_op("vortex::dequantize_int4", mutates_args=())
def dequantize_int4(
    packed: torch.Tensor,
    scale: torch.Tensor,
    zero_point: torch.Tensor,
    logical_shape: list[int],
    quant_axis: int,
    group_size: int,
    pack_axis: int,
    quant_scheme: str,
) -> torch.Tensor:
    return _dequantize_reference(
        packed,
        scale,
        zero_point,
        logical_shape,
        quant_axis,
        group_size,
        pack_axis,
        quant_scheme,
    )


@dequantize_int4.register_fake
def _dequantize_int4_fake(
    packed,
    scale,
    zero_point,
    logical_shape,
    quant_axis,
    group_size,
    pack_axis,
    quant_scheme,
):
    del packed, scale, zero_point, quant_axis, group_size, pack_axis
    _validate_scheme(quant_scheme)
    return torch.empty(tuple(logical_shape), dtype=torch.float16, device="meta")


def _validate_hadamard_args(
    hidden: torch.Tensor, base: torch.Tensor, base_size: int
) -> tuple[int, int]:
    if hidden.dtype != torch.float16 or hidden.ndim < 2:
        raise ValueError("hadamard input must be rank-2-or-higher FP16")
    if base.dtype != torch.float32 or base.ndim != 2:
        raise ValueError("hadamard base must be rank-2 FP32")
    width = hidden.shape[-1]
    if base_size <= 0 or width % base_size:
        raise ValueError("hadamard base_size must be a positive divisor of width")
    if tuple(base.shape) != (base_size, base_size):
        raise ValueError("hadamard base shape must match base_size")
    factor = width // base_size
    if factor & (factor - 1):
        raise ValueError("hadamard power-of-two factor is invalid")
    return width, factor


def _hadamard_reference(
    hidden: torch.Tensor, base: torch.Tensor, base_size: int
) -> torch.Tensor:
    """Mixed-radix FP32 Hadamard reference used by eager PyTorch."""

    width, factor = _validate_hadamard_args(hidden, base, base_size)
    work = hidden.float().reshape(-1, base_size, factor)
    stride = 1
    while stride < factor:
        grouped = work.reshape(work.shape[0], base_size, -1, 2, stride)
        left = grouped[..., 0, :]
        right = grouped[..., 1, :]
        work = torch.cat((left + right, left - right), dim=-1).reshape_as(work)
        stride *= 2
    if base_size > 1:
        work = torch.matmul(base.reshape(1, base_size, base_size), work)
    return (work.reshape_as(hidden) / math.sqrt(width)).to(hidden.dtype)


@torch.library.custom_op("vortex::hadamard", mutates_args=())
def hadamard(hidden: torch.Tensor, base: torch.Tensor, base_size: int) -> torch.Tensor:
    return _hadamard_reference(hidden, base, base_size)


@hadamard.register_fake
def _hadamard_fake(hidden, base, base_size):
    _validate_hadamard_args(hidden, base, base_size)
    return hidden.new_empty(hidden.shape)


def _validate_causal_softmax_args(
    scores: torch.Tensor,
    position_ids: torch.Tensor,
    valid_length: torch.Tensor,
    head_dim: int,
) -> None:
    if scores.dtype != torch.float16 or scores.ndim != 5:
        raise ValueError("causal_softmax scores must be rank-5 FP16")
    if position_ids.dtype != torch.int64 or position_ids.ndim != 2:
        raise ValueError("causal_softmax position_ids must be rank-2 INT64")
    if tuple(position_ids.shape) != (scores.shape[0], scores.shape[-2]):
        raise ValueError(
            "causal_softmax position_ids must match the batch and query extents"
        )
    if valid_length.dtype != torch.int64 or valid_length.numel() != 1:
        raise ValueError("causal_softmax valid_length must be one INT64 scalar")
    if head_dim <= 0:
        raise ValueError("causal_softmax head_dim must be positive")


@torch.library.custom_op("vortex::causal_softmax", mutates_args=())
def causal_softmax(
    scores: torch.Tensor,
    position_ids: torch.Tensor,
    valid_length: torch.Tensor,
    head_dim: int,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Apply scaled causal masking and softmax to rank-5 GQA scores."""

    _validate_causal_softmax_args(scores, position_ids, valid_length, head_dim)
    scaled_scores = scores.float() / math.sqrt(head_dim)
    key_positions = torch.arange(
        scores.shape[-1], device=scores.device, dtype=torch.int64
    )
    valid = key_positions.reshape(1, 1, 1, 1, -1) < valid_length.reshape(
        1, 1, 1, 1, 1
    )
    causal = key_positions.reshape(1, 1, 1, 1, -1) <= position_ids.reshape(
        scores.shape[0], 1, 1, scores.shape[-2], 1
    )
    masked_scores = torch.where(
        valid & causal,
        scaled_scores,
        torch.full_like(scaled_scores, float("-inf")),
    )
    probabilities = torch.softmax(masked_scores, dim=-1).to(torch.float16)
    return masked_scores, probabilities


@causal_softmax.register_fake
def _causal_softmax_fake(scores, position_ids, valid_length, head_dim):
    _validate_causal_softmax_args(scores, position_ids, valid_length, head_dim)
    return (
        scores.new_empty(scores.shape, dtype=torch.float32),
        scores.new_empty(scores.shape, dtype=torch.float16),
    )


@torch.library.custom_op("vortex::mm_w4a16", mutates_args=())
def mm_w4a16(
    lhs: torch.Tensor,
    rhs_packed: torch.Tensor,
    scales: torch.Tensor,
    zero_points: torch.Tensor,
    rhs_logical_shape: list[int],
    group_size: int,
    quant_axis: int,
    pack_axis: int,
    quant_scheme: str,
    transpose_rhs: bool,
) -> torch.Tensor:
    rhs = _dequantize_reference(
        rhs_packed,
        scales,
        zero_points,
        rhs_logical_shape,
        quant_axis,
        group_size,
        pack_axis,
        quant_scheme,
    )
    logical_rhs = rhs.transpose(-2, -1) if transpose_rhs else rhs
    if lhs.dtype != torch.float16:
        raise TypeError(f"mm_w4a16 lhs must be FP16, got {lhs.dtype}")
    return torch.matmul(lhs.float(), logical_rhs.float()).to(torch.float16)


@mm_w4a16.register_fake
def _mm_w4a16_fake(
    lhs,
    rhs_packed,
    scales,
    zero_points,
    rhs_logical_shape,
    group_size,
    quant_axis,
    pack_axis,
    quant_scheme,
    transpose_rhs,
):
    del rhs_packed, scales, zero_points, group_size, quant_axis, pack_axis
    _validate_scheme(quant_scheme)
    rhs_shape = tuple(rhs_logical_shape)
    if len(rhs_shape) < 2 or lhs.ndim < 2:
        raise ValueError("mm_w4a16 operands must have rank at least two")
    k = rhs_shape[-1] if transpose_rhs else rhs_shape[-2]
    n = rhs_shape[-2] if transpose_rhs else rhs_shape[-1]
    if lhs.shape[-1] != k:
        raise ValueError(f"mm_w4a16 K mismatch: lhs={lhs.shape[-1]}, rhs={k}")
    return lhs.new_empty((*lhs.shape[:-1], n), dtype=torch.float16)


@torch.library.custom_op("vortex::mm_w4a16_prepacked", mutates_args=())
def mm_w4a16_prepacked(
    lhs: torch.Tensor,
    rhs_tiled: torch.Tensor,
    scales_tiled: torch.Tensor,
    zero_points_tiled: torch.Tensor,
    rhs_logical_shape: list[int],
    group_size: int,
    quant_axis: int,
    pack_axis: int,
    quant_scheme: str,
    transpose_rhs: bool,
) -> torch.Tensor:
    del (
        rhs_tiled,
        scales_tiled,
        zero_points_tiled,
        group_size,
        quant_axis,
        pack_axis,
        quant_scheme,
    )
    rhs_shape = tuple(rhs_logical_shape)
    n = rhs_shape[-2] if transpose_rhs else rhs_shape[-1]
    return lhs.new_zeros((*lhs.shape[:-1], n), dtype=torch.float16)


@mm_w4a16_prepacked.register_fake
def _mm_w4a16_prepacked_fake(
    lhs,
    rhs_tiled,
    scales_tiled,
    zero_points_tiled,
    rhs_logical_shape,
    group_size,
    quant_axis,
    pack_axis,
    quant_scheme,
    transpose_rhs,
):
    if lhs.dtype != torch.float16 or lhs.ndim < 2:
        raise ValueError("prepacked W4A16 lhs must be rank-2-or-higher FP16")
    if rhs_tiled.dtype != torch.uint8 or rhs_tiled.ndim != 1:
        raise ValueError("prepacked W4A16 weight must be flat uint8")
    if scales_tiled.dtype != torch.float16 or scales_tiled.ndim != 1:
        raise ValueError("prepacked W4A16 scale must be flat FP16")
    if zero_points_tiled.dtype != torch.int16 or zero_points_tiled.ndim != 1:
        raise ValueError("prepacked W4A16 zero point must be flat INT16")
    if scales_tiled.shape != zero_points_tiled.shape:
        raise ValueError("prepacked W4A16 qparam buffers must have equal shapes")
    del rhs_tiled, scales_tiled, zero_points_tiled, group_size, quant_axis, pack_axis
    _validate_scheme(quant_scheme)
    rhs_shape = tuple(rhs_logical_shape)
    k = rhs_shape[-1] if transpose_rhs else rhs_shape[-2]
    n = rhs_shape[-2] if transpose_rhs else rhs_shape[-1]
    if lhs.shape[-1] != k:
        raise ValueError(f"prepacked W4A16 K mismatch: lhs={lhs.shape[-1]}, rhs={k}")
    return lhs.new_empty((*lhs.shape[:-1], n), dtype=torch.float16)


@torch.library.custom_op("vortex::kv_cache_update", mutates_args=())
def kv_cache_update(
    cache_payload: torch.Tensor,
    cache_scale: torch.Tensor,
    cache_zero_point: torch.Tensor,
    payload: torch.Tensor,
    scale: torch.Tensor,
    zero_point: torch.Tensor,
    position: int,
    capacity: int,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    if position < 0 or position >= capacity:
        raise ValueError(f"cache position {position} is outside capacity {capacity}")
    outputs = [
        tensor.clone() for tensor in (cache_payload, cache_scale, cache_zero_point)
    ]
    for output, update in zip(outputs, (payload, scale, zero_point)):
        if output.shape[-2] != capacity or update.shape[-2] != 1:
            raise ValueError(
                "kv_cache_update uses the penultimate dimension as sequence"
            )
        output[..., position : position + 1, :].copy_(update)
    return tuple(outputs)


@kv_cache_update.register_fake
def _kv_cache_update_fake(
    cache_payload,
    cache_scale,
    cache_zero_point,
    payload,
    scale,
    zero_point,
    position,
    capacity,
):
    del payload, scale, zero_point, position, capacity
    return (
        torch.empty_like(cache_payload),
        torch.empty_like(cache_scale),
        torch.empty_like(cache_zero_point),
    )


def _validate_cache_position_tensor(position: torch.Tensor) -> None:
    if position.dtype != torch.int64 or position.numel() != 1:
        raise ValueError("cache position must be one scalar INT64 tensor")


@torch.library.custom_op("vortex::kv_cache_update_dynamic", mutates_args=())
def kv_cache_update_dynamic(
    cache_payload: torch.Tensor,
    cache_scale: torch.Tensor,
    cache_zero_point: torch.Tensor,
    payload: torch.Tensor,
    scale: torch.Tensor,
    zero_point: torch.Tensor,
    position: torch.Tensor,
    capacity: int,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    _validate_cache_position_tensor(position)
    index = int(position.item())
    if index < 0 or index >= capacity:
        raise ValueError(f"cache position {index} is outside capacity {capacity}")
    outputs = [
        tensor.clone() for tensor in (cache_payload, cache_scale, cache_zero_point)
    ]
    for output, update in zip(outputs, (payload, scale, zero_point)):
        if output.shape[-2] != capacity or update.shape[-2] != 1:
            raise ValueError(
                "kv_cache_update_dynamic uses the penultimate dimension as sequence"
            )
        output[..., index : index + 1, :].copy_(update)
    return tuple(outputs)


@kv_cache_update_dynamic.register_fake
def _kv_cache_update_dynamic_fake(
    cache_payload,
    cache_scale,
    cache_zero_point,
    payload,
    scale,
    zero_point,
    position,
    capacity,
):
    del payload, scale, zero_point, capacity
    _validate_cache_position_tensor(position)
    return (
        torch.empty_like(cache_payload),
        torch.empty_like(cache_scale),
        torch.empty_like(cache_zero_point),
    )
