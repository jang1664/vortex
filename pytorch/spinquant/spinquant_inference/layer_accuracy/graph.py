"""Backend-independent semantic schedule for one SpinQuant Llama decoder layer."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List

import torch

from .artifacts import GRAPH_VERSION, LayerCase
from .backends import Backend, QuantizedActivation
from .stages import STAGE_INDEX, STAGE_NAMES, validate_stop_stage


@dataclass
class RunResult:
    backend: str
    case_hash: str
    graph_version: str
    stop_after: str
    stage_order: List[str]
    captures: Dict[str, torch.Tensor]
    auxiliary_captures: Dict[str, torch.Tensor]
    physical_captures: Dict[str, torch.Tensor]
    physical_descriptors: Dict[str, dict]
    placement: dict


class _StopExecution(Exception):
    pass


class LayerExecutor:
    def __init__(self, backend: Backend) -> None:
        self.backend = backend

    def run(
        self,
        case: LayerCase,
        *,
        stop_after: str = "final_residual",
        capture_physical: bool = False,
    ) -> RunResult:
        stop_index = validate_stop_stage(stop_after)
        self.backend.preflight(case, stop_after)
        self.backend.bind(case)
        captures: Dict[str, torch.Tensor] = {}
        auxiliary: Dict[str, torch.Tensor] = {}
        physical: Dict[str, torch.Tensor] = {}
        physical_descriptors: Dict[str, dict] = {}
        stage_order: List[str] = []

        def record_physical(name: str, value: object) -> None:
            if not capture_physical:
                return
            buffers, descriptor = self.backend.capture_physical(value)
            buffer_names = []
            for index, buffer in enumerate(buffers):
                buffer_name = name if len(buffers) == 1 else f"{name}.buffer{index}"
                physical[buffer_name] = buffer
                buffer_names.append(buffer_name)
            physical_descriptors[name] = {**descriptor, "buffers": buffer_names}

        def record(stage: str, value: object, **extra: object) -> None:
            expected_index = len(stage_order)
            actual_index = STAGE_INDEX[stage]
            if actual_index != expected_index:
                raise RuntimeError(
                    f"semantic schedule drift: expected {STAGE_NAMES[expected_index]!r}, got {stage!r}"
                )
            captures[stage] = self.backend.canonicalize(value)
            record_physical(stage, value)
            for name, tensor in extra.items():
                capture_name = f"{stage}.{name}"
                auxiliary[capture_name] = self.backend.canonicalize(tensor)
                record_physical(capture_name, tensor)
            stage_order.append(stage)
            if actual_index == stop_index:
                raise _StopExecution

        def record_quantized(stage: str, value: QuantizedActivation) -> None:
            primary = self.backend.quantized_capture(value)
            extra = {"packed": value.packed, "scale": value.scale}
            if value.zero is not None:
                extra["zero"] = value.zero
            record(stage, primary, **extra)

        config = case.config
        residual = self.backend.tensor("input")
        try:
            normalized = self.backend.rms_norm(
                residual, "input_norm.weight", config.rms_norm_eps
            )
            record("input_norm", normalized)

            q_linear = self.backend.linear("q_proj", normalized)
            record("q_proj", q_linear)
            k_linear = self.backend.linear("k_proj", normalized)
            record("k_proj", k_linear)
            v_linear = self.backend.linear("v_proj", normalized)
            record("v_proj", v_linear)

            q = self.backend.rope(self.backend.split_heads(q_linear))
            record("q_rope", q)
            k = self.backend.rope(self.backend.split_heads(k_linear))
            record("k_rope", k)

            q = self.backend.hadamard(q)
            record("q_r3", q)
            k = self.backend.hadamard(k)
            record("k_r3", k)

            k_quantized = self.backend.quantize(k, "asym")
            record_quantized("k_quant", k_quantized)
            v_quantized = self.backend.quantize(self.backend.split_heads(v_linear), "sym")
            record_quantized("v_quant", v_quantized)

            scores = self.backend.qk(q, k_quantized)
            record("qk", scores)
            scores = self.backend.scaled_masked_scores(scores, config.head_dim)
            record("scaled_masked_scores", scores)
            probabilities = self.backend.softmax(scores)
            record("softmax", probabilities)
            attention = self.backend.pv(probabilities, v_quantized)
            record("pv", attention)
            attention = self.backend.head_concat(attention)
            record("head_concat", attention)

            attention = self.backend.linear("o_proj", attention)
            record("o_proj", attention)
            residual = self.backend.add(residual, attention)
            record("attn_residual", residual)

            normalized = self.backend.rms_norm(
                residual, "post_attention_norm.weight", config.rms_norm_eps
            )
            record("post_attn_norm", normalized)
            gate = self.backend.linear("gate_proj", normalized)
            record("gate_proj", gate)
            up = self.backend.linear("up_proj", normalized)
            record("up_proj", up)
            activated = self.backend.silu(gate)
            record("silu", activated)
            mlp = self.backend.mul(activated, up)
            record("mlp_mul", mlp)
            mlp = self.backend.hadamard(mlp)
            record("r4", mlp)
            mlp = self.backend.linear("down_proj", mlp)
            record("down_proj", mlp)
            output = self.backend.add(residual, mlp)
            record("final_residual", output)
        except _StopExecution:
            pass

        return RunResult(
            backend=self.backend.name,
            case_hash=case.manifest["case_hash"],
            graph_version=GRAPH_VERSION,
            stop_after=stop_after,
            stage_order=stage_order,
            captures=captures,
            auxiliary_captures=auxiliary,
            physical_captures=physical,
            physical_descriptors=physical_descriptors,
            placement=self.backend.placement_report(),
        )
