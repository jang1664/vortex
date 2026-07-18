"""Reference and Vortex physical backends for the semantic layer graph."""

from __future__ import annotations

import math
import os
from dataclasses import dataclass
from typing import Dict, Iterable, Optional

import torch
import torch.nn.functional as F

from ..utils.hadamard_utils import get_hadK
from .artifacts import LayerCase
from .tensor_io import dequantize_weight, pack_signed_int4, unpack_signed_int4


@dataclass
class QuantizedActivation:
    packed: torch.Tensor
    scale: torch.Tensor
    zero: Optional[torch.Tensor]
    mode: str
    logical_shape: tuple[int, ...]
    unpacked: Optional[torch.Tensor] = None


class Backend:
    """Backend interface. The graph owns semantics; the backend owns storage/layout."""

    name = "abstract"

    def bind(self, case: LayerCase) -> None:
        self.case = case

    def preflight(self, case: LayerCase, stop_after: str) -> None:
        del case, stop_after

    def tensor(self, name: str) -> torch.Tensor:
        raise NotImplementedError

    def rms_norm(self, x: torch.Tensor, weight_name: str, eps: float) -> torch.Tensor:
        raise NotImplementedError

    def linear(self, name: str, x: torch.Tensor) -> torch.Tensor:
        raise NotImplementedError

    def rope(self, x: torch.Tensor) -> torch.Tensor:
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

    def canonicalize(self, value: torch.Tensor) -> torch.Tensor:
        return value.detach().cpu().contiguous()

    def placement_report(self) -> dict:
        return {"backend": self.name, "strict_native": False, "physical_steps": []}


class TorchBackend(Backend):
    """Naive, explicit PyTorch implementation used by CPU tests and CUDA reference."""

    name = "torch"

    def __init__(self, device: str | torch.device = "cuda") -> None:
        self.device = torch.device(device)
        self._tensors: Dict[str, torch.Tensor] = {}
        self._weights: Dict[str, torch.Tensor] = {}

    def bind(self, case: LayerCase) -> None:
        super().bind(case)
        if self.device.type == "cuda":
            if not torch.cuda.is_available():
                raise RuntimeError("CUDA backend requested but torch.cuda.is_available() is false")
            torch.backends.cuda.matmul.allow_tf32 = False
            torch.backends.cudnn.allow_tf32 = False
            torch.use_deterministic_algorithms(True)
        self._tensors = {name: tensor.to(self.device) for name, tensor in case.tensors.items()}
        self._weights.clear()

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
                self.case.config.weight_group_size,
                dtype=torch.float16,
            )
            self._weights[name] = cached
        return cached

    def linear(self, name: str, x: torch.Tensor) -> torch.Tensor:
        shape = x.shape[:-1]
        result = torch.matmul(x.reshape(-1, x.shape[-1]), self._weight(name))
        return result.reshape(*shape, result.shape[-1]).to(torch.float16)

    def rope(self, x: torch.Tensor) -> torch.Tensor:
        cos = self.tensor("rope_cos").unsqueeze(1).float()
        sin = self.tensor("rope_sin").unsqueeze(1).float()
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


class VortexBackend(Backend):
    """Standalone Vortex lowering with explicit layout and strict-op boundaries."""

    name = "vortex"

    REQUIRED_OPS = (
        "rms_norm",
        "apply_rotary_pos_emb",
        "tile_input_a",
        "tile_weight_w4a16",
        "tile_weight_w4a16_ex",
        "tile_scale_zp_w4a16",
        "tile_scale_zp_w4a16_ex",
        "mm_w4a16_gemm_core",
        "detile_output",
        "hadamard_butterfly",
        "hadamard_base",
        "quantize_pack_per_token",
        "qk_asym_correction",
        "head_concat",
    )

    def __init__(self, *, strict_native: bool = True) -> None:
        self.strict_native = strict_native
        # The public "vortex" device name is registered by torch_vortex during
        # preflight, so keep this as a string until then.
        self.device = "vortex"
        self._tensors: Dict[str, torch.Tensor] = {}
        self._weight_layouts: Dict[str, tuple[torch.Tensor, torch.Tensor, torch.Tensor]] = {}
        self._steps: list[dict] = []
        self._launches: Dict[str, int] = {}

    def bind(self, case: LayerCase) -> None:
        import torch_vortex  # noqa: F401

        super().bind(case)
        self._tensors = {name: tensor.to(self.device) for name, tensor in case.tensors.items()}
        self._weight_layouts.clear()
        self._steps.clear()
        self._launches.clear()

    def preflight(self, case: LayerCase, stop_after: str) -> None:
        del stop_after
        if self.strict_native:
            os.environ["TORCH_VORTEX_STRICT_NATIVE"] = "1"
        import torch_vortex  # noqa: F401

        missing = [name for name in self.REQUIRED_OPS if not hasattr(torch.ops.vortex, name)]
        if missing:
            raise RuntimeError(f"Vortex layer-accuracy extension is missing required ops: {missing}")
        if case.config.batch_size != 1 or case.config.sequence_length != 32:
            raise ValueError("Vortex v1 requires B=1 and S=32")
        self._prewarm_kernel_regions(case)

    def _prewarm_kernel_regions(self, case: LayerCase) -> None:
        """Reserve both kernel VMA regions before uploading the real case."""
        x = torch.zeros((8, 32), dtype=torch.float16).to(self.device)
        gamma = torch.ones((32,), dtype=torch.float16).to(self.device)
        # Force a host-visible completion between kernel families.  In the
        # simulator, ready_wait completes the launch but a following kernel
        # image replacement can otherwise race the final device-side drains.
        rms_out = torch.ops.vortex.rms_norm(
            x.reshape(1, 8, 32), gamma, case.config.rms_norm_eps
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

    def _record(self, op: str, **metadata) -> None:
        self._steps.append({"op": op, **metadata})
        self._launches[op] = self._launches.get(op, 0) + 1

    def tensor(self, name: str) -> torch.Tensor:
        return self._tensors[name]

    def rms_norm(self, x: torch.Tensor, weight_name: str, eps: float) -> torch.Tensor:
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
            scales, in_features, out_features, self.case.config.weight_group_size, 0
        )
        zero_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
            zeros, in_features, out_features, self.case.config.weight_group_size, 0
        )
        self._record("tile_static_weight", tensor=name, layout="gemm_w_tiled")
        self._weight_layouts[name] = (weight_tiled, scale_tiled, zero_tiled)
        return self._weight_layouts[name]

    def linear(self, name: str, x: torch.Tensor) -> torch.Tensor:
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
            self.case.config.weight_group_size,
            0,
            0,
        )
        output = torch.ops.vortex.detile_output(output_tiled, m_dim, m_pad, n_dim)
        self._record("w4a16_linear", tensor=name, M=m_dim, K=k_dim, N=n_dim)
        return output.reshape(*shape, n_dim)

    def rope(self, x: torch.Tensor) -> torch.Tensor:
        half = x.shape[-1] // 2
        cos = self.tensor("rope_cos")[..., :half].reshape(-1, half).contiguous()
        sin = self.tensor("rope_sin")[..., :half].reshape(-1, half).contiguous()
        physical = x.permute(0, 2, 1, 3).contiguous()
        output = torch.ops.vortex.apply_rotary_pos_emb(physical, cos, sin, 0)
        self._record("rope", layout_from="BHSD", layout_to="BHSD")
        return output.permute(0, 2, 1, 3).contiguous()

    def hadamard(self, x: torch.Tensor) -> torch.Tensor:
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

    def quantize(self, x: torch.Tensor, mode: str) -> QuantizedActivation:
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
        packed = value.packed.detach().cpu()
        scale = value.scale.detach().cpu().float()
        q = unpack_signed_int4(packed).float()
        if value.mode == "asym":
            assert value.zero is not None
            q -= value.zero.detach().cpu().float()
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
        for head in range(heads):
            x = lhs[0, head].contiguous()
            m_pad = (m_dim + 7) & ~7
            input_tiled = torch.ops.vortex.tile_input_a(x, m_pad, k_dim)
            packed = rhs.packed[0, head].view(torch.uint8).contiguous()
            scale = rhs.scale[0, head].contiguous()
            if transpose_source:
                source_k, source_n = rhs.logical_shape[-2], rhs.logical_shape[-1]
                weight = torch.ops.vortex.tile_weight_w4a16_ex(
                    packed, source_k, source_n, 1, 1
                )
                zeros = torch.zeros(scale.shape, dtype=torch.int16).to(self.device)
                scale_tiled = torch.ops.vortex.tile_scale_zp_w4a16_ex(
                    scale, source_k, source_n, self.case.config.kv_group_size, 1, 0, 1
                )
                zero_tiled = torch.ops.vortex.tile_scale_zp_w4a16_ex(
                    zeros, source_k, source_n, self.case.config.kv_group_size, 1, 0, 1
                )
                wtrans, qdir = 1, 0
            else:
                weight = torch.ops.vortex.tile_weight_w4a16(packed, k_dim, n_dim, 0)
                zeros = torch.zeros(scale.shape, dtype=torch.int16).to(self.device)
                scale_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
                    scale, k_dim, n_dim, self.case.config.kv_group_size, 1
                )
                zero_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
                    zeros, k_dim, n_dim, self.case.config.kv_group_size, 1
                )
                wtrans, qdir = 0, 1
            output_tiled = torch.ops.vortex.mm_w4a16_gemm_core(
                input_tiled,
                weight,
                scale_tiled,
                zero_tiled,
                k_dim,
                n_dim,
                self.case.config.kv_group_size,
                wtrans,
                qdir,
            )
            output = torch.ops.vortex.detile_output(output_tiled, m_dim, m_pad, n_dim)
            if transpose_source:
                assert rhs.zero is not None
                output = torch.ops.vortex.qk_asym_correction(
                    output, x, scale.reshape(-1), rhs.zero[0, head].reshape(-1)
                )
            outputs.append(output)
        self._record(
            "attention_w4a16",
            transpose_source=transpose_source,
            heads=heads,
            M=m_dim,
            K=k_dim,
            N=n_dim,
        )
        stacked = torch.empty((1, heads, m_dim, n_dim), dtype=torch.float16, device=self.device)
        for head, output in enumerate(outputs):
            stacked[0, head].copy_(output)
        self._record("head_stack_layout_copy", implementation="host_staged_device_copy")
        return stacked

    def qk(self, q: torch.Tensor, k: QuantizedActivation) -> torch.Tensor:
        return self._attention_core(q, k, transpose_source=True)

    def scaled_masked_scores(self, qk: torch.Tensor, head_dim: int) -> torch.Tensor:
        del head_dim
        scaled = qk.contiguous() * self.tensor("score_scale")
        mask = self.tensor("causal_mask").expand_as(qk).contiguous()
        self._record("scale_scores", layout="BHSS")
        self._record("add_causal_mask", layout="BHSS")
        return scaled + mask

    def softmax(self, scores: torch.Tensor) -> torch.Tensor:
        self._record("softmax", axis="S")
        return torch.softmax(scores.contiguous(), dim=-1)

    def pv(self, probabilities: torch.Tensor, v: QuantizedActivation) -> torch.Tensor:
        return self._attention_core(probabilities, v, transpose_source=False)

    def head_concat(self, value: torch.Tensor) -> torch.Tensor:
        self._record("head_concat", layout_from="BHSD", layout_to="BSC")
        return torch.ops.vortex.head_concat(value.contiguous())

    def silu(self, value: torch.Tensor) -> torch.Tensor:
        self._record("silu", layout="row_major")
        return F.silu(value.contiguous())

    def add(self, lhs: torch.Tensor, rhs: torch.Tensor) -> torch.Tensor:
        if lhs.dtype != torch.float16 or rhs.dtype != torch.float16:
            raise TypeError("strict Vortex add requires float16 operands")
        self._record("fp16_add", layout="row_major")
        return lhs.contiguous() + rhs.contiguous()

    def mul(self, lhs: torch.Tensor, rhs: torch.Tensor) -> torch.Tensor:
        if lhs.dtype != torch.float16 or rhs.dtype != torch.float16:
            raise TypeError("strict Vortex mul requires float16 operands")
        self._record("fp16_mul", layout="row_major")
        return lhs.contiguous() * rhs.contiguous()

    def canonicalize(self, value: torch.Tensor) -> torch.Tensor:
        return value.detach().cpu().contiguous()

    def placement_report(self) -> dict:
        return {
            "backend": self.name,
            "strict_native": self.strict_native,
            "fallback_count": 0,
            "kernel_launches": dict(sorted(self._launches.items())),
            "physical_steps": self._steps,
        }
