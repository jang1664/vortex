"""Portable, checksum-protected test case and run artifacts."""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Mapping

import torch

from .specs import LayerConfig
from .tensor_io import pack_signed_int4, tensor_sha256


CASE_SCHEMA_VERSION = 1
GRAPH_VERSION = "llama2_decoder_layer_r3r4_v1"
PROJECTION_DIMS = {
    "q_proj": ("hidden_size", "hidden_size"),
    "k_proj": ("hidden_size", "hidden_size"),
    "v_proj": ("hidden_size", "hidden_size"),
    "o_proj": ("hidden_size", "hidden_size"),
    "gate_proj": ("hidden_size", "intermediate_size"),
    "up_proj": ("hidden_size", "intermediate_size"),
    "down_proj": ("intermediate_size", "hidden_size"),
}


@dataclass
class LayerCase:
    config: LayerConfig
    tensors: Dict[str, torch.Tensor]
    manifest: dict


def _canonical_json(value: Mapping) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _case_hash(manifest: Mapping) -> str:
    without_hash = {key: value for key, value in manifest.items() if key != "case_hash"}
    return hashlib.sha256(_canonical_json(without_hash)).hexdigest()


def _projection_shape(config: LayerConfig, projection: str) -> tuple[int, int]:
    in_name, out_name = PROJECTION_DIMS[projection]
    return getattr(config, in_name), getattr(config, out_name)


def _quantize_random_weight(
    in_features: int,
    out_features: int,
    group_size: int,
    generator: torch.Generator,
) -> tuple[torch.Tensor, torch.Tensor]:
    weight = torch.randn(in_features, out_features, generator=generator, dtype=torch.float32)
    weight.mul_(1.0 / math.sqrt(in_features))
    groups = weight.reshape(in_features // group_size, group_size, out_features)
    scales = groups.abs().amax(dim=1).clamp_min_(1e-8).div_(7.0)
    quantized = torch.round(groups / scales.unsqueeze(1)).clamp_(-8, 7).to(torch.int8)
    quantized = quantized.reshape(in_features, out_features)
    return pack_signed_int4(quantized), scales.to(torch.float16)


def _rope_tables(config: LayerConfig) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    positions = torch.arange(config.sequence_length, dtype=torch.long).view(1, -1)
    exponent = torch.arange(0, config.head_dim, 2, dtype=torch.float32) / config.head_dim
    inv_freq = 1.0 / (config.rope_theta**exponent)
    frequencies = torch.outer(positions[0].float(), inv_freq)
    embedding = torch.cat((frequencies, frequencies), dim=-1)
    return positions, embedding.cos().to(torch.float16).unsqueeze(0), embedding.sin().to(torch.float16).unsqueeze(0)


def _causal_mask(config: LayerConfig) -> torch.Tensor:
    mask = torch.full(
        (config.sequence_length, config.sequence_length),
        torch.finfo(torch.float16).min,
        dtype=torch.float16,
    )
    return torch.triu(mask, diagonal=1).view(1, 1, config.sequence_length, config.sequence_length)


def _build_manifest(
    config: LayerConfig,
    tensors: Mapping[str, torch.Tensor],
    *,
    source: str,
    seed: int | None,
    layer_index: int,
    checkpoint_profile: str,
) -> dict:
    tensor_hashes = {name: tensor_sha256(tensor) for name, tensor in sorted(tensors.items())}
    manifest = {
        "schema_version": CASE_SCHEMA_VERSION,
        "graph_version": GRAPH_VERSION,
        "source": source,
        "seed": seed,
        "layer_index": layer_index,
        "checkpoint_profile": checkpoint_profile,
        "config": config.to_dict(),
        "weight_quantization": {
            "bits": 4,
            "signed": True,
            "mode": "sym",
            "group_size": config.weight_group_size,
            "group_axis": "input",
            "scale_dtype": "float16",
            "nibble_order": "low_first",
        },
        "kv_quantization": {
            "bits": 4,
            "signed": True,
            "group_size": config.kv_group_size,
            "group_axis": "head_dim",
            "key_mode": "asym",
            "value_mode": "sym",
            "scale_dtype": "float16",
            "zero_dtype": "float16",
            "nibble_order": "low_first",
        },
        "rotation_contract": {
            "offline_folded_r1_r2": True,
            "residual_basis": "spinquant_rotated",
            "online_r3": "post_rope_q_and_k",
            "online_r4": "pre_down_projection_exact_172x64",
        },
        "tensor_hashes": tensor_hashes,
    }
    manifest["case_hash"] = _case_hash(manifest)
    return manifest


def create_random_case(config: LayerConfig | None = None, *, seed: int = 0) -> LayerCase:
    config = config or LayerConfig()
    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)

    tensors: Dict[str, torch.Tensor] = {
        "input": torch.randn(
            config.batch_size,
            config.sequence_length,
            config.hidden_size,
            generator=generator,
            dtype=torch.float16,
        ),
        "input_norm.weight": (
            1.0 + 0.02 * torch.randn(config.hidden_size, generator=generator)
        ).to(torch.float16),
        "post_attention_norm.weight": (
            1.0 + 0.02 * torch.randn(config.hidden_size, generator=generator)
        ).to(torch.float16),
    }
    position_ids, rope_cos, rope_sin = _rope_tables(config)
    tensors.update(
        {
            "position_ids": position_ids,
            "rope_cos": rope_cos,
            "rope_sin": rope_sin,
            "causal_mask": _causal_mask(config),
            "score_scale": torch.full(
                (
                    config.batch_size,
                    config.num_attention_heads,
                    config.sequence_length,
                    config.sequence_length,
                ),
                1.0 / math.sqrt(config.head_dim),
                dtype=torch.float16,
            ),
        }
    )
    for projection in PROJECTION_DIMS:
        in_features, out_features = _projection_shape(config, projection)
        packed, scales = _quantize_random_weight(
            in_features, out_features, config.weight_group_size, generator
        )
        tensors[f"{projection}.qweight"] = packed
        tensors[f"{projection}.scales"] = scales

    manifest = _build_manifest(
        config,
        tensors,
        source="random",
        seed=seed,
        layer_index=0,
        checkpoint_profile="spinquant-w4a16-r3r4",
    )
    return LayerCase(config, tensors, manifest)


def _required_checkpoint_tensors(config: LayerConfig, layer_index: int) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    prefix = f"model.layers.{layer_index}."
    required: dict[str, tuple[tuple[int, ...], torch.dtype]] = {
        f"{prefix}input_layernorm.weight": ((config.hidden_size,), torch.float16),
        f"{prefix}post_attention_layernorm.weight": ((config.hidden_size,), torch.float16),
    }
    checkpoint_names = {
        "q_proj": "self_attn.q_proj",
        "k_proj": "self_attn.k_proj",
        "v_proj": "self_attn.v_proj",
        "o_proj": "self_attn.o_proj",
        "gate_proj": "mlp.gate_proj",
        "up_proj": "mlp.up_proj",
        "down_proj": "mlp.down_proj",
    }
    for projection, checkpoint_name in checkpoint_names.items():
        in_features, out_features = _projection_shape(config, projection)
        required[f"{prefix}{checkpoint_name}.qweight"] = (
            (in_features, out_features // 2),
            torch.int8,
        )
        required[f"{prefix}{checkpoint_name}.scales"] = (
            (in_features // config.weight_group_size, out_features),
            torch.float16,
        )
    return required


def create_checkpoint_case(
    checkpoint: str | Path,
    *,
    layer_index: int,
    checkpoint_profile: str,
    config: LayerConfig | None = None,
    seed: int = 0,
) -> LayerCase:
    if checkpoint_profile != "spinquant-w4a16-r3r4":
        raise ValueError("checkpoint_profile must explicitly be spinquant-w4a16-r3r4")
    config = config or LayerConfig()
    state = torch.load(Path(checkpoint), map_location="cpu", weights_only=True, mmap=True)
    if not isinstance(state, dict):
        raise TypeError("checkpoint must contain a state_dict mapping")

    required = _required_checkpoint_tensors(config, layer_index)
    missing = sorted(set(required) - set(state))
    if missing:
        raise ValueError(f"checkpoint is missing required layer tensors: {missing}")
    for key, (shape, dtype) in required.items():
        tensor = state[key]
        if not isinstance(tensor, torch.Tensor):
            raise TypeError(f"checkpoint value {key} is not a tensor")
        if tuple(tensor.shape) != shape or tensor.dtype != dtype:
            raise ValueError(
                f"checkpoint tensor {key} expected shape={shape}, dtype={dtype}; "
                f"got shape={tuple(tensor.shape)}, dtype={tensor.dtype}"
            )

    prefix = f"model.layers.{layer_index}."
    rename = {
        "input_norm.weight": f"{prefix}input_layernorm.weight",
        "post_attention_norm.weight": f"{prefix}post_attention_layernorm.weight",
        "q_proj": f"{prefix}self_attn.q_proj",
        "k_proj": f"{prefix}self_attn.k_proj",
        "v_proj": f"{prefix}self_attn.v_proj",
        "o_proj": f"{prefix}self_attn.o_proj",
        "gate_proj": f"{prefix}mlp.gate_proj",
        "up_proj": f"{prefix}mlp.up_proj",
        "down_proj": f"{prefix}mlp.down_proj",
    }
    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    tensors: Dict[str, torch.Tensor] = {
        "input": torch.randn(
            config.batch_size,
            config.sequence_length,
            config.hidden_size,
            generator=generator,
            dtype=torch.float16,
        ),
        "input_norm.weight": state[rename["input_norm.weight"]].contiguous(),
        "post_attention_norm.weight": state[rename["post_attention_norm.weight"]].contiguous(),
    }
    positions, cos, sin = _rope_tables(config)
    tensors.update(
        {
            "position_ids": positions,
            "rope_cos": cos,
            "rope_sin": sin,
            "causal_mask": _causal_mask(config),
            "score_scale": torch.full(
                (
                    config.batch_size,
                    config.num_attention_heads,
                    config.sequence_length,
                    config.sequence_length,
                ),
                1.0 / math.sqrt(config.head_dim),
                dtype=torch.float16,
            ),
        }
    )
    for projection in PROJECTION_DIMS:
        base = rename[projection]
        tensors[f"{projection}.qweight"] = state[f"{base}.qweight"].contiguous()
        tensors[f"{projection}.scales"] = state[f"{base}.scales"].contiguous()

    manifest = _build_manifest(
        config,
        tensors,
        source="checkpoint",
        seed=seed,
        layer_index=layer_index,
        checkpoint_profile=checkpoint_profile,
    )
    manifest["checkpoint_path"] = str(Path(checkpoint).resolve())
    manifest["case_hash"] = _case_hash(manifest)
    return LayerCase(config, tensors, manifest)


def save_case(case: LayerCase, path: str | Path) -> None:
    destination = Path(path)
    destination.mkdir(parents=True, exist_ok=False)
    _validate_case(case)
    torch.save(case.tensors, destination / "tensors.pt")
    (destination / "manifest.json").write_text(
        json.dumps(case.manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def load_case(path: str | Path) -> LayerCase:
    source = Path(path)
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    tensors = torch.load(source / "tensors.pt", map_location="cpu", weights_only=True)
    case = LayerCase(LayerConfig.from_dict(manifest["config"]), tensors, manifest)
    _validate_case(case)
    return case


def _validate_case(case: LayerCase) -> None:
    if case.manifest.get("schema_version") != CASE_SCHEMA_VERSION:
        raise ValueError(f"unsupported case schema version {case.manifest.get('schema_version')!r}")
    expected_hashes = case.manifest.get("tensor_hashes", {})
    if set(expected_hashes) != set(case.tensors):
        raise ValueError("case tensor set does not match manifest")
    config = case.config
    expected: dict[str, tuple[tuple[int, ...], torch.dtype]] = {
        "input": (
            (config.batch_size, config.sequence_length, config.hidden_size),
            torch.float16,
        ),
        "input_norm.weight": ((config.hidden_size,), torch.float16),
        "post_attention_norm.weight": ((config.hidden_size,), torch.float16),
        "position_ids": ((config.batch_size, config.sequence_length), torch.int64),
        "rope_cos": (
            (config.batch_size, config.sequence_length, config.head_dim),
            torch.float16,
        ),
        "rope_sin": (
            (config.batch_size, config.sequence_length, config.head_dim),
            torch.float16,
        ),
        "causal_mask": (
            (1, 1, config.sequence_length, config.sequence_length),
            torch.float16,
        ),
        "score_scale": (
            (
                config.batch_size,
                config.num_attention_heads,
                config.sequence_length,
                config.sequence_length,
            ),
            torch.float16,
        ),
    }
    for projection in PROJECTION_DIMS:
        in_features, out_features = _projection_shape(config, projection)
        expected[f"{projection}.qweight"] = (
            (in_features, out_features // 2),
            torch.int8,
        )
        expected[f"{projection}.scales"] = (
            (in_features // config.weight_group_size, out_features),
            torch.float16,
        )
    if set(expected) != set(case.tensors):
        raise ValueError("case tensors do not match the decoder-layer contract")
    for name, tensor in case.tensors.items():
        expected_shape, expected_dtype = expected[name]
        if tuple(tensor.shape) != expected_shape or tensor.dtype != expected_dtype:
            raise ValueError(
                f"case tensor {name} expected shape={expected_shape}, dtype={expected_dtype}; "
                f"got shape={tuple(tensor.shape)}, dtype={tensor.dtype}"
            )
        actual = tensor_sha256(tensor)
        if actual != expected_hashes[name]:
            raise ValueError(f"tensor checksum mismatch for {name}: {actual} != {expected_hashes[name]}")
    actual_case_hash = _case_hash(case.manifest)
    if actual_case_hash != case.manifest.get("case_hash"):
        raise ValueError("case manifest checksum mismatch")
