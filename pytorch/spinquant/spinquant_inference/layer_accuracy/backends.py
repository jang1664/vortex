"""Reference and Vortex physical backends for the semantic layer graph."""

from __future__ import annotations

import math
import os
from dataclasses import asdict, dataclass
from typing import Dict, Iterable, Optional, Sequence

import torch
import torch.nn.functional as F

from ..utils.hadamard_utils import get_hadK
from ..modeling.quantized_kv_cache import FixedCapacityKVQuantizedCache
from .artifacts import DecodeCase, LayerCase
from .specs import (
    CacheGeometry,
    CacheState,
    DecodeConfig,
    LayerConfig,
    PersistentCache,
    PhysicalSpec,
    TensorHandle,
    TensorSpec,
)
from .tensor_io import dequantize_weight, pack_signed_int4, unpack_signed_int4


TILE_M = 128
TILE_K = 128
TILE_KN = 32


@dataclass(frozen=True)
class DeferredScaledMaskedScores:
    """Semantic score stage whose scale/mask are fused into the next kernel."""

    qk: object
    head_dim: int


def _physical_parameters(handle: TensorHandle) -> dict[str, int]:
    physical = handle.spec.physical
    assert physical is not None
    return dict(physical.parameters)


def _decode_gemm_matrix(
    storage: torch.Tensor,
    *,
    m: int,
    m_pad: int,
    n: int,
) -> torch.Tensor:
    """Decode the common C4 GEMM-A/C tile order on CPU.

    Both A and C use the same 128-row outer tile and 32-column micro-tile
    address function.  Naming the second dimension K or N is semantic only.
    """
    flat = storage.reshape(-1)
    decoded = []
    offset = 0
    for mt_start in range(0, m_pad, TILE_M):
        cm = min(m_pad - mt_start, TILE_M)
        extent = cm * n
        matrix = (
            flat[offset:offset + extent]
            .reshape(n // TILE_KN, cm, TILE_KN)
            .permute(1, 0, 2)
            .contiguous()
            .reshape(cm, n)
        )
        decoded.append(matrix)
        offset += extent
    if len(decoded) == 1:
        return decoded[0][:m]
    return torch.cat(decoded, dim=0)[:m]


def _decode_gemm_weight_values(
    storage: torch.Tensor,
    *,
    k: int,
    n: int,
    wtrans: int,
) -> torch.Tensor:
    """Decode a packed signed-int4 GEMM-W buffer to semantic INT8 values."""
    raw = storage.detach().cpu().view(torch.uint8).reshape(-1)
    unpacked = torch.empty((k, n), dtype=torch.int8)
    k_tile = 128
    for row in range(k):
        kt = row // k_tile
        kt_start = kt * k_tile
        cur_k = min(k - kt_start, k_tile)
        local_k = row - kt_start
        kb, k0 = divmod(local_k, TILE_KN)
        for column in range(n):
            nt, n0 = divmod(column, TILE_KN)
            if wtrans == 0:
                offset = (
                    kt * k_tile * (n // 2)
                    + nt * cur_k * (TILE_KN // 2)
                    + (kb * TILE_KN + k0) * (TILE_KN // 2)
                    + n0 // 2
                )
                nibble = int(raw[offset]) >> (4 if n0 & 1 else 0)
            else:
                offset = (
                    kt * k_tile * (n // 2)
                    + nt * cur_k * (TILE_KN // 2)
                    + kb * TILE_KN * (TILE_KN // 2)
                    + n0 * (TILE_KN // 2)
                    + k0 // 2
                )
                nibble = int(raw[offset]) >> (4 if k0 & 1 else 0)
            nibble &= 0xF
            unpacked[row, column] = nibble - 16 if nibble >= 8 else nibble
    return unpacked


def _decode_packed_gemm_weight(
    storage: torch.Tensor,
    *,
    k: int,
    n: int,
    wtrans: int,
) -> torch.Tensor:
    """Decode a GEMM-W buffer and pack pairs along its physical N axis."""
    return pack_signed_int4(
        _decode_gemm_weight_values(storage, k=k, n=n, wtrans=wtrans)
    )


def decode_physical_tensor(handle: TensorHandle) -> torch.Tensor:
    """Return a semantic CPU tensor without launching a Vortex layout op."""
    if handle.spec.physical is None:
        return handle.value.detach().cpu().reshape(handle.spec.shape).contiguous()
    physical = handle.spec.physical
    values = handle.value if isinstance(handle.value, tuple) else (handle.value,)
    storages = tuple(value.detach().cpu().contiguous() for value in values)
    storage = storages[0]
    params = _physical_parameters(handle)
    if physical.layout == "grouped_row":
        return torch.stack([value.reshape(params["rows"], params["columns"])
                            for value in storages]).reshape(handle.spec.shape).contiguous()
    if physical.layout == "grouped_prefix_row":
        active = params["logical_rows"]
        return torch.stack([
            value.reshape(params["rows"], params["columns"])[:active]
            for value in storages
        ]).reshape(handle.spec.shape).contiguous()
    if physical.layout == "gemm_w_packed_grouped":
        packed = []
        for value in storages:
            matrix = _decode_gemm_weight_values(
                value,
                k=params["weight_k"],
                n=params["weight_n"],
                wtrans=params["wtrans"],
            )
            if params.get("source_transposed", 0):
                matrix = matrix.transpose(0, 1).contiguous()
            matrix = matrix[
                :handle.spec.shape[-2], :handle.spec.shape[-1] * 2
            ].contiguous()
            packed.append(pack_signed_int4(matrix))
        return torch.stack(packed).reshape(handle.spec.shape).contiguous()
    if physical.layout in ("row_major", "bhsd_row", "packed_row"):
        return storage.reshape(handle.spec.shape).contiguous()
    if physical.layout in ("gemm_a_tiled", "gemm_c_tiled"):
        matrix_count = params.get("matrix_count", 1)
        m = params["m"]
        m_pad = params["m_pad"]
        n = params["n"]
        n_pad = params.get("n_pad", n)
        matrix_extent = m_pad * n_pad
        flat = storage.reshape(-1)
        decoded = [
            _decode_gemm_matrix(
                flat[index * matrix_extent:(index + 1) * matrix_extent],
                m=m,
                m_pad=m_pad,
                n=n_pad,
            )[:, :n]
            for index in range(matrix_count)
        ]
        if matrix_count == 1:
            return decoded[0].reshape(handle.spec.shape).contiguous()
        return torch.stack(decoded).reshape(handle.spec.shape).contiguous()
    if physical.layout == "gemm_w_packed":
        return _decode_packed_gemm_weight(
            storage,
            k=params["k"],
            n=params["n"],
            wtrans=params["wtrans"],
        ).reshape(handle.spec.shape)
    raise ValueError(f"unsupported physical layout {physical.layout!r}")


def _make_handle(
    value: torch.Tensor,
    *,
    name: str,
    axes: Sequence[str],
    shape: Sequence[int],
    layout: str,
    padded_shape: Sequence[int],
    producer: str,
    grouping: Optional[str] = None,
    **parameters: int,
) -> TensorHandle:
    spec = TensorSpec(
        name=name,
        axes=tuple(axes),
        shape=tuple(shape),
        dtype=str(value.dtype).removeprefix("torch."),
        physical=PhysicalSpec.contiguous(
            layout,
            tuple(padded_shape),
            grouping=grouping,
            parameters=parameters,
        ),
    )
    return TensorHandle(spec=spec, value=value, producer=producer)


def _make_grouped_handle(
    values: Sequence[torch.Tensor],
    **kwargs,
) -> TensorHandle:
    handle = _make_handle(values[0], **kwargs)
    handle.value = tuple(values)
    return handle


@dataclass
class QuantizedActivation:
    packed: object
    scale: object
    zero: Optional[object]
    mode: str
    logical_shape: tuple[int, ...]
    unpacked: Optional[torch.Tensor] = None
    weight_tiled: Optional[object] = None
    scale_tiled: Optional[object] = None
    zero_tiled: Optional[object] = None
    dequantized: Optional[torch.Tensor] = None


class Backend:
    """Backend interface. The graph owns semantics; the backend owns storage/layout."""

    name = "abstract"

    def bind(self, case: LayerCase | DecodeCase) -> None:
        self.case = case

    @property
    def layer_config(self) -> LayerConfig:
        config = self.case.config
        return config.layer if isinstance(config, DecodeConfig) else config

    def preflight(self, case: LayerCase, stop_after: str) -> None:
        del case, stop_after

    def tensor(self, name: str) -> torch.Tensor:
        raise NotImplementedError

    def activate(
        self,
        input_tensor: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
    ) -> None:
        raise NotImplementedError

    def create_persistent_cache(self, config: DecodeConfig) -> PersistentCache:
        raise NotImplementedError

    def rms_norm(self, x: object, weight_name: str, eps: float) -> object:
        raise NotImplementedError

    def linear(self, name: str, x: object) -> object:
        raise NotImplementedError

    def split_heads(self, x: object) -> object:
        raise NotImplementedError

    def rope(self, x: object) -> object:
        raise NotImplementedError

    def hadamard(self, x: torch.Tensor) -> torch.Tensor:
        raise NotImplementedError

    def quantize(self, x: torch.Tensor, mode: str) -> QuantizedActivation:
        raise NotImplementedError

    def quantized_capture(self, value: QuantizedActivation) -> torch.Tensor:
        raise NotImplementedError

    def qk(self, q: torch.Tensor, k: QuantizedActivation) -> torch.Tensor:
        raise NotImplementedError

    def scaled_masked_scores(self, qk: torch.Tensor, head_dim: int) -> torch.Tensor:
        raise NotImplementedError

    def softmax(self, scores: torch.Tensor) -> torch.Tensor:
        raise NotImplementedError

    def pv(self, probabilities: torch.Tensor, v: QuantizedActivation) -> torch.Tensor:
        raise NotImplementedError

    def head_concat(self, value: torch.Tensor) -> torch.Tensor:
        raise NotImplementedError

    def silu(self, value: torch.Tensor) -> torch.Tensor:
        raise NotImplementedError

    def add(self, lhs: torch.Tensor, rhs: torch.Tensor) -> torch.Tensor:
        raise NotImplementedError

    def mul(self, lhs: torch.Tensor, rhs: torch.Tensor) -> torch.Tensor:
        raise NotImplementedError

    def canonicalize(self, value: object) -> torch.Tensor:
        if isinstance(value, TensorHandle):
            return decode_physical_tensor(value)
        return value.detach().cpu().contiguous()

    def capture_physical(self, value: object) -> tuple[tuple[torch.Tensor, ...], dict]:
        if isinstance(value, DeferredScaledMaskedScores):
            return self.capture_physical(value.qk)
        if isinstance(value, TensorHandle):
            raw_values = value.value if isinstance(value.value, tuple) else (value.value,)
            buffers = tuple(tensor.detach().cpu().contiguous() for tensor in raw_values)
            return buffers, {
                "producer": value.producer,
                "tensor_spec": asdict(value.spec),
            }
        tensor = value.detach().cpu().contiguous()
        return (tensor,), {
            "producer": "semantic_tensor",
            "tensor_spec": {
                "shape": list(tensor.shape),
                "dtype": str(tensor.dtype).removeprefix("torch."),
                "physical": {"layout": "row_major"},
            },
        }

    def placement_report(self) -> dict:
        return {"backend": self.name, "strict_native": False, "physical_steps": []}


class TorchBackend(Backend):
    """Naive, explicit PyTorch implementation used by CPU tests and CUDA reference."""

    name = "torch"

    def __init__(self, device: str | torch.device = "cuda") -> None:
        self.device = torch.device(device)
        self._tensors: Dict[str, torch.Tensor] = {}
        self._weights: Dict[str, torch.Tensor] = {}

    def bind(self, case: LayerCase | DecodeCase) -> None:
        super().bind(case)
        if self.device.type == "cuda":
            if not torch.cuda.is_available():
                raise RuntimeError("CUDA backend requested but torch.cuda.is_available() is false")
            torch.backends.cuda.matmul.allow_tf32 = False
            torch.backends.cudnn.allow_tf32 = False
            torch.use_deterministic_algorithms(True)
        self._tensors = {name: tensor.to(self.device) for name, tensor in case.tensors.items()}
        self._weights.clear()

    def activate(
        self,
        input_tensor: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
    ) -> None:
        self._tensors["input"] = input_tensor.to(self.device)
        self._tensors["position_ids"] = position_ids.to(self.device)
        self._tensors["causal_mask"] = causal_mask.to(self.device)

    def create_persistent_cache(
        self, config: DecodeConfig
    ) -> FixedCapacityKVQuantizedCache:
        layer = config.layer
        return FixedCapacityKVQuantizedCache(
            batch_size=layer.batch_size,
            num_kv_heads=layer.num_attention_heads,
            head_dim=layer.head_dim,
            max_sequence_length=config.max_sequence_length,
            device=self.device,
        )

    def tensor(self, name: str) -> torch.Tensor:
        return self._tensors[name]

    def rms_norm(self, x: torch.Tensor, weight_name: str, eps: float) -> torch.Tensor:
        weight = self.tensor(weight_name)
        normalized = x.float() * torch.rsqrt(x.float().pow(2).mean(-1, keepdim=True) + eps)
        return (normalized * weight.float()).to(torch.float16)

    def _weight(self, name: str) -> torch.Tensor:
        cached = self._weights.get(name)
        if cached is None:
            cached = dequantize_weight(
                self.tensor(f"{name}.qweight"),
                self.tensor(f"{name}.scales"),
                self.layer_config.weight_group_size,
                dtype=torch.float16,
            )
            self._weights[name] = cached
        return cached

    def linear(self, name: str, x: torch.Tensor) -> torch.Tensor:
        shape = x.shape[:-1]
        result = torch.matmul(x.reshape(-1, x.shape[-1]), self._weight(name))
        return result.reshape(*shape, result.shape[-1]).to(torch.float16)

    def split_heads(self, x: torch.Tensor) -> torch.Tensor:
        config = self.layer_config
        return x.reshape(
            config.batch_size,
            x.shape[1],
            config.num_attention_heads,
            config.head_dim,
        ).transpose(1, 2).contiguous()

    def rope(self, x: torch.Tensor) -> torch.Tensor:
        positions = self.tensor("position_ids")
        table_shape = (*positions.shape, self.layer_config.head_dim)
        indices = positions.unsqueeze(-1).expand(table_shape)
        cos = self.tensor("rope_cos").gather(1, indices).unsqueeze(1).float()
        sin = self.tensor("rope_sin").gather(1, indices).unsqueeze(1).float()
        half = x.shape[-1] // 2
        rotated = torch.cat((-x[..., half:], x[..., :half]), dim=-1)
        return (x.float() * cos + rotated.float() * sin).to(torch.float16)

    def hadamard(self, x: torch.Tensor) -> torch.Tensor:
        n = x.shape[-1]
        had_k, k_base = get_hadK(n)
        original_dtype = x.dtype
        work = x.float().reshape(-1, n, 1).clone()
        while work.shape[1] > k_base:
            pairs = work.reshape(work.shape[0], work.shape[1] // 2, 2, work.shape[2])
            work = torch.cat((pairs[:, :, 0, :] + pairs[:, :, 1, :],
                              pairs[:, :, 0, :] - pairs[:, :, 1, :]), dim=-1)
        if k_base > 1:
            matrix = had_k.to(device=x.device, dtype=torch.float32).reshape(1, k_base, k_base)
            work = matrix @ work
        return (work.reshape(x.shape) / math.sqrt(n)).to(original_dtype)

    def quantize(self, x: torch.Tensor, mode: str) -> QuantizedActivation:
        if mode not in ("sym", "asym"):
            raise ValueError(f"unsupported KV quantization mode {mode!r}")
        values = x.float()
        if mode == "sym":
            scale = values.abs().amax(dim=-1, keepdim=True).clamp_min(1e-8) / 7.5
            zero = None
            quantized = torch.round(values / scale)
        else:
            minimum = values.amin(dim=-1, keepdim=True)
            maximum = values.amax(dim=-1, keepdim=True)
            scale = ((maximum - minimum) / 15.0).clamp_min(1e-8)
            zero = -8.0 - minimum / scale
            quantized = torch.round(values / scale + zero)
        quantized = quantized.clamp(-8, 7).to(torch.int8)
        return QuantizedActivation(
            packed=pack_signed_int4(quantized),
            scale=scale.to(torch.float16),
            zero=None if zero is None else zero.to(torch.float16),
            mode=mode,
            logical_shape=tuple(x.shape),
            unpacked=quantized,
        )

    def _dequantize(self, value: QuantizedActivation) -> torch.Tensor:
        if value.dequantized is not None:
            return value.dequantized
        q = value.unpacked
        if q is None:
            q = unpack_signed_int4(value.packed)
        qf = q.float()
        if value.mode == "asym":
            assert value.zero is not None
            qf = qf - value.zero.float()
        return (qf * value.scale.float()).to(torch.float16)

    def quantized_capture(self, value: QuantizedActivation) -> torch.Tensor:
        return self._dequantize(value)

    def qk(self, q: torch.Tensor, k: QuantizedActivation) -> torch.Tensor:
        return torch.matmul(q, self._dequantize(k).transpose(-1, -2)).to(torch.float16)

    def scaled_masked_scores(self, qk: torch.Tensor, head_dim: int) -> torch.Tensor:
        return (qk.float() / math.sqrt(head_dim) + self.tensor("causal_mask").float()).to(torch.float16)

    def softmax(self, scores: torch.Tensor) -> torch.Tensor:
        return torch.softmax(scores.float(), dim=-1).to(torch.float16)

    def pv(self, probabilities: torch.Tensor, v: QuantizedActivation) -> torch.Tensor:
        return torch.matmul(probabilities, self._dequantize(v)).to(torch.float16)

    def head_concat(self, value: torch.Tensor) -> torch.Tensor:
        batch, heads, sequence, head_dim = value.shape
        return value.transpose(1, 2).contiguous().reshape(batch, sequence, heads * head_dim)

    def silu(self, value: torch.Tensor) -> torch.Tensor:
        return F.silu(value.float()).to(torch.float16)

    def add(self, lhs: torch.Tensor, rhs: torch.Tensor) -> torch.Tensor:
        return (lhs.float() + rhs.float()).to(torch.float16)

    def mul(self, lhs: torch.Tensor, rhs: torch.Tensor) -> torch.Tensor:
        return (lhs.float() * rhs.float()).to(torch.float16)

    def placement_report(self) -> dict:
        return {
            "backend": "cuda" if self.device.type == "cuda" else "cpu",
            "strict_native": False,
            "device": str(self.device),
            "physical_steps": [],
        }


class _LayoutPlan:
    name = "abstract"
    required_ops: tuple[str, ...] = ()

    def __init__(self, backend: "VortexBackend") -> None:
        self.backend = backend

    def rms_norm(self, x, weight_name: str, eps: float):
        raise NotImplementedError

    def linear(self, name: str, x):
        raise NotImplementedError

    def split_heads(self, x):
        raise NotImplementedError

    def rope(self, x):
        raise NotImplementedError

    def hadamard(self, x):
        raise NotImplementedError

    def quantize(self, x, mode: str):
        raise NotImplementedError

    def qk(self, q, k):
        raise NotImplementedError

    def scaled_masked_scores(self, qk, head_dim: int):
        raise NotImplementedError

    def softmax(self, scores):
        raise NotImplementedError

    def pv(self, probabilities, v):
        raise NotImplementedError

    def head_concat(self, value):
        raise NotImplementedError

    def add(self, lhs, rhs):
        raise NotImplementedError


class StandaloneLayoutPlan(_LayoutPlan):
    name = "standalone"
    required_ops = (
        "apply_rotary_pos_emb",
        "tile_weight_w4a16_ex",
        "tile_scale_zp_w4a16_ex",
        "quantize_pack_per_token",
        "qk_asym_correction",
        "head_concat",
        "tile_input_a",
        "hadamard_butterfly",
        "hadamard_base",
    )

    def rms_norm(self, x, weight_name: str, eps: float):
        return self.backend._standalone_rms_norm(x, weight_name, eps)

    def linear(self, name: str, x):
        return self.backend._standalone_linear(name, x)

    def split_heads(self, x):
        return self.backend._standalone_split_heads(x)

    def rope(self, x):
        return self.backend._standalone_rope(x)

    def hadamard(self, x):
        return self.backend._standalone_hadamard(x)

    def quantize(self, x, mode: str):
        return self.backend._standalone_quantize(x, mode)

    def qk(self, q, k):
        return self.backend._standalone_qk(q, k)

    def scaled_masked_scores(self, qk, head_dim: int):
        return self.backend._standalone_scaled_masked_scores(qk, head_dim)

    def softmax(self, scores):
        return self.backend._standalone_softmax(scores)

    def pv(self, probabilities, v):
        return self.backend._standalone_pv(probabilities, v)

    def head_concat(self, value):
        return self.backend._standalone_head_concat(value)

    def add(self, lhs, rhs):
        return self.backend._standalone_add(lhs, rhs)


class FusedLayoutPlan(_LayoutPlan):
    name = "fused"
    required_ops = (
        "rms_norm_layout_fused",
        "rope_layout_fused",
        "kv_cache_quant_layout_fused_w4a16",
        "kv_cache_quant_layout_fused_w4a16_update",
        "softmax_layout_fused",
        "head_concat_layout_fused",
        "eladd_layout_fused",
        "mm_w4a16_gemm_core_out",
        "qk_asym_correction_out",
        "hadamard_layout_fused",
    )

    def rms_norm(self, x, weight_name: str, eps: float):
        return self.backend._fused_rms_norm(x, weight_name, eps)

    def linear(self, name: str, x):
        return self.backend._fused_linear(name, x)

    def split_heads(self, x):
        return self.backend._fused_split_heads(x)

    def rope(self, x):
        return self.backend._fused_rope(x)

    def hadamard(self, x):
        return self.backend._fused_hadamard(x)

    def quantize(self, x, mode: str):
        return self.backend._fused_quantize(x, mode)

    def qk(self, q, k):
        return self.backend._fused_attention_core(q, k, transpose_source=True)

    def scaled_masked_scores(self, qk, head_dim: int):
        return DeferredScaledMaskedScores(qk=qk, head_dim=head_dim)

    def softmax(self, scores):
        return self.backend._fused_softmax(scores)

    def pv(self, probabilities, v):
        return self.backend._fused_attention_core(probabilities, v, transpose_source=False)

    def head_concat(self, value):
        return self.backend._fused_head_concat(value)

    def add(self, lhs, rhs):
        return self.backend._fused_add(lhs, rhs)


class VortexPersistentCache:
    """Fixed-capacity K/V buffers in the two C4 GEMM-consumer layouts."""

    def __init__(self, backend: "VortexBackend", config: DecodeConfig) -> None:
        self.backend = backend
        layer = config.layer
        if layer.head_dim != 128:
            raise ValueError("C4 persistent KV v1 requires head_dim=128")
        if config.max_sequence_length % TILE_KN != 0:
            raise ValueError("C4 persistent KV v1 requires capacity divisible by 32")
        padded_capacity = (
            (config.max_sequence_length + (TILE_K - 1)) // TILE_K * TILE_K
            if config.max_sequence_length > TILE_K
            else (config.max_sequence_length + TILE_KN - 1) // TILE_KN * TILE_KN
        )
        self.state = CacheState(
            CacheGeometry(
                batch_size=layer.batch_size,
                num_kv_heads=layer.num_attention_heads,
                head_dim=layer.head_dim,
                max_sequence_length=config.max_sequence_length,
                padded_sequence_length=padded_capacity,
            ),
            allocation_id=f"vortex-kv-{id(self):x}",
        )
        self.group_count = layer.batch_size * layer.num_attention_heads
        zero_source_host = torch.zeros(
            (config.max_sequence_length, layer.head_dim),
            dtype=torch.float16,
        )
        with torch.vortex.memory_alignment(512):
            zero_source = zero_source_host.to(backend.device)
        self.key_buffers = tuple(
            self._allocate_group(zero_source, quant_mode=1)
            for _ in range(self.group_count)
        )
        self.value_buffers = tuple(
            self._allocate_group(zero_source, quant_mode=2)
            for _ in range(self.group_count)
        )
        backend._record(
            "persistent_kv_allocate",
            launches=2 * self.group_count,
            capacity=config.max_sequence_length,
            padded_capacity=padded_capacity,
        )

    @property
    def logical_length(self) -> int:
        return self.state.logical_length

    def _allocate_group(self, source: torch.Tensor, *, quant_mode: int):
        asymmetric = quant_mode == 1
        capacity, head_dim = source.shape
        return torch.ops.vortex.kv_cache_quant_layout_fused_w4a16(
            source,
            capacity,
            head_dim,
            head_dim,
            1,
            0 if asymmetric else 1,
            1 if asymmetric else 0,
            0,
            1 if asymmetric else 0,
            quant_mode,
            head_dim,
            0,
            capacity,
            0,
        )

    @staticmethod
    def _source_views(packed: object) -> tuple[dict, ...]:
        if not isinstance(packed, TensorHandle):
            raise TypeError("C4 persistent cache requires a fused physical KV source")
        views = packed.attachments.get("persistent_source_views")
        if not isinstance(views, tuple):
            raise TypeError("fused KV source is missing persistent source geometry")
        return views

    def _update(
        self,
        packed: object,
        buffers: tuple[tuple[torch.Tensor, ...], ...],
        *,
        quant_mode: int,
        start_position: int,
    ) -> None:
        views = self._source_views(packed)
        if len(views) != self.group_count:
            raise ValueError("persistent source group count does not match cache allocation")
        sequence = int(packed.spec.shape[-2])
        for group_index, view in enumerate(views):
            for local_position in range(sequence):
                torch.ops.vortex.kv_cache_quant_layout_fused_w4a16_update(
                    view["source"],
                    self.state.geometry.max_sequence_length,
                    start_position + local_position,
                    quant_mode,
                    *buffers[group_index],
                    self.state.geometry.head_dim,
                    view["src_layout"],
                    view["src_total_n"],
                    view["src_col_offset"],
                    view["src_total_k"],
                    view["src_row_offset"] + local_position,
                )
        self.backend._record(
            "persistent_kv_append",
            launches=self.group_count * sequence,
            quant_mode=quant_mode,
            start_position=start_position,
            token_count=sequence,
        )

    def prefill_quantized(self, qkey, k_scale, k_zero, qvalue, v_scale) -> None:
        del k_scale, k_zero, v_scale
        prompt_length = int(qkey.spec.shape[-2])
        self.state.validate_prefill(prompt_length)
        if int(qvalue.spec.shape[-2]) != prompt_length:
            raise ValueError("K/V prefill lengths do not match")
        self._update(qkey, self.key_buffers, quant_mode=1, start_position=0)
        self._update(qvalue, self.value_buffers, quant_mode=2, start_position=0)
        self.state.publish_prefill(prompt_length)

    def append_quantized(
        self, qkey, k_scale, k_zero, qvalue, v_scale, *, position: int
    ) -> None:
        del k_scale, k_zero, v_scale
        self.state.validate_append(position=position)
        if int(qkey.spec.shape[-2]) != 1 or int(qvalue.spec.shape[-2]) != 1:
            raise ValueError("persistent append requires exactly one K/V token")
        self._update(qkey, self.key_buffers, quant_mode=1, start_position=position)
        self._update(qvalue, self.value_buffers, quant_mode=2, start_position=position)
        self.state.publish_append()

    def _packed_handle(self, *, key: bool) -> TensorHandle:
        geometry = self.state.geometry
        buffers = self.key_buffers if key else self.value_buffers
        payload = tuple(group[0] for group in buffers)
        source_transposed = 1 if key else 0
        weight_k = geometry.head_dim if key else geometry.padded_sequence_length
        weight_n = (
            (geometry.max_sequence_length + TILE_KN - 1) // TILE_KN * TILE_KN
            if key else geometry.head_dim
        )
        return _make_grouped_handle(
            payload,
            name="persistent_k" if key else "persistent_v",
            axes=("B", "H", "S", "Dp"),
            shape=(
                geometry.batch_size,
                geometry.num_kv_heads,
                self.logical_length,
                geometry.head_dim // 2,
            ),
            layout="gemm_w_packed_grouped",
            padded_shape=tuple(payload[0].shape),
            producer="persistent_kv_cache",
            grouping="head",
            weight_k=weight_k,
            weight_n=weight_n,
            wtrans=source_transposed,
            source_transposed=source_transposed,
            capacity=geometry.max_sequence_length,
            padded_capacity=geometry.padded_sequence_length,
            logical_length=self.logical_length,
        )

    def _logical_handle(self, *, key: bool, zero: bool = False) -> TensorHandle:
        geometry = self.state.geometry
        buffers = self.key_buffers if key else self.value_buffers
        buffer_index = 4 if zero else 3
        values = tuple(group[buffer_index] for group in buffers)
        if zero:
            name = "k_zero"
        else:
            name = "k_scale" if key else "v_scale"
        return _make_grouped_handle(
            values,
            name=name,
            axes=("B", "H", "S", "G"),
            shape=(
                geometry.batch_size,
                geometry.num_kv_heads,
                self.logical_length,
                1,
            ),
            layout="grouped_prefix_row",
            padded_shape=(geometry.max_sequence_length, 1),
            producer="persistent_kv_cache",
            grouping="head",
            rows=geometry.max_sequence_length,
            columns=1,
            logical_rows=self.logical_length,
        )

    def get_kv(self):
        key = self._packed_handle(key=True)
        k_scale = self._logical_handle(key=True)
        k_zero = self._logical_handle(key=True, zero=True)
        value = self._packed_handle(key=False)
        v_scale = self._logical_handle(key=False)
        key.attachments["weight_tiled"] = tuple(group[0] for group in self.key_buffers)
        k_scale.attachments["scale_tiled"] = tuple(group[1] for group in self.key_buffers)
        k_zero.attachments["zero_tiled"] = tuple(group[2] for group in self.key_buffers)
        value.attachments["weight_tiled"] = tuple(group[0] for group in self.value_buffers)
        v_scale.attachments["scale_tiled"] = tuple(group[1] for group in self.value_buffers)
        v_scale.attachments["zero_tiled"] = tuple(group[2] for group in self.value_buffers)
        return (key, k_scale, k_zero), (value, v_scale, None)

    def dequantized_kv(self):
        key_cache, value_cache = self.get_kv()
        key = QuantizedActivation(
            packed=key_cache[0], scale=key_cache[1], zero=key_cache[2],
            mode="asym", logical_shape=key_cache[0].spec.shape,
        )
        value = QuantizedActivation(
            packed=value_cache[0], scale=value_cache[1], zero=None,
            mode="sym", logical_shape=value_cache[0].spec.shape,
        )
        return self.backend.quantized_capture(key), self.backend.quantized_capture(value)

    def descriptor(self) -> dict:
        geometry = self.state.geometry

        def describe_groups(groups):
            names = ("weight", "scale", "zero", "logical_scale", "logical_zero")
            return [
                {
                    name: {
                        "address": tensor.data_ptr(),
                        "nbytes": tensor.numel() * tensor.element_size(),
                        "shape": list(tensor.shape),
                        "dtype": str(tensor.dtype).removeprefix("torch."),
                    }
                    for name, tensor in zip(names, group)
                }
                for group in groups
            ]

        key_groups = describe_groups(self.key_buffers)
        value_groups = describe_groups(self.value_buffers)
        return {
            "allocation_id": self.state.allocation_id,
            "device": str(self.backend.device),
            "logical_length": self.logical_length,
            "cache_generation": self.state.cache_generation,
            "lifecycle": self.state.lifecycle,
            "geometry": asdict(geometry),
            "layouts": {
                "key": "gemm_w_tiled_transposed",
                "value": "gemm_w_tiled",
            },
            "quantization": {
                "key": "signed_asymmetric_int4",
                "value": "signed_symmetric_int4",
            },
            "group_storage": "separate_aligned_allocations",
            "buffers": {"key": key_groups, "value": value_groups},
            # Each batch/head group owns an independent allocation, so there is
            # no valid address delta between adjacent groups.  The capacity-
            # derived allocation extent is the stride a contiguous arena would
            # require and is useful to consumers sizing such an arena later.
            "per_head_strides_bytes": {
                "key": None,
                "value": None,
            },
            "per_head_buffer_bytes": {
                "key": {
                    name: item["nbytes"] for name, item in key_groups[0].items()
                },
                "value": {
                    name: item["nbytes"] for name, item in value_groups[0].items()
                },
            },
            "key_addresses": [group[0].data_ptr() for group in self.key_buffers],
            "value_addresses": [group[0].data_ptr() for group in self.value_buffers],
        }

    def reset(self) -> None:
        self.state.reset()


class VortexBackend(Backend):
    """Strict Vortex backend with selectable activation-layout lowering."""

    name = "vortex"

    COMMON_REQUIRED_OPS = (
        "rms_norm",
        "mm_w4a16_opt",
        "tile_weight_w4a16",
        "tile_scale_zp_w4a16",
        "mm_w4a16_gemm_core",
        "detile_output",
    )

    def __init__(
        self,
        *,
        strict_native: bool = True,
        physical_plan: str = "standalone",
    ) -> None:
        if physical_plan not in ("standalone", "fused"):
            raise ValueError(f"unknown Vortex physical plan {physical_plan!r}")
        self.strict_native = strict_native
        # The public "vortex" device name is registered by torch_vortex during
        # preflight, so keep this as a string until then.
        self.device = "vortex"
        self._tensors: Dict[str, torch.Tensor] = {}
        self._weight_layouts: Dict[str, tuple[torch.Tensor, torch.Tensor, torch.Tensor]] = {}
        self._hadamard_matrices: Dict[int, tuple[torch.Tensor, int]] = {}
        self._steps: list[dict] = []
        self._launches: Dict[str, int] = {}
        self._canonical_cache: Dict[int, tuple[TensorHandle, torch.Tensor]] = {}
        self._active_sequence_length = 0
        self._active_key_length = 0
        self._active_position_offset = 0
        plan_type = StandaloneLayoutPlan if physical_plan == "standalone" else FusedLayoutPlan
        self.layout_plan = plan_type(self)

    @property
    def physical_plan(self) -> str:
        return self.layout_plan.name

    def bind(self, case: LayerCase | DecodeCase) -> None:
        import torch_vortex  # noqa: F401

        super().bind(case)
        self._tensors = {name: tensor.to(self.device) for name, tensor in case.tensors.items()}
        self._weight_layouts.clear()
        self._hadamard_matrices.clear()
        self._steps.clear()
        self._launches.clear()
        self._canonical_cache.clear()

    def activate(
        self,
        input_tensor: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
    ) -> None:
        self._tensors["input"] = input_tensor.to(self.device)
        self._tensors["position_ids"] = position_ids.to(self.device)
        self._tensors["causal_mask"] = causal_mask.to(self.device)
        self._active_sequence_length = int(input_tensor.shape[1])
        self._active_key_length = int(causal_mask.shape[-1])
        positions = position_ids.reshape(-1)
        self._active_position_offset = int(positions[0].item())

    def create_persistent_cache(self, config: DecodeConfig) -> VortexPersistentCache:
        if self.physical_plan != "fused":
            raise ValueError("C4 persistent decode currently requires physical_plan='fused'")
        return VortexPersistentCache(self, config)

    def preflight(self, case: LayerCase | DecodeCase, stop_after: str) -> None:
        del stop_after
        if self.strict_native:
            os.environ["TORCH_VORTEX_STRICT_NATIVE"] = "1"
        import torch_vortex  # noqa: F401

        required = self.COMMON_REQUIRED_OPS + self.layout_plan.required_ops
        missing = [name for name in required if not hasattr(torch.ops.vortex, name)]
        if missing:
            raise RuntimeError(f"Vortex layer-accuracy extension is missing required ops: {missing}")
        if self.layout_plan.name == "fused":
            self._validate_fused_case(case)
        else:
            self._validate_c4_shape(case)
        self._prewarm_kernel_regions(case)

    @staticmethod
    def _validate_c4_shape(case: LayerCase | DecodeCase) -> None:
        if isinstance(case.config, DecodeConfig):
            if case.config.max_sequence_length % TILE_KN != 0:
                raise ValueError("C4 decode cache capacity must be divisible by 32")
            return
        sequence_m_pad = (case.config.sequence_length + 7) & ~7
        if case.config.sequence_length % TILE_KN != 0:
            raise ValueError(
                "the C4 physical plans currently require sequence_length "
                "to be a multiple of the 32-column GEMM micro-tile"
            )
        qk_head_stride_bytes = sequence_m_pad * case.config.sequence_length * 2
        if qk_head_stride_bytes % 512 != 0:
            raise ValueError(
                "the fused physical plan requires a 512-byte-aligned QK head stride: "
                f"align8(S)*S*2={qk_head_stride_bytes}"
            )

    @staticmethod
    def _validate_fused_case(case: LayerCase | DecodeCase) -> None:
        VortexBackend._validate_c4_shape(case)
        config = case.config.layer if isinstance(case.config, DecodeConfig) else case.config
        expected = ("llama2-7b", 4096, 11008, 32, 128)
        actual = (
            config.model,
            config.hidden_size,
            config.intermediate_size,
            config.num_attention_heads,
            config.head_dim,
        )
        if actual != expected:
            raise ValueError(
                "the fused physical plan currently requires Llama2-7B "
                "H4096/I11008/heads32/head_dim128"
            )
        score_scale = case.tensors["score_scale"]
        expected_scale = torch.full_like(
            score_scale, 1.0 / math.sqrt(config.head_dim)
        )
        if not torch.equal(score_scale, expected_scale):
            raise ValueError(
                "the fused softmax requires uniform score_scale=1/sqrt(head_dim)"
            )
        expected_mask = torch.full_like(
            case.tensors["causal_mask"], torch.finfo(torch.float16).min
        )
        expected_mask = torch.triu(expected_mask, diagonal=1)
        if not torch.equal(case.tensors["causal_mask"], expected_mask):
            raise ValueError("the fused softmax requires the canonical causal mask")

    def _prewarm_kernel_regions(self, case: LayerCase | DecodeCase) -> None:
        """Reserve both kernel VMA regions before uploading the real case."""
        x = torch.zeros((8, 32), dtype=torch.float16).to(self.device)
        gamma = torch.ones((32,), dtype=torch.float16).to(self.device)
        # Force a host-visible completion between kernel families.  In the
        # simulator, ready_wait completes the launch but a following kernel
        # image replacement can otherwise race the final device-side drains.
        config = case.config.layer if isinstance(case.config, DecodeConfig) else case.config
        rms_out = torch.ops.vortex.rms_norm(
            x.reshape(1, 8, 32), gamma, config.rms_norm_eps
        )
        rms_host = rms_out.cpu()
        packed = torch.zeros((32, 16), dtype=torch.uint8).to(self.device)
        scales = torch.ones((1, 32), dtype=torch.float16).to(self.device)
        zeros = torch.zeros((1, 32), dtype=torch.int16).to(self.device)
        gemm_out = torch.ops.vortex.mm_w4a16_opt(
            x, packed, scales, zeros, 32, 32, 0, 0
        )
        gemm_host = gemm_out.cpu()
        # Keep device and host temporaries alive until both regions have
        # completed their first round trip.
        del rms_host, gemm_host

    def _record(self, op: str, *, launches: int = 1, **metadata) -> None:
        self._steps.append({"op": op, "launches": launches, **metadata})
        self._launches[op] = self._launches.get(op, 0) + launches

    def _transition(self, layout_from: str, layout_to: str, *, reason: str) -> None:
        self._steps.append(
            {
                "op": "layout_transition",
                "layout_from": layout_from,
                "layout_to": layout_to,
                "reason": reason,
            }
        )

    def tensor(self, name: str) -> torch.Tensor:
        return self._tensors[name]

    def rms_norm(self, x, weight_name: str, eps: float):
        return self.layout_plan.rms_norm(x, weight_name, eps)

    def _standalone_rms_norm(
        self, x: torch.Tensor, weight_name: str, eps: float
    ) -> torch.Tensor:
        self._record("rms_norm", layout="row_major")
        return torch.ops.vortex.rms_norm(x.contiguous(), self.tensor(weight_name).contiguous(), eps)

    def _static_layout(self, name: str) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        cached = self._weight_layouts.get(name)
        if cached is not None:
            return cached
        packed = self.tensor(f"{name}.qweight").view(torch.uint8).contiguous()
        scales = self.tensor(f"{name}.scales").contiguous()
        in_features = packed.shape[0]
        out_features = packed.shape[1] * 2
        zeros = torch.zeros(scales.shape, dtype=torch.int16).to(self.device)
        weight_tiled = torch.ops.vortex.tile_weight_w4a16(packed, in_features, out_features, 0)
        scale_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
            scales, in_features, out_features, self.layer_config.weight_group_size, 0
        )
        zero_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
            zeros, in_features, out_features, self.layer_config.weight_group_size, 0
        )
        self._record(
            "tile_static_weight", launches=3, tensor=name, layout="gemm_w_tiled"
        )
        self._weight_layouts[name] = (weight_tiled, scale_tiled, zero_tiled)
        return self._weight_layouts[name]

    def linear(self, name: str, x):
        return self.layout_plan.linear(name, x)

    def _standalone_linear(self, name: str, x: torch.Tensor) -> torch.Tensor:
        shape = x.shape[:-1]
        x2 = x.reshape(-1, x.shape[-1]).contiguous()
        k_dim = x2.shape[1]
        n_dim = self.tensor(f"{name}.qweight").shape[1] * 2
        m_dim = x2.shape[0]
        m_pad = (m_dim + 7) & ~7
        weight, scale, zero = self._static_layout(name)
        input_tiled = torch.ops.vortex.tile_input_a(x2, m_pad, k_dim)
        output_tiled = torch.ops.vortex.mm_w4a16_gemm_core(
            input_tiled,
            weight,
            scale,
            zero,
            k_dim,
            n_dim,
            self.layer_config.weight_group_size,
            0,
            0,
        )
        output = torch.ops.vortex.detile_output(output_tiled, m_dim, m_pad, n_dim)
        self._record("w4a16_linear", tensor=name, M=m_dim, K=k_dim, N=n_dim)
        return output.reshape(*shape, n_dim)

    def split_heads(self, x):
        return self.layout_plan.split_heads(x)

    def _standalone_split_heads(self, x: torch.Tensor) -> torch.Tensor:
        config = self.layer_config
        return x.reshape(
            config.batch_size,
            self._active_sequence_length,
            config.num_attention_heads,
            config.head_dim,
        ).transpose(1, 2).contiguous()

    def rope(self, x):
        return self.layout_plan.rope(x)

    def _standalone_rope(self, x: torch.Tensor) -> torch.Tensor:
        half = x.shape[-1] // 2
        cos = self.tensor("rope_cos")[..., :half].reshape(-1, half).contiguous()
        sin = self.tensor("rope_sin")[..., :half].reshape(-1, half).contiguous()
        physical = x.permute(0, 2, 1, 3).contiguous()
        output = torch.ops.vortex.apply_rotary_pos_emb(
            physical, cos, sin, self._active_position_offset
        )
        self._record("rope", layout_from="BHSD", layout_to="BHSD")
        return output.permute(0, 2, 1, 3).contiguous()

    def hadamard(self, x):
        return self.layout_plan.hadamard(x)

    def _standalone_hadamard(self, x: torch.Tensor) -> torch.Tensor:
        n = x.shape[-1]
        had_k, k_base = get_hadK(n)
        output = torch.ops.vortex.hadamard_butterfly(x.contiguous(), k_base)
        self._record("hadamard_butterfly", dimension=n, base=k_base)
        if k_base > 1:
            rows = output.numel() // n
            matrix = had_k.to(dtype=torch.float16, device=self.device).contiguous()
            output = torch.ops.vortex.hadamard_base(
                output.reshape(rows, n).contiguous(), matrix, k_base
            ).reshape(x.shape)
            self._record("hadamard_base", dimension=k_base, implementation="native")
        return output

    def _hadamard_matrix(self, n: int) -> tuple[torch.Tensor, int]:
        cached = self._hadamard_matrices.get(n)
        if cached is None:
            had_k, k_base = get_hadK(n)
            matrix = had_k if k_base > 1 else torch.ones((1, 1))
            cached = (
                matrix.to(dtype=torch.float16, device=self.device).contiguous(),
                k_base,
            )
            self._hadamard_matrices[n] = cached
        return cached

    def _fused_hadamard(self, x: torch.Tensor) -> TensorHandle:
        config = self.layer_config
        n = x.shape[-1]
        matrix, k_base = self._hadamard_matrix(n)
        if tuple(x.shape) == (
            config.batch_size,
            config.num_attention_heads,
            self._active_sequence_length,
            config.head_dim,
        ):
            matrix_count = config.batch_size * config.num_attention_heads
            rows = self._active_sequence_length
            axes = ("B", "H", "S", "D")
            grouping = "head"
            name = "r3"
        elif tuple(x.shape) == (
            config.batch_size,
            self._active_sequence_length,
            config.intermediate_size,
        ):
            matrix_count = 1
            rows = config.batch_size * self._active_sequence_length
            axes = ("B", "S", "I")
            grouping = None
            name = "r4"
        else:
            raise ValueError(
                "fused Hadamard requires BHSD R3 or BSI R4 semantic storage"
            )
        m_pad = (rows + 7) & ~7
        output = torch.ops.vortex.hadamard_layout_fused(
            x.contiguous(), matrix, k_base, matrix_count, rows, m_pad
        )
        if matrix_count == 1:
            output = output[0]
        self._record(
            "hadamard_layout_fused",
            rotation=name.upper(),
            matrices=matrix_count,
            M=rows,
            M_pad=m_pad,
            K=n,
            base=k_base,
        )
        self._transition(
            "bhsd_row" if name == "r3" else "row_major",
            "gemm_a_tiled",
            reason=f"spinquant_{name}",
        )
        return _make_handle(
            output,
            name=name,
            axes=axes,
            shape=tuple(x.shape),
            layout="gemm_a_tiled",
            padded_shape=tuple(output.shape),
            producer="hadamard_layout_fused",
            grouping=grouping,
            matrix_count=matrix_count,
            m=rows,
            m_pad=m_pad,
            n=n,
        )

    def quantize(self, x, mode: str) -> QuantizedActivation:
        return self.layout_plan.quantize(x, mode)

    def _standalone_quantize(self, x: torch.Tensor, mode: str) -> QuantizedActivation:
        mode_value = 0 if mode == "sym" else 1
        packed, scale, zero = torch.ops.vortex.quantize_pack_per_token(x.contiguous(), mode_value)
        self._record("quantize_pack_per_token", mode=mode, layout="packed_s4_low_first")
        return QuantizedActivation(
            packed=packed,
            scale=scale,
            zero=None if mode == "sym" else zero,
            mode=mode,
            logical_shape=tuple(x.shape),
        )

    def quantized_capture(self, value: QuantizedActivation) -> torch.Tensor:
        packed = self.canonicalize(value.packed)
        scale = self.canonicalize(value.scale).float()
        q = unpack_signed_int4(packed).float()
        if value.mode == "asym":
            assert value.zero is not None
            q -= self.canonicalize(value.zero).float()
        return (q * scale).to(torch.float16)

    def _attention_core(
        self,
        lhs: torch.Tensor,
        rhs: QuantizedActivation,
        *,
        transpose_source: bool,
    ) -> torch.Tensor:
        batch, heads, m_dim, k_dim = lhs.shape
        outputs = []
        n_dim = rhs.logical_shape[-2] if transpose_source else rhs.logical_shape[-1]
        for batch_index in range(batch):
            for head in range(heads):
                x = lhs[batch_index, head].contiguous()
                m_pad = (m_dim + 7) & ~7
                input_tiled = torch.ops.vortex.tile_input_a(x, m_pad, k_dim)
                gemm_k = input_tiled.shape[1]
                packed = rhs.packed[batch_index, head].view(torch.uint8).contiguous()
                scale = rhs.scale[batch_index, head].contiguous()
                if transpose_source:
                    source_k, source_n = rhs.logical_shape[-2], rhs.logical_shape[-1]
                    weight = torch.ops.vortex.tile_weight_w4a16_ex(
                        packed, source_k, source_n, 1, 1
                    )
                    zeros = torch.zeros(scale.shape, dtype=torch.int16).to(self.device)
                    scale_tiled = torch.ops.vortex.tile_scale_zp_w4a16_ex(
                        scale, source_k, source_n, self.layer_config.kv_group_size, 1, 0, 1
                    )
                    zero_tiled = torch.ops.vortex.tile_scale_zp_w4a16_ex(
                        zeros, source_k, source_n, self.layer_config.kv_group_size, 1, 0, 1
                    )
                    wtrans, qdir = 1, 0
                else:
                    weight = torch.ops.vortex.tile_weight_w4a16(packed, k_dim, n_dim, 0)
                    zeros = torch.zeros(scale.shape, dtype=torch.int16).to(self.device)
                    scale_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
                        scale, k_dim, n_dim, self.layer_config.kv_group_size, 1
                    )
                    zero_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
                        zeros, k_dim, n_dim, self.layer_config.kv_group_size, 1
                    )
                    wtrans, qdir = 0, 1
                output_tiled = torch.ops.vortex.mm_w4a16_gemm_core(
                    input_tiled,
                    weight,
                    scale_tiled,
                    zero_tiled,
                    gemm_k,
                    n_dim,
                    self.layer_config.kv_group_size,
                    wtrans,
                    qdir,
                )
                output = torch.ops.vortex.detile_output(output_tiled, m_dim, m_pad, n_dim)
                if transpose_source:
                    assert rhs.zero is not None
                    output = torch.ops.vortex.qk_asym_correction(
                        output,
                        x,
                        scale.reshape(-1),
                        rhs.zero[batch_index, head].reshape(-1),
                    )
                outputs.append(output)
        self._record(
            "attention_w4a16",
            transpose_source=transpose_source,
            batch=batch,
            heads=heads,
            launches=batch * heads,
            M=m_dim,
            K=k_dim,
            K_pad=gemm_k,
            N=n_dim,
        )
        stacked = torch.empty(
            (batch, heads, m_dim, n_dim), dtype=torch.float16, device=self.device
        )
        for group_index, output in enumerate(outputs):
            batch_index, head = divmod(group_index, heads)
            stacked[batch_index, head].copy_(output)
        self._record("head_stack_layout_copy", implementation="host_staged_device_copy")
        return stacked

    def qk(self, q, k: QuantizedActivation):
        return self.layout_plan.qk(q, k)

    def _standalone_qk(self, q: torch.Tensor, k: QuantizedActivation) -> torch.Tensor:
        return self._attention_core(q, k, transpose_source=True)

    def scaled_masked_scores(self, qk, head_dim: int):
        return self.layout_plan.scaled_masked_scores(qk, head_dim)

    def _standalone_scaled_masked_scores(
        self, qk: torch.Tensor, head_dim: int
    ) -> torch.Tensor:
        del head_dim
        scaled = qk.contiguous() * self.tensor("score_scale")
        mask = self.tensor("causal_mask").expand_as(qk).contiguous()
        self._record("scale_scores", layout="BHSS")
        self._record("add_causal_mask", layout="BHSS")
        return scaled + mask

    def softmax(self, scores):
        return self.layout_plan.softmax(scores)

    def _standalone_softmax(self, scores: torch.Tensor) -> torch.Tensor:
        self._record("softmax", axis="S")
        return torch.softmax(scores.contiguous(), dim=-1)

    def pv(self, probabilities, v: QuantizedActivation):
        return self.layout_plan.pv(probabilities, v)

    def _standalone_pv(
        self, probabilities: torch.Tensor, v: QuantizedActivation
    ) -> torch.Tensor:
        return self._attention_core(probabilities, v, transpose_source=False)

    def head_concat(self, value):
        return self.layout_plan.head_concat(value)

    def _standalone_head_concat(self, value: torch.Tensor) -> torch.Tensor:
        self._record("head_concat", layout_from="BHSD", layout_to="BSC")
        return torch.ops.vortex.head_concat(value.contiguous())

    def _fused_rms_norm(self, x: torch.Tensor, weight_name: str, eps: float) -> TensorHandle:
        shape = tuple(x.shape)
        m = x.numel() // shape[-1]
        k = shape[-1]
        m_pad = (m + 7) & ~7
        output = torch.ops.vortex.rms_norm_layout_fused(
            x.reshape(m, k).contiguous(),
            self.tensor(weight_name).contiguous(),
            eps,
            m_pad,
        )
        self._record("rms_norm_layout_fused", M=m, M_pad=m_pad, K=k)
        self._transition("row_major", "gemm_a_tiled", reason="rms_norm")
        return _make_handle(
            output,
            name=f"{weight_name}.output",
            axes=("B", "S", "C"),
            shape=shape,
            layout="gemm_a_tiled",
            padded_shape=tuple(output.shape),
            producer="rms_norm_layout_fused",
            m=m,
            m_pad=m_pad,
            n=k,
        )

    def _fused_linear(self, name: str, x) -> TensorHandle:
        if isinstance(x, TensorHandle):
            physical = x.spec.physical
            assert physical is not None and physical.layout == "gemm_a_tiled"
            params = _physical_parameters(x)
            input_tiled = x.value
            semantic_shape = x.spec.shape
            m = params["m"]
            m_pad = params["m_pad"]
            k = params["n"]
        else:
            raise TypeError(
                f"fused linear {name!r} requires a GEMM-A physical tensor"
            )
        n = self.tensor(f"{name}.qweight").shape[1] * 2
        weight, scale, zero = self._static_layout(name)
        output = torch.ops.vortex.mm_w4a16_gemm_core(
            input_tiled,
            weight,
            scale,
            zero,
            k,
            n,
            self.layer_config.weight_group_size,
            0,
            0,
        )
        self._record("mm_w4a16_gemm_core", tensor=name, M=m, M_pad=m_pad, K=k, N=n)
        output_shape = (*semantic_shape[:-1], n)
        return _make_handle(
            output,
            name=f"{name}.output",
            axes=("B", "S", "C"),
            shape=output_shape,
            layout="gemm_c_tiled",
            padded_shape=tuple(output.shape),
            producer="mm_w4a16_gemm_core",
            m=m,
            m_pad=m_pad,
            n=n,
        )

    def _fused_split_heads(self, x: TensorHandle) -> TensorHandle:
        physical = x.spec.physical
        if physical is None or physical.layout != "gemm_c_tiled":
            raise TypeError("fused split_heads requires a GEMM-C physical tensor")
        config = self.layer_config
        return TensorHandle(
            spec=TensorSpec(
                name=x.spec.name,
                axes=("B", "H", "S", "D"),
                shape=(
                    config.batch_size,
                    config.num_attention_heads,
                    self._active_sequence_length,
                    config.head_dim,
                ),
                dtype=x.spec.dtype,
                physical=physical,
            ),
            value=x.value,
            producer="split_heads_view",
        )

    def _fused_rope(self, x: TensorHandle) -> torch.Tensor:
        config = self.layer_config
        params = _physical_parameters(x)
        half = config.head_dim // 2
        cos = self.tensor("rope_cos")[..., :half].reshape(-1, half).contiguous()
        sin = self.tensor("rope_sin")[..., :half].reshape(-1, half).contiguous()
        output = torch.ops.vortex.rope_layout_fused(
            x.value,
            cos,
            sin,
            config.batch_size,
            self._active_sequence_length,
            config.num_attention_heads,
            config.head_dim,
            params["m_pad"],
            3,
            self._active_position_offset,
        )
        self._record("rope_layout_fused", layout_to="BHSD", M_pad=params["m_pad"])
        self._transition("gemm_c_tiled", "bhsd_row", reason="rope_r3_boundary")
        return output

    def _fused_quantize(self, x, mode: str) -> QuantizedActivation:
        if mode not in ("asym", "sym"):
            raise ValueError(f"unsupported KV quantization mode {mode!r}")
        config = self.layer_config
        source_is_tiled = isinstance(x, TensorHandle)
        source_layout = "bhsd_row"
        source_is_grouped = False
        if source_is_tiled:
            if x.spec.physical is None or x.spec.physical.layout not in (
                "gemm_a_tiled", "gemm_c_tiled"
            ):
                raise TypeError("fused KV quantization requires GEMM-A/C source")
            source = x.value
            source_params = _physical_parameters(x)
            source_total_n = source_params["n"]
            logical_shape = x.spec.shape
            source_layout = x.spec.physical.layout
            source_is_grouped = source_layout == "gemm_a_tiled"
        else:
            source = x
            source_total_n = config.head_dim
            logical_shape = tuple(x.shape)
        packed_tiled = []
        scale_tiled = []
        zero_tiled = []
        row_scale = []
        row_zero = []
        persistent_source_views = []
        source_transposed = 1 if mode == "asym" else 0
        wtrans = source_transposed
        gemm_qdir = 0 if mode == "asym" else 1
        quant_mode = 1 if mode == "asym" else 2
        group_count = config.batch_size * config.num_attention_heads
        for group_index in range(group_count):
            batch_index, head = divmod(group_index, config.num_attention_heads)
            head_source = (
                source[group_index]
                if source_is_grouped
                else source if source_is_tiled
                else source[batch_index, head].contiguous()
            )
            src_layout = 2 if source_is_grouped else 1 if source_is_tiled else 0
            source_total_k = (
                source_params["m_pad"] if source_is_tiled else self._active_sequence_length
            )
            source_row_offset = (
                batch_index * self._active_sequence_length
                if source_is_tiled and not source_is_grouped
                else 0
            )
            persistent_source_views.append(
                {
                    "source": head_source,
                    "src_layout": src_layout,
                    "src_total_n": config.head_dim if source_is_grouped else source_total_n,
                    "src_col_offset": (
                        head * config.head_dim
                        if source_is_tiled and not source_is_grouped else 0
                    ),
                    "src_total_k": source_total_k,
                    "src_row_offset": source_row_offset,
                }
            )
            outputs = torch.ops.vortex.kv_cache_quant_layout_fused_w4a16(
                head_source,
                self._active_sequence_length,
                config.head_dim,
                config.kv_group_size,
                1,
                gemm_qdir,
                wtrans,
                src_layout,
                source_transposed,
                quant_mode,
                config.head_dim if source_is_grouped else source_total_n,
                head * config.head_dim if source_is_tiled and not source_is_grouped else 0,
                source_total_k,
                source_row_offset,
            )
            weight, scale_tile, zero_tile, scale_row, zero_row = outputs
            packed_tiled.append(weight)
            scale_tiled.append(scale_tile)
            zero_tiled.append(zero_tile)
            row_scale.append(scale_row)
            row_zero.append(zero_row)
        logical_weight_k = (
            config.head_dim if source_transposed else self._active_sequence_length
        )
        weight_k_alignment = TILE_KN if logical_weight_k <= TILE_K else TILE_K
        weight_k = (
            logical_weight_k + weight_k_alignment - 1
        ) // weight_k_alignment * weight_k_alignment
        weight_n = self._active_sequence_length if source_transposed else config.head_dim
        packed = _make_grouped_handle(
            packed_tiled,
            name=f"{mode}_kv.packed",
            axes=("B", "H", "S", "Dp"),
            shape=(
                config.batch_size,
                config.num_attention_heads,
                self._active_sequence_length,
                config.head_dim // 2,
            ),
            layout="gemm_w_packed_grouped",
            padded_shape=tuple(packed_tiled[0].shape),
            producer="kv_cache_quant_layout_fused_w4a16",
            grouping="head",
            weight_k=weight_k,
            weight_n=weight_n,
            wtrans=wtrans,
            source_transposed=source_transposed,
        )
        packed.attachments["persistent_source_views"] = tuple(
            persistent_source_views
        )
        scale = _make_grouped_handle(
            row_scale,
            name=f"{mode}_kv.scale",
            axes=("B", "H", "S", "G"),
            shape=(
                config.batch_size,
                config.num_attention_heads,
                self._active_sequence_length,
                1,
            ),
            layout="grouped_row",
            padded_shape=tuple(row_scale[0].shape),
            producer="kv_cache_quant_layout_fused_w4a16",
            grouping="head",
            rows=self._active_sequence_length,
            columns=1,
        )
        zero = None
        if mode == "asym":
            zero = _make_grouped_handle(
                row_zero,
                name="asym_kv.zero",
                axes=("B", "H", "S", "G"),
                shape=(
                    config.batch_size,
                    config.num_attention_heads,
                    self._active_sequence_length,
                    1,
                ),
                layout="grouped_row",
                padded_shape=tuple(row_zero[0].shape),
                producer="kv_cache_quant_layout_fused_w4a16",
                grouping="head",
                rows=self._active_sequence_length,
                columns=1,
            )
        self._record(
            "kv_cache_quant_layout_fused_w4a16",
            launches=group_count,
            mode=mode,
            batch=config.batch_size,
            heads=config.num_attention_heads,
            source_layout=source_layout,
        )
        self._transition(
            source_layout,
            "gemm_w_packed",
            reason=f"{mode}_kv_quant",
        )
        return QuantizedActivation(
            packed=packed,
            scale=scale,
            zero=zero,
            mode=mode,
            logical_shape=logical_shape,
            weight_tiled=tuple(packed_tiled),
            scale_tiled=tuple(scale_tiled),
            zero_tiled=tuple(zero_tiled),
        )

    def _fused_attention_core(
        self,
        lhs,
        rhs: QuantizedActivation,
        *,
        transpose_source: bool,
    ) -> TensorHandle:
        config = self.layer_config
        heads = config.num_attention_heads
        group_count = config.batch_size * heads
        m = self._active_sequence_length
        m_pad = (m + 7) & ~7
        logical_cache_length = rhs.logical_shape[-2]
        persistent_params = None
        if isinstance(rhs.packed, TensorHandle) and rhs.packed.spec.physical is not None:
            params = _physical_parameters(rhs.packed)
            if "capacity" in params:
                persistent_params = params
        k = config.head_dim if transpose_source else logical_cache_length
        k_pad = k
        if isinstance(lhs, TensorHandle):
            k_pad = _physical_parameters(lhs).get("n_pad", k)
        if persistent_params is not None and not transpose_source:
            k_pad = persistent_params["weight_k"]
        n = logical_cache_length if transpose_source else config.head_dim
        output_n = (
            persistent_params["weight_n"]
            if persistent_params is not None and transpose_source else n
        )
        head_stride_bytes = m_pad * output_n * torch.empty((), dtype=torch.float16).element_size()
        if head_stride_bytes % 512 != 0:
            raise ValueError(
                "grouped fused attention requires each head output stride to be 512-byte aligned"
            )
        with torch.vortex.memory_alignment(512):
            output = torch.empty(
                (group_count, m_pad, output_n),
                dtype=torch.float16,
                device=self.device,
            )
        for group_index in range(group_count):
            if isinstance(lhs, TensorHandle):
                lhs_storage = lhs.value[group_index]
                query_storage = lhs_storage
            else:
                raise TypeError("fused attention requires grouped GEMM-A input")
            torch.ops.vortex.mm_w4a16_gemm_core_out(
                lhs_storage,
                rhs.weight_tiled[group_index],
                rhs.scale_tiled[group_index],
                rhs.zero_tiled[group_index],
                k_pad,
                output_n,
                config.kv_group_size,
                1 if transpose_source else 0,
                0 if transpose_source else 1,
                output[group_index],
            )
            if transpose_source:
                torch.ops.vortex.qk_asym_correction_out(
                    output[group_index],
                    query_storage,
                    rhs.scale.value[group_index].reshape(-1),
                    rhs.zero.value[group_index].reshape(-1),
                    m,
                    m_pad,
                    output_n,
                    1,
                    1 if isinstance(lhs, TensorHandle) else 0,
                    output[group_index],
                )
        self._record(
            "mm_w4a16_gemm_core_out",
            launches=group_count,
            operation="qk" if transpose_source else "pv",
            batch=config.batch_size,
            heads=heads,
            M=m,
            M_pad=m_pad,
            K=k,
            K_pad=k_pad,
            N=n,
            N_storage=output_n,
        )
        if transpose_source:
            self._record(
                "qk_asym_correction_out",
                launches=group_count,
                layout="gemm_c_tiled",
                batch=config.batch_size,
                heads=heads,
            )
        return _make_handle(
            output,
            name="qk" if transpose_source else "pv",
            axes=("B", "H", "S", "N"),
            shape=(config.batch_size, heads, m, n),
            layout="gemm_c_tiled",
            padded_shape=tuple(output.shape),
            producer="attention_w4a16_fused",
            grouping="head",
            matrix_count=group_count,
            m=m,
            m_pad=m_pad,
            n=n,
            n_pad=output_n,
            pv_k_pad=(
                persistent_params["padded_capacity"]
                if persistent_params is not None else k_pad
            ),
        )

    def _fused_softmax(self, scores: DeferredScaledMaskedScores) -> TensorHandle:
        if not isinstance(scores, DeferredScaledMaskedScores) or not isinstance(scores.qk, TensorHandle):
            raise TypeError("fused softmax requires deferred GEMM-C scores")
        qk = scores.qk
        params = _physical_parameters(qk)
        config = self.layer_config
        output = torch.ops.vortex.softmax_layout_fused(
            qk.value,
            config.batch_size,
            config.num_attention_heads,
            self._active_sequence_length,
            self._active_key_length,
            params["m_pad"],
            1 if self._active_sequence_length > 1 else 0,
            1.0 / math.sqrt(scores.head_dim),
            params.get("n_pad", self._active_key_length),
            params.get("pv_k_pad", 0),
        )
        output_k_pad = output.shape[-1]
        self._record("softmax_layout_fused", heads=config.num_attention_heads)
        self._transition("gemm_c_tiled", "gemm_a_tiled", reason="scaled_masked_softmax")
        return _make_handle(
            output,
            name="softmax",
            axes=("B", "H", "Sq", "Sk"),
            shape=(
                config.batch_size,
                config.num_attention_heads,
                self._active_sequence_length,
                self._active_key_length,
            ),
            layout="gemm_a_tiled",
            padded_shape=tuple(output.shape),
            producer="softmax_layout_fused",
            grouping="head",
            matrix_count=config.batch_size * config.num_attention_heads,
            m=self._active_sequence_length,
            m_pad=params["m_pad"],
            n=self._active_key_length,
            n_pad=output_k_pad,
        )

    def _fused_head_concat(self, value: TensorHandle) -> TensorHandle:
        params = _physical_parameters(value)
        config = self.layer_config
        output_m_pad = (config.batch_size * self._active_sequence_length + 7) & ~7
        output = torch.ops.vortex.head_concat_layout_fused(
            value.value,
            config.batch_size,
            self._active_sequence_length,
            config.num_attention_heads,
            config.head_dim,
            params["m_pad"],
            output_m_pad,
        )
        self._record("head_concat_layout_fused", heads=config.num_attention_heads)
        self._transition("grouped_gemm_c_tiled", "gemm_a_tiled", reason="head_concat")
        return _make_handle(
            output,
            name="head_concat",
            axes=("B", "S", "C"),
            shape=(config.batch_size, self._active_sequence_length, config.hidden_size),
            layout="gemm_a_tiled",
            padded_shape=tuple(output.shape),
            producer="head_concat_layout_fused",
            m=config.batch_size * self._active_sequence_length,
            m_pad=output_m_pad,
            n=config.hidden_size,
        )

    def _fused_add(self, lhs: torch.Tensor, rhs: TensorHandle) -> torch.Tensor:
        if not isinstance(rhs, TensorHandle):
            return self._standalone_add(lhs, rhs)
        params = _physical_parameters(rhs)
        output = torch.ops.vortex.eladd_layout_fused(
            rhs.value,
            lhs.reshape(params["m"], params["n"]).contiguous(),
            params["m"],
            params["m_pad"],
            params["n"],
        )
        self._record("eladd_layout_fused", M=params["m"], K=params["n"])
        self._transition("gemm_c_tiled+row_major", "row_major", reason="residual_add")
        return output.reshape(lhs.shape)

    def _to_row_major(self, value: TensorHandle, *, reason: str) -> torch.Tensor:
        params = _physical_parameters(value)
        if params.get("matrix_count", 1) != 1:
            raise ValueError("standalone detile boundary requires one combined matrix")
        output = torch.ops.vortex.detile_output(
            value.value,
            params["m"],
            params["m_pad"],
            params["n"],
        )
        self._record("detile_output", reason=reason, M=params["m"], N=params["n"])
        self._transition("gemm_c_tiled", "row_major", reason=reason)
        return output.reshape(value.spec.shape)

    def silu(self, value) -> torch.Tensor:
        if isinstance(value, TensorHandle):
            value = self._to_row_major(value, reason="spinquant_r4_gate")
        self._record("silu", layout="row_major")
        return F.silu(value.contiguous())

    def add(self, lhs, rhs):
        return self.layout_plan.add(lhs, rhs)

    def _standalone_add(self, lhs: torch.Tensor, rhs: torch.Tensor) -> torch.Tensor:
        if lhs.dtype != torch.float16 or rhs.dtype != torch.float16:
            raise TypeError("strict Vortex add requires float16 operands")
        self._record("fp16_add", layout="row_major")
        return lhs.contiguous() + rhs.contiguous()

    def mul(self, lhs: torch.Tensor, rhs) -> torch.Tensor:
        if isinstance(rhs, TensorHandle):
            rhs = self._to_row_major(rhs, reason="spinquant_r4_up")
        if lhs.dtype != torch.float16 or rhs.dtype != torch.float16:
            raise TypeError("strict Vortex mul requires float16 operands")
        self._record("fp16_mul", layout="row_major")
        return lhs.contiguous() * rhs.contiguous()

    def canonicalize(self, value: object) -> torch.Tensor:
        if isinstance(value, DeferredScaledMaskedScores):
            qk = self.canonicalize(value.qk)
            return (
                qk.float() / math.sqrt(value.head_dim)
                + self.tensor("causal_mask").detach().cpu().float()
            ).to(torch.float16)
        if isinstance(value, TensorHandle):
            cache_key = id(value)
            cached = self._canonical_cache.get(cache_key)
            if cached is not None and cached[0] is value:
                return cached[1]
            decoded = decode_physical_tensor(value)
            # Retain the handle with its decoded tensor so CPython cannot
            # recycle the id while this run's cache entry remains live.
            self._canonical_cache[cache_key] = (value, decoded)
            return decoded
        return value.detach().cpu().contiguous()

    def placement_report(self) -> dict:
        return {
            "backend": self.name,
            "strict_native": self.strict_native,
            "physical_plan": self.layout_plan.name,
            "fallback_count": 0,
            "kernel_launches": dict(sorted(self._launches.items())),
            "physical_steps": self._steps,
        }
