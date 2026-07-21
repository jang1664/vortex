"""Serialization for backend run captures and physical-plan metadata."""

from __future__ import annotations

import json
from pathlib import Path

import torch

from .graph import DecodeRunResult, RunResult, StackRunResult
from .tensor_io import tensor_sha256


RUN_SCHEMA_VERSION = 1


def save_run(result: RunResult, path: str | Path, *, capture_mode: str) -> None:
    if capture_mode not in ("semantic", "physical", "both"):
        raise ValueError(f"invalid capture mode {capture_mode!r}")
    destination = Path(path)
    destination.mkdir(parents=True, exist_ok=False)
    save_semantic = capture_mode in ("semantic", "both")
    save_physical = capture_mode in ("physical", "both")
    capture_hashes = {}
    auxiliary_hashes = {}
    physical_hashes = {}
    if save_semantic:
        torch.save(result.captures, destination / "captures.pt")
        torch.save(result.auxiliary_captures, destination / "auxiliary_captures.pt")
        capture_hashes = {
            name: tensor_sha256(tensor) for name, tensor in sorted(result.captures.items())
        }
        auxiliary_hashes = {
            name: tensor_sha256(tensor)
            for name, tensor in sorted(result.auxiliary_captures.items())
        }
    if save_physical:
        if not result.physical_captures:
            raise ValueError("physical capture mode requires LayerExecutor(capture_physical=True)")
        torch.save(result.physical_captures, destination / "physical_captures.pt")
        physical_hashes = {
            name: tensor_sha256(tensor)
            for name, tensor in sorted(result.physical_captures.items())
        }
        (destination / "physical_descriptors.json").write_text(
            json.dumps(result.physical_descriptors, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    metadata = {
        "schema_version": RUN_SCHEMA_VERSION,
        "backend": result.backend,
        "case_hash": result.case_hash,
        "graph_version": result.graph_version,
        "stop_after": result.stop_after,
        "stage_order": result.stage_order,
        "capture_mode": capture_mode,
        "capture_hashes": capture_hashes,
        "auxiliary_capture_hashes": auxiliary_hashes,
        "physical_capture_hashes": physical_hashes,
        "placement": result.placement,
    }
    metadata.update(result.artifact_metadata)
    (destination / "run.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (destination / "physical_plan.json").write_text(
        json.dumps(result.placement, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def save_decode_run(
    result: DecodeRunResult, path: str | Path, *, capture_mode: str
) -> None:
    """Serialize prompt and per-token captures with stable qualified names."""

    def flatten(attribute: str) -> dict:
        values = {
            f"prefill.{name}": tensor
            for name, tensor in getattr(result.prefill, attribute).items()
        }
        for step in result.steps:
            values.update(
                {
                    f"step{step.step}.{name}": tensor
                    for name, tensor in getattr(step, attribute).items()
                }
            )
        return values

    stage_order = [f"prefill.{name}" for name in result.prefill.stage_order]
    for step in result.steps:
        stage_order.extend(f"step{step.step}.{name}" for name in step.stage_order)
    flattened = RunResult(
        backend=result.backend,
        case_hash=result.case_hash,
        graph_version=result.graph_version,
        stop_after=f"step{result.stop_after.step}:{result.stop_after.stage}",
        stage_order=stage_order,
        captures=flatten("captures"),
        auxiliary_captures=flatten("auxiliary_captures"),
        physical_captures=flatten("physical_captures"),
        physical_descriptors=flatten("physical_descriptors"),
        placement=result.placement,
        artifact_metadata={
            "run_kind": "decode",
            "stop_after": {
                "step": result.stop_after.step,
                "stage": result.stop_after.stage,
            },
            "prefill": {
                "logical_length": result.prefill.logical_length,
                "stage_order": result.prefill.stage_order,
                "cache_descriptor": result.prefill.cache_descriptor,
            },
            "steps": [
                {
                    "step": step.step,
                    "logical_length": step.logical_length,
                    "stage_order": step.stage_order,
                    "cache_descriptor": step.cache_descriptor,
                }
                for step in result.steps
            ],
            "cache_descriptor": result.cache_descriptor,
        },
    )
    save_run(flattened, path, capture_mode=capture_mode)


def save_stack_run(
    result: StackRunResult, path: str | Path, *, capture_mode: str
) -> None:
    flattened = RunResult(
        backend=result.backend,
        case_hash=result.case_hash,
        graph_version=result.graph_version,
        stop_after=f"layer{result.stop_after_layer}:{result.stop_after}",
        stage_order=[
            f"layer{layer.layer_index}.{stage}"
            for layer in result.layers
            for stage in layer.stage_order
        ],
        captures=result.captures,
        auxiliary_captures=result.auxiliary_captures,
        physical_captures=result.physical_captures,
        physical_descriptors=result.physical_descriptors,
        placement=result.placement,
        artifact_metadata={
            "run_kind": "decoder_stack",
            "stop_after": {
                "layer": result.stop_after_layer,
                "stage": result.stop_after,
            },
            "layers": [
                {
                    "layer_index": layer.layer_index,
                    "stop_after": layer.stop_after,
                    "stage_order": layer.stage_order,
                    "placement": layer.placement,
                }
                for layer in result.layers
            ],
        },
    )
    save_run(flattened, path, capture_mode=capture_mode)


def load_decode_run(
    path: str | Path,
) -> tuple[dict, dict[str, torch.Tensor], dict[str, torch.Tensor]]:
    return _load_typed_run(path, expected_kind="decode", label="decode")


def load_stack_run(
    path: str | Path,
) -> tuple[dict, dict[str, torch.Tensor], dict[str, torch.Tensor]]:
    return _load_typed_run(
        path, expected_kind="decoder_stack", label="decoder stack"
    )


def _load_typed_run(
    path: str | Path,
    *,
    expected_kind: str,
    label: str,
) -> tuple[dict, dict[str, torch.Tensor], dict[str, torch.Tensor]]:
    metadata_path = Path(path) / "run.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if metadata.get("run_kind") != expected_kind:
        raise ValueError(f"run is not a {label} artifact")
    return load_run(path)


def load_run(path: str | Path) -> tuple[dict, dict[str, torch.Tensor], dict[str, torch.Tensor]]:
    source = Path(path)
    metadata = json.loads((source / "run.json").read_text(encoding="utf-8"))
    if metadata.get("schema_version") != RUN_SCHEMA_VERSION:
        raise ValueError(f"unsupported run schema version {metadata.get('schema_version')!r}")
    if metadata.get("capture_mode") == "physical":
        raise ValueError("run contains physical captures only; use load_physical_run")
    captures = torch.load(source / "captures.pt", map_location="cpu", weights_only=True)
    auxiliary = torch.load(
        source / "auxiliary_captures.pt", map_location="cpu", weights_only=True
    )
    _validate_hashes("capture", captures, metadata.get("capture_hashes", {}))
    _validate_hashes("auxiliary capture", auxiliary, metadata.get("auxiliary_capture_hashes", {}))
    return metadata, captures, auxiliary


def load_physical_run(path: str | Path) -> tuple[dict, dict[str, torch.Tensor], dict[str, dict]]:
    source = Path(path)
    metadata = json.loads((source / "run.json").read_text(encoding="utf-8"))
    if metadata.get("schema_version") != RUN_SCHEMA_VERSION:
        raise ValueError(f"unsupported run schema version {metadata.get('schema_version')!r}")
    if metadata.get("capture_mode") not in ("physical", "both"):
        raise ValueError("run does not contain physical captures")
    captures = torch.load(
        source / "physical_captures.pt", map_location="cpu", weights_only=True
    )
    descriptors = json.loads(
        (source / "physical_descriptors.json").read_text(encoding="utf-8")
    )
    _validate_hashes(
        "physical capture", captures, metadata.get("physical_capture_hashes", {})
    )
    return metadata, captures, descriptors


def _validate_hashes(kind: str, tensors: dict[str, torch.Tensor], expected: dict[str, str]) -> None:
    if set(tensors) != set(expected):
        raise ValueError(f"{kind} set does not match run metadata")
    for name, tensor in tensors.items():
        actual = tensor_sha256(tensor)
        if actual != expected[name]:
            raise ValueError(f"{kind} checksum mismatch for {name}: {actual} != {expected[name]}")
