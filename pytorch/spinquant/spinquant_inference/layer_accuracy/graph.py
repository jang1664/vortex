"""Backend-independent semantic schedule for one SpinQuant Llama decoder layer."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Dict, List, Literal, Optional

import torch

from .artifacts import DecodeCase, LayerCase, graph_version
from .backends import Backend, QuantizedActivation
from .stages import (
    DECODE_STAGE_INDEX,
    DECODE_STAGE_NAMES,
    STAGE_INDEX,
    STAGE_NAMES,
    DecodeStopPoint,
    validate_stop_stage,
)
from .specs import LayerConfig, PersistentCache


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
    artifact_metadata: dict = field(default_factory=dict)


@dataclass
class DecodeStepResult:
    step: int
    logical_length: int
    stage_order: List[str]
    captures: Dict[str, torch.Tensor]
    auxiliary_captures: Dict[str, torch.Tensor]
    physical_captures: Dict[str, torch.Tensor]
    physical_descriptors: Dict[str, dict]
    cache_descriptor: dict


@dataclass
class DecodeRunResult:
    backend: str
    case_hash: str
    graph_version: str
    stop_after: DecodeStopPoint
    prefill: DecodeStepResult
    steps: List[DecodeStepResult]
    cache_descriptor: dict
    placement: dict


class _StopExecution(Exception):
    pass


def _execute_layer_schedule(
    backend: Backend,
    config: LayerConfig,
    record: Callable[..., None],
    record_quantized: Callable[[str, QuantizedActivation], None],
    cache_update: Optional[
        Callable[
            [QuantizedActivation, QuantizedActivation],
            tuple[QuantizedActivation, QuantizedActivation, object, dict],
        ]
    ] = None,
) -> None:
    """Run the shared decoder-layer semantics with an optional persistent KV hook."""

    residual = backend.tensor("input")
    normalized = backend.rms_norm(residual, "input_norm.weight", config.rms_norm_eps)
    record("input_norm", normalized)
    q_linear = backend.linear("q_proj", normalized)
    record("q_proj", q_linear)
    k_linear = backend.linear("k_proj", normalized)
    record("k_proj", k_linear)
    v_linear = backend.linear("v_proj", normalized)
    record("v_proj", v_linear)

    q = backend.rope(backend.split_heads(q_linear))
    record("q_rope", q)
    k = backend.rope(backend.split_heads(k_linear))
    record("k_rope", k)
    q = backend.hadamard(q)
    record("q_r3", q)
    k = backend.hadamard(k)
    record("k_r3", k)

    k_quantized = backend.quantize(k, "asym")
    record_quantized("k_quant", k_quantized)
    value_states = backend.split_heads(v_linear)
    v_quantized = backend.quantize(value_states, "sym")
    record_quantized("v_quant", v_quantized)
    if cache_update is not None:
        k_quantized, v_quantized, cache_capture, cache_extra = cache_update(
            k_quantized, v_quantized
        )
        record("cache_update", cache_capture, **cache_extra)

    scores = backend.qk(q, k_quantized)
    record("qk", scores)
    scores = backend.scaled_masked_scores(scores, config.head_dim)
    record("scaled_masked_scores", scores)
    probabilities = backend.softmax(scores)
    record("softmax", probabilities)
    attention = backend.pv(probabilities, v_quantized)
    record("pv", attention)
    attention = backend.head_concat(attention)
    record("head_concat", attention)
    attention = backend.linear("o_proj", attention)
    record("o_proj", attention)
    residual = backend.add(residual, attention)
    record("attn_residual", residual)

    normalized = backend.rms_norm(
        residual, "post_attention_norm.weight", config.rms_norm_eps
    )
    record("post_attn_norm", normalized)
    gate = backend.linear("gate_proj", normalized)
    record("gate_proj", gate)
    up = backend.linear("up_proj", normalized)
    record("up_proj", up)
    activated = backend.silu(gate)
    record("silu", activated)
    mlp = backend.mul(activated, up)
    record("mlp_mul", mlp)
    mlp = backend.hadamard(mlp)
    record("r4", mlp)
    mlp = backend.linear("down_proj", mlp)
    record("down_proj", mlp)
    output = backend.add(residual, mlp)
    record("final_residual", output)


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
        self.backend.activate(
            self.backend.tensor("input"),
            self.backend.tensor("position_ids"),
            self.backend.tensor("causal_mask"),
        )
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
        try:
            _execute_layer_schedule(
                self.backend, config, record, record_quantized
            )
        except _StopExecution:
            pass

        return RunResult(
            backend=self.backend.name,
            case_hash=case.manifest["case_hash"],
            graph_version=case.manifest.get("graph_version", graph_version(case.config)),
            stop_after=stop_after,
            stage_order=stage_order,
            captures=captures,
            auxiliary_captures=auxiliary,
            physical_captures=physical,
            physical_descriptors=physical_descriptors,
            placement=self.backend.placement_report(),
        )


class DecodeExecutor:
    """Backend-neutral prompt prefill plus ordered one-token decode schedule."""

    def __init__(self, backend: Backend) -> None:
        self.backend = backend

    def run(
        self,
        case: DecodeCase,
        *,
        stop_after: Optional[DecodeStopPoint] = None,
        capture_physical: bool = False,
    ) -> DecodeRunResult:
        stop_after = stop_after or DecodeStopPoint(
            step=case.config.decode_steps - 1, stage="final_residual"
        )
        stop_after.validate(decode_steps=case.config.decode_steps)
        self.backend.preflight(case, f"decode:{stop_after.step}:{stop_after.stage}")
        self.backend.bind(case)
        cache = self.backend.create_persistent_cache(case.config)

        prompt_length = case.config.prompt_length
        full_causal_mask = self.backend.tensor("causal_mask")
        prompt_mask = full_causal_mask[
            :, :, :prompt_length, :prompt_length
        ]
        prefill = self._run_active(
            case,
            cache,
            step=-1,
            input_tensor=self.backend.tensor("prompt_input"),
            position_ids=self.backend.tensor("prompt_position_ids"),
            causal_mask=prompt_mask,
            update="prefill",
            stop_index=None,
            capture_physical=capture_physical,
        )

        steps: List[DecodeStepResult] = []
        for step in range(case.config.decode_steps):
            logical_after_append = cache.logical_length + 1
            decode_mask = full_causal_mask[
                :,
                :,
                logical_after_append - 1 : logical_after_append,
                :logical_after_append,
            ]
            step_stop = (
                DECODE_STAGE_INDEX[stop_after.stage]
                if step == stop_after.step
                else None
            )
            result = self._run_active(
                case,
                cache,
                step=step,
                input_tensor=self.backend.tensor("decode_inputs")[step, :, 0:1],
                position_ids=self.backend.tensor("decode_position_ids")[step, :, 0:1],
                causal_mask=decode_mask,
                update="append",
                stop_index=step_stop,
                capture_physical=capture_physical,
            )
            steps.append(result)
            if step == stop_after.step:
                break

        return DecodeRunResult(
            backend=self.backend.name,
            case_hash=case.manifest["case_hash"],
            graph_version=case.manifest.get(
                "graph_version", graph_version(case.config.layer, decode=True)
            ),
            stop_after=stop_after,
            prefill=prefill,
            steps=steps,
            cache_descriptor=cache.descriptor(),
            placement=self.backend.placement_report(),
        )

    def _run_active(
        self,
        case: DecodeCase,
        cache: PersistentCache,
        *,
        step: int,
        input_tensor: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
        update: Literal["prefill", "append"],
        stop_index: Optional[int],
        capture_physical: bool,
    ) -> DecodeStepResult:
        self.backend.activate(input_tensor, position_ids, causal_mask)
        captures: Dict[str, torch.Tensor] = {}
        auxiliary: Dict[str, torch.Tensor] = {}
        physical: Dict[str, torch.Tensor] = {}
        descriptors: Dict[str, dict] = {}
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
            descriptors[name] = {**descriptor, "buffers": buffer_names}

        def record(stage: str, value: object, **extra: object) -> None:
            actual_index = DECODE_STAGE_INDEX[stage]
            expected_index = len(stage_order)
            if actual_index != expected_index:
                raise RuntimeError(
                    f"decode schedule drift: expected "
                    f"{DECODE_STAGE_NAMES[expected_index]!r}, got {stage!r}"
                )
            captures[stage] = self.backend.canonicalize(value)
            record_physical(stage, value)
            for name, tensor in extra.items():
                capture_name = f"{stage}.{name}"
                auxiliary[capture_name] = self.backend.canonicalize(tensor)
                record_physical(capture_name, tensor)
            stage_order.append(stage)
            if stop_index == actual_index:
                raise _StopExecution

        def record_quantized(stage: str, value: QuantizedActivation) -> None:
            extra = {"packed": value.packed, "scale": value.scale}
            if value.zero is not None:
                extra["zero"] = value.zero
            record(stage, self.backend.quantized_capture(value), **extra)

        config = case.config.layer
        def update_cache(
            k_quantized: QuantizedActivation,
            v_quantized: QuantizedActivation,
        ) -> tuple[QuantizedActivation, QuantizedActivation, object, dict]:
            assert k_quantized.zero is not None
            if update == "prefill":
                cache.prefill_quantized(
                    k_quantized.packed,
                    k_quantized.scale,
                    k_quantized.zero,
                    v_quantized.packed,
                    v_quantized.scale,
                )
            elif update == "append":
                cache.append_quantized(
                    k_quantized.packed,
                    k_quantized.scale,
                    k_quantized.zero,
                    v_quantized.packed,
                    v_quantized.scale,
                    position=cache.logical_length,
                )
            else:
                raise AssertionError(f"unsupported cache update {update!r}")
            key_cache, value_cache = cache.get_kv()
            qkey, k_scale, k_zero = key_cache
            qvalue, v_scale, _ = value_cache
            semantic_key, semantic_value = cache.dequantized_kv()
            cached_key = QuantizedActivation(
                packed=qkey,
                scale=k_scale,
                zero=k_zero,
                mode="asym",
                logical_shape=tuple(semantic_key.shape),
                weight_tiled=getattr(qkey, "attachments", {}).get("weight_tiled"),
                scale_tiled=getattr(k_scale, "attachments", {}).get("scale_tiled"),
                zero_tiled=getattr(k_zero, "attachments", {}).get("zero_tiled"),
                dequantized=semantic_key,
            )
            cached_value = QuantizedActivation(
                packed=qvalue,
                scale=v_scale,
                zero=None,
                mode="sym",
                logical_shape=tuple(semantic_value.shape),
                weight_tiled=getattr(qvalue, "attachments", {}).get("weight_tiled"),
                scale_tiled=getattr(v_scale, "attachments", {}).get("scale_tiled"),
                zero_tiled=getattr(v_scale, "attachments", {}).get("zero_tiled"),
                dequantized=semantic_value,
            )
            return (
                cached_key,
                cached_value,
                torch.stack((semantic_key, semantic_value)),
                {
                    "k_packed": qkey,
                    "k_scale": k_scale,
                    "k_zero": k_zero,
                    "v_packed": qvalue,
                    "v_scale": v_scale,
                },
            )

        try:
            _execute_layer_schedule(
                self.backend,
                config,
                record,
                record_quantized,
                cache_update=update_cache,
            )
        except _StopExecution:
            pass

        return DecodeStepResult(
            step=step,
            logical_length=cache.logical_length,
            stage_order=stage_order,
            captures=captures,
            auxiliary_captures=auxiliary,
            physical_captures=physical,
            physical_descriptors=descriptors,
            cache_descriptor=cache.descriptor(),
        )
