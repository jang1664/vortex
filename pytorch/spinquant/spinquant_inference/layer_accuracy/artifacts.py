"""Portable, checksum-protected test case and run artifacts."""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Dict, Mapping

import torch

from .specs import (
    ALL_ASYMMETRIC_WKV4,
    DecodeConfig,
    LayerConfig,
    LLAMA3_MODEL,
    StackConfig,
)
from .tensor_io import pack_signed_int4, tensor_sha256


CASE_SCHEMA_VERSION = 1
GRAPH_VERSION = "llama2_decoder_layer_r3r4_v1"
DECODE_GRAPH_VERSION = "llama2_decoder_layer_r3r4_decode_v1"
LLAMA3_GRAPH_VERSION = "llama3_decoder_layer_gqa_r3r4_v1"
LLAMA3_DECODE_GRAPH_VERSION = "llama3_decoder_layer_gqa_r3r4_decode_v1"
STACK_GRAPH_VERSION = "llama_decoder_stack_r3r4_v1"
PROJECTION_DIMS = {
    "q_proj": ("hidden_size", "hidden_size"),
    "k_proj": ("hidden_size", "kv_hidden_size"),
    "v_proj": ("hidden_size", "kv_hidden_size"),
    "o_proj": ("hidden_size", "hidden_size"),
    "gate_proj": ("hidden_size", "intermediate_size"),
    "up_proj": ("hidden_size", "intermediate_size"),
    "down_proj": ("intermediate_size", "hidden_size"),
}
CHECKPOINT_PROJECTION_NAMES = {
    "q_proj": "self_attn.q_proj",
    "k_proj": "self_attn.k_proj",
    "v_proj": "self_attn.v_proj",
    "o_proj": "self_attn.o_proj",
    "gate_proj": "mlp.gate_proj",
    "up_proj": "mlp.up_proj",
    "down_proj": "mlp.down_proj",
}
LAYER_TENSOR_NAMES = {
    "input_norm.weight",
    "post_attention_norm.weight",
    *(
        name
        for projection in PROJECTION_DIMS
        for name in (
            f"{projection}.qweight",
            f"{projection}.scales",
            f"{projection}.zeros",
        )
    ),
}


@dataclass
class LayerCase:
    config: LayerConfig
    tensors: Dict[str, torch.Tensor]
    manifest: dict


@dataclass
class DecodeCase:
    config: DecodeConfig
    tensors: Dict[str, torch.Tensor]
    manifest: dict


@dataclass
class StackCase:
    config: StackConfig
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


def graph_version(config: LayerConfig, *, decode: bool = False) -> str:
    if config.model == LLAMA3_MODEL:
        version = LLAMA3_DECODE_GRAPH_VERSION if decode else LLAMA3_GRAPH_VERSION
    else:
        version = DECODE_GRAPH_VERSION if decode else GRAPH_VERSION
    if config.quantization_policy == ALL_ASYMMETRIC_WKV4:
        version += ":signed_all_asymmetric_wkv4_v1"
    return version


def stack_graph_version(config: StackConfig) -> str:
    return f"{STACK_GRAPH_VERSION}:{graph_version(config.layer)}"


def _quantize_random_weight(
    in_features: int,
    out_features: int,
    group_size: int,
    generator: torch.Generator,
    mode: str,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor | None]:
    weight = torch.randn(in_features, out_features, generator=generator, dtype=torch.float32)
    weight.mul_(1.0 / math.sqrt(in_features))
    groups = weight.reshape(in_features // group_size, group_size, out_features)
    if mode == "sym":
        scales = groups.abs().amax(dim=1).clamp_min_(1e-8).div_(7.0)
        zeros = None
    elif mode == "asym":
        minimum = torch.minimum(groups.amin(dim=1), torch.zeros_like(groups[:, 0]))
        maximum = torch.maximum(groups.amax(dim=1), torch.zeros_like(groups[:, 0]))
        scales = (maximum - minimum) / 15.0
        constant = scales == 0
        scales = torch.where(constant, torch.ones_like(scales), scales)
        zeros = torch.where(
            constant,
            torch.zeros_like(scales),
            (torch.round(-minimum / scales) - 8.0).clamp(-8, 7),
        ).to(torch.int16)
    else:
        raise ValueError(f"unsupported weight quantization mode {mode!r}")
    scales = scales.to(torch.float16)
    quantized = torch.round(groups / scales.float().unsqueeze(1))
    if zeros is not None:
        quantized = quantized + zeros.float().unsqueeze(1)
    quantized = quantized.clamp_(-8, 7).to(torch.int8)
    quantized = quantized.reshape(in_features, out_features)
    return pack_signed_int4(quantized), scales, zeros


def _rope_tables(config: LayerConfig) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    positions = torch.arange(config.sequence_length, dtype=torch.long).view(1, -1)
    exponent = torch.arange(0, config.head_dim, 2, dtype=torch.float32) / config.head_dim
    inv_freq = 1.0 / (config.rope_theta**exponent)
    frequencies = torch.outer(positions[0].float(), inv_freq)
    embedding = torch.cat((frequencies, frequencies), dim=-1)
    positions = positions.expand(config.batch_size, -1).contiguous()
    cos = embedding.cos().to(torch.float16).unsqueeze(0)
    sin = embedding.sin().to(torch.float16).unsqueeze(0)
    return (
        positions,
        cos.expand(config.batch_size, -1, -1).contiguous(),
        sin.expand(config.batch_size, -1, -1).contiguous(),
    )


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
        "graph_version": graph_version(config),
        "source": source,
        "seed": seed,
        "layer_index": layer_index,
        "checkpoint_profile": checkpoint_profile,
        "config": config.to_dict(),
        "weight_quantization": {
            "bits": 4,
            "signed": True,
            "mode": config.weight_quant_mode,
            "group_size": config.weight_group_size,
            "group_axis": "input",
            "scale_dtype": "float16",
            "zero_dtype": "int16",
            "nibble_order": "low_first",
        },
        "kv_quantization": {
            "bits": 4,
            "signed": True,
            "group_size": config.kv_group_size,
            "group_axis": "head_dim",
            "key_mode": config.key_quant_mode,
            "value_mode": config.value_quant_mode,
            "scale_dtype": "float16",
            "zero_dtype": "int16",
            "nibble_order": "low_first",
        },
        "rotation_contract": {
            "offline_folded_r1_r2": True,
            "residual_basis": "spinquant_rotated",
            "online_r3": "post_rope_q_and_k",
            "online_r4": (
                "pre_down_projection_exact_28x512"
                if config.model == LLAMA3_MODEL
                else "pre_down_projection_exact_172x64"
            ),
        },
        "attention_contract": {
            "gqa": config.num_key_value_heads != config.num_attention_heads,
            "num_query_heads": config.num_attention_heads,
            "num_kv_heads": config.num_key_value_heads,
            "query_heads_per_kv": config.num_key_value_groups,
        },
        "tensor_hashes": tensor_hashes,
    }
    manifest["case_hash"] = _case_hash(manifest)
    return manifest


def _create_common_tensors(
    config: LayerConfig, generator: torch.Generator
) -> Dict[str, torch.Tensor]:
    tensors: Dict[str, torch.Tensor] = {
        "input": torch.randn(
            config.batch_size,
            config.sequence_length,
            config.hidden_size,
            generator=generator,
            dtype=torch.float16,
        ),
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
    return tensors


def _create_random_layer_tensors(
    config: LayerConfig, generator: torch.Generator
) -> Dict[str, torch.Tensor]:
    tensors: Dict[str, torch.Tensor] = {
        "input_norm.weight": (
            1.0 + 0.02 * torch.randn(config.hidden_size, generator=generator)
        ).to(torch.float16),
        "post_attention_norm.weight": (
            1.0 + 0.02 * torch.randn(config.hidden_size, generator=generator)
        ).to(torch.float16),
    }
    for projection in PROJECTION_DIMS:
        in_features, out_features = _projection_shape(config, projection)
        packed, scales, zeros = _quantize_random_weight(
            in_features,
            out_features,
            config.weight_group_size,
            generator,
            config.weight_quant_mode,
        )
        tensors[f"{projection}.qweight"] = packed
        tensors[f"{projection}.scales"] = scales
        if zeros is not None:
            tensors[f"{projection}.zeros"] = zeros
    return tensors


def create_random_case(config: LayerConfig | None = None, *, seed: int = 0) -> LayerCase:
    config = config or LayerConfig()
    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    tensors = _create_common_tensors(config, generator)
    tensors.update(_create_random_layer_tensors(config, generator))

    manifest = _build_manifest(
        config,
        tensors,
        source="random",
        seed=seed,
        layer_index=0,
        checkpoint_profile="spinquant-w4a16-r3r4",
    )
    return LayerCase(config, tensors, manifest)


def _build_stack_manifest(
    config: StackConfig,
    tensors: Mapping[str, torch.Tensor],
    *,
    source: str,
    seed: int,
    random_weight_mode: str | None,
    checkpoint_profile: str,
    checkpoint_path: str | None = None,
    checkpoint_signature: Mapping[str, int] | None = None,
) -> dict:
    manifest = {
        "schema_version": CASE_SCHEMA_VERSION,
        "case_kind": "decoder_stack",
        "graph_version": stack_graph_version(config),
        "source": source,
        "seed": seed,
        "random_weight_mode": random_weight_mode,
        "checkpoint_profile": checkpoint_profile,
        "config": config.to_dict(),
        "layer_indices": list(config.layer_indices),
        "tensor_hashes": {
            name: tensor_sha256(tensor) for name, tensor in sorted(tensors.items())
        },
    }
    if checkpoint_path is not None:
        manifest["checkpoint_path"] = checkpoint_path
    if checkpoint_signature is not None:
        manifest["checkpoint_signature"] = dict(checkpoint_signature)
    manifest["case_hash"] = _case_hash(manifest)
    return manifest


def create_random_stack_case(
    config: StackConfig,
    *,
    seed: int = 0,
    random_weight_mode: str = "shared",
) -> StackCase:
    if random_weight_mode not in ("shared", "independent"):
        raise ValueError("random_weight_mode must be 'shared' or 'independent'")
    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    tensors = _create_common_tensors(config.layer, generator)
    if random_weight_mode == "shared":
        tensors.update(_create_random_layer_tensors(config.layer, generator))
    manifest = _build_stack_manifest(
        config,
        tensors,
        source="random",
        seed=seed,
        random_weight_mode=random_weight_mode,
        checkpoint_profile="spinquant-w4a16-r3r4",
    )
    return StackCase(config, tensors, manifest)


def create_random_decode_case(config: DecodeConfig, *, seed: int = 0) -> DecodeCase:
    """Create one prompt plus ordered one-token decode inputs with shared weights."""

    base = create_random_case(config.layer, seed=seed)
    return _decode_case_from_layer_case(base, config)


def _decode_case_from_layer_case(base: LayerCase, config: DecodeConfig) -> DecodeCase:
    if base.config != config.layer:
        raise ValueError("decode config layer geometry does not match the source layer case")
    tensors = dict(base.tensors)
    full_input = tensors.pop("input")
    full_positions = tensors.pop("position_ids")
    tensors["prompt_input"] = full_input[:, : config.prompt_length].contiguous()
    decode = full_input[:, config.prompt_length :].contiguous()
    tensors["decode_inputs"] = decode.transpose(0, 1).unsqueeze(2).contiguous()
    tensors["prompt_position_ids"] = full_positions[:, : config.prompt_length].contiguous()
    decode_positions = full_positions[:, config.prompt_length :].contiguous()
    tensors["decode_position_ids"] = (
        decode_positions.transpose(0, 1).unsqueeze(2).contiguous()
    )

    manifest = dict(base.manifest)
    manifest.update(
        {
            "case_kind": "decode",
            "graph_version": graph_version(config.layer, decode=True),
            "config": config.to_dict(),
            "decode_contract": {
                "prompt_length": config.prompt_length,
                "decode_steps": config.decode_steps,
                "max_sequence_length": config.max_sequence_length,
                "decode_token_length": 1,
            },
            "tensor_hashes": {
                name: tensor_sha256(tensor) for name, tensor in sorted(tensors.items())
            },
        }
    )
    manifest["case_hash"] = _case_hash(manifest)
    case = DecodeCase(config, tensors, manifest)
    _validate_decode_case(case)
    return case


def _required_checkpoint_tensors(config: LayerConfig, layer_index: int) -> dict[str, tuple[tuple[int, ...], torch.dtype]]:
    prefix = f"model.layers.{layer_index}."
    required: dict[str, tuple[tuple[int, ...], torch.dtype]] = {
        f"{prefix}input_layernorm.weight": ((config.hidden_size,), torch.float16),
        f"{prefix}post_attention_layernorm.weight": ((config.hidden_size,), torch.float16),
    }
    for projection, checkpoint_name in CHECKPOINT_PROJECTION_NAMES.items():
        in_features, out_features = _projection_shape(config, projection)
        required[f"{prefix}{checkpoint_name}.qweight"] = (
            (in_features, out_features // 2),
            torch.int8,
        )
        required[f"{prefix}{checkpoint_name}.scales"] = (
            (in_features // config.weight_group_size, out_features),
            torch.float16,
        )
        if config.weight_quant_mode == "asym":
            required[f"{prefix}{checkpoint_name}.zeros"] = (
                (in_features // config.weight_group_size, out_features),
                torch.int16,
            )
    return required


def _validate_checkpoint_layer(
    state: Mapping[str, torch.Tensor],
    config: LayerConfig,
    layer_index: int,
) -> None:
    required = _required_checkpoint_tensors(config, layer_index)
    missing = sorted(key for key in required if key not in state)
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


def _layer_tensors_from_state(
    state: Mapping[str, torch.Tensor],
    config: LayerConfig,
    layer_index: int,
) -> Dict[str, torch.Tensor]:
    _validate_checkpoint_layer(state, config, layer_index)

    prefix = f"model.layers.{layer_index}."
    rename = {
        "input_norm.weight": f"{prefix}input_layernorm.weight",
        "post_attention_norm.weight": f"{prefix}post_attention_layernorm.weight",
        **{
            projection: f"{prefix}{checkpoint_name}"
            for projection, checkpoint_name in CHECKPOINT_PROJECTION_NAMES.items()
        },
    }
    tensors: Dict[str, torch.Tensor] = {
        "input_norm.weight": state[rename["input_norm.weight"]].contiguous(),
        "post_attention_norm.weight": state[
            rename["post_attention_norm.weight"]
        ].contiguous(),
    }
    for projection in PROJECTION_DIMS:
        base = rename[projection]
        tensors[f"{projection}.qweight"] = state[f"{base}.qweight"].contiguous()
        tensors[f"{projection}.scales"] = state[f"{base}.scales"].contiguous()
        if config.weight_quant_mode == "asym":
            tensors[f"{projection}.zeros"] = state[f"{base}.zeros"].contiguous()
    return tensors


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

    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    tensors = _create_common_tensors(config, generator)
    tensors.update(_layer_tensors_from_state(state, config, layer_index))

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


def _checkpoint_signature(path: Path) -> dict[str, int]:
    stat = path.stat()
    return {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def create_checkpoint_stack_case(
    checkpoint: str | Path,
    *,
    config: StackConfig,
    checkpoint_profile: str,
    seed: int = 0,
) -> StackCase:
    if checkpoint_profile != "spinquant-w4a16-r3r4":
        raise ValueError("checkpoint_profile must explicitly be spinquant-w4a16-r3r4")
    checkpoint_path = Path(checkpoint).resolve()
    state = torch.load(
        checkpoint_path, map_location="cpu", weights_only=True, mmap=True
    )
    if not isinstance(state, dict):
        raise TypeError("checkpoint must contain a state_dict mapping")
    for layer_index in config.layer_indices:
        _validate_checkpoint_layer(state, config.layer, layer_index)

    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    tensors = _create_common_tensors(config.layer, generator)
    manifest = _build_stack_manifest(
        config,
        tensors,
        source="checkpoint",
        seed=seed,
        random_weight_mode=None,
        checkpoint_profile=checkpoint_profile,
        checkpoint_path=str(checkpoint_path),
        checkpoint_signature=_checkpoint_signature(checkpoint_path),
    )
    return StackCase(config, tensors, manifest)


class StackLayerSource:
    """Materialize one layer at a time while keeping checkpoint state mapped once."""

    def __init__(self, case: StackCase) -> None:
        self.case = case
        self._state: Mapping[str, torch.Tensor] | None = None
        if case.manifest["source"] == "checkpoint":
            checkpoint = Path(case.manifest["checkpoint_path"])
            if _checkpoint_signature(checkpoint) != case.manifest["checkpoint_signature"]:
                raise ValueError("checkpoint signature changed after stack case creation")
            state = torch.load(
                checkpoint, map_location="cpu", weights_only=True, mmap=True
            )
            if not isinstance(state, dict):
                raise TypeError("checkpoint must contain a state_dict mapping")
            self._state = state

    def layer_case(self, layer_index: int) -> LayerCase:
        if not self.case.config.contains(layer_index):
            raise ValueError(
                f"layer {layer_index} is outside stack layer range "
                f"{self.case.config.layer_indices}"
            )
        common = self.case.tensors
        source = self.case.manifest["source"]
        if source == "checkpoint":
            assert self._state is not None
            layer_tensors = _layer_tensors_from_state(
                self._state, self.case.config.layer, layer_index
            )
        elif self.case.manifest["random_weight_mode"] == "shared":
            layer_tensors = {
                name: tensor
                for name, tensor in common.items()
                if name in LAYER_TENSOR_NAMES
            }
        else:
            generator = torch.Generator(device="cpu")
            generator.manual_seed(self.case.manifest["seed"] + layer_index)
            layer_tensors = _create_random_layer_tensors(
                self.case.config.layer, generator
            )
        tensors = {
            name: tensor
            for name, tensor in common.items()
            if name not in LAYER_TENSOR_NAMES
        }
        tensors.update(layer_tensors)
        return LayerCase(
            self.case.config.layer,
            tensors,
            {
                "case_hash": self.case.manifest["case_hash"],
                "graph_version": graph_version(self.case.config.layer),
                "layer_index": layer_index,
            },
        )


def create_checkpoint_decode_case(
    checkpoint: str | Path,
    *,
    layer_index: int,
    checkpoint_profile: str,
    config: DecodeConfig,
    seed: int = 0,
) -> DecodeCase:
    base = create_checkpoint_case(
        checkpoint,
        layer_index=layer_index,
        checkpoint_profile=checkpoint_profile,
        config=config.layer,
        seed=seed,
    )
    return _decode_case_from_layer_case(base, config)


def materialize_decode_prefix(
    case: DecodeCase, *, logical_length: int
) -> LayerCase:
    """Build a valid full-prefix case for incremental-reference comparison."""

    if logical_length < case.config.prompt_length:
        raise ValueError("logical_length cannot be shorter than the prompt")
    if logical_length > case.config.total_sequence_length:
        raise ValueError("logical_length exceeds available decode inputs")
    layer = replace(case.config.layer, sequence_length=logical_length)
    decode_count = logical_length - case.config.prompt_length
    decode = case.tensors["decode_inputs"][:decode_count, :, 0].transpose(0, 1)
    positions = case.tensors["decode_position_ids"][:decode_count, :, 0].transpose(0, 1)
    tensors: Dict[str, torch.Tensor] = {
        "input": torch.cat((case.tensors["prompt_input"], decode), dim=1).contiguous(),
        "position_ids": torch.cat(
            (case.tensors["prompt_position_ids"], positions), dim=1
        ).contiguous(),
        "rope_cos": case.tensors["rope_cos"][:, :logical_length].contiguous(),
        "rope_sin": case.tensors["rope_sin"][:, :logical_length].contiguous(),
        "causal_mask": case.tensors["causal_mask"][
            :, :, :logical_length, :logical_length
        ].contiguous(),
        "score_scale": case.tensors["score_scale"][
            :, :, :logical_length, :logical_length
        ].contiguous(),
    }
    for name, tensor in case.tensors.items():
        if name in LAYER_TENSOR_NAMES:
            tensors[name] = tensor
    manifest = _build_manifest(
        layer,
        tensors,
        source=f"{case.manifest['source']}-decode-prefix",
        seed=case.manifest.get("seed"),
        layer_index=case.manifest.get("layer_index", 0),
        checkpoint_profile=case.manifest["checkpoint_profile"],
    )
    return LayerCase(layer, tensors, manifest)


def _save_case_artifact(
    case: LayerCase | DecodeCase | StackCase,
    path: str | Path,
    validator,
) -> None:
    destination = Path(path)
    destination.mkdir(parents=True, exist_ok=False)
    validator(case)
    torch.save(case.tensors, destination / "tensors.pt")
    (destination / "manifest.json").write_text(
        json.dumps(case.manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def save_case(case: LayerCase, path: str | Path) -> None:
    _save_case_artifact(case, path, _validate_case)


def save_decode_case(case: DecodeCase, path: str | Path) -> None:
    _save_case_artifact(case, path, _validate_decode_case)


def save_stack_case(case: StackCase, path: str | Path) -> None:
    _save_case_artifact(case, path, _validate_stack_case)


def load_case(path: str | Path) -> LayerCase:
    source = Path(path)
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    tensors = torch.load(source / "tensors.pt", map_location="cpu", weights_only=True)
    case = LayerCase(LayerConfig.from_dict(manifest["config"]), tensors, manifest)
    _validate_case(case)
    return case


def load_decode_case(path: str | Path) -> DecodeCase:
    source = Path(path)
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("case_kind") != "decode":
        raise ValueError("artifact is not a decode case")
    tensors = torch.load(source / "tensors.pt", map_location="cpu", weights_only=True)
    case = DecodeCase(DecodeConfig.from_dict(manifest["config"]), tensors, manifest)
    _validate_decode_case(case)
    return case


def load_stack_case(path: str | Path) -> StackCase:
    source = Path(path)
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("case_kind") != "decoder_stack":
        raise ValueError("artifact is not a decoder stack case")
    tensors = torch.load(source / "tensors.pt", map_location="cpu", weights_only=True)
    case = StackCase(StackConfig.from_dict(manifest["config"]), tensors, manifest)
    _validate_stack_case(case)
    return case


def _validate_tensor_contract(
    tensors: Mapping[str, torch.Tensor],
    expected: Mapping[str, tuple[tuple[int, ...], torch.dtype]],
    manifest: Mapping,
    *,
    contract_name: str,
) -> None:
    if set(expected) != set(tensors):
        raise ValueError(f"case tensors do not match the {contract_name} contract")
    expected_hashes = manifest.get("tensor_hashes", {})
    if set(expected_hashes) != set(tensors):
        raise ValueError("case tensor set does not match manifest")
    for name, tensor in tensors.items():
        expected_shape, expected_dtype = expected[name]
        if tuple(tensor.shape) != expected_shape or tensor.dtype != expected_dtype:
            raise ValueError(
                f"case tensor {name} expected shape={expected_shape}, "
                f"dtype={expected_dtype}; got shape={tuple(tensor.shape)}, "
                f"dtype={tensor.dtype}"
            )
        actual = tensor_sha256(tensor)
        if actual != expected_hashes[name]:
            raise ValueError(
                f"tensor checksum mismatch for {name}: {actual} != "
                f"{expected_hashes[name]}"
            )
    if _case_hash(manifest) != manifest.get("case_hash"):
        raise ValueError("case manifest checksum mismatch")


def _validate_stack_case(case: StackCase) -> None:
    manifest = case.manifest
    if manifest.get("schema_version") != CASE_SCHEMA_VERSION:
        raise ValueError(
            f"unsupported case schema version {manifest.get('schema_version')!r}"
        )
    if manifest.get("case_kind") != "decoder_stack":
        raise ValueError("stack case manifest must declare case_kind=decoder_stack")
    if manifest.get("graph_version") != stack_graph_version(case.config):
        raise ValueError("stack case graph version mismatch")
    if tuple(manifest.get("layer_indices", ())) != case.config.layer_indices:
        raise ValueError("stack case layer indices do not match config")
    if manifest.get("source") not in ("random", "checkpoint"):
        raise ValueError("stack case source must be random or checkpoint")
    if manifest.get("source") == "random":
        if manifest.get("random_weight_mode") not in ("shared", "independent"):
            raise ValueError("random stack case has invalid weight mode")
    else:
        checkpoint = Path(manifest.get("checkpoint_path", ""))
        if not checkpoint.is_file():
            raise ValueError(f"stack checkpoint does not exist: {checkpoint}")
        if _checkpoint_signature(checkpoint) != manifest.get("checkpoint_signature"):
            raise ValueError("checkpoint signature changed after stack case creation")

    config = case.config.layer
    expected: dict[str, tuple[tuple[int, ...], torch.dtype]] = {
        "input": (
            (config.batch_size, config.sequence_length, config.hidden_size),
            torch.float16,
        ),
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
    if manifest.get("random_weight_mode") == "shared":
        expected["input_norm.weight"] = ((config.hidden_size,), torch.float16)
        expected["post_attention_norm.weight"] = (
            (config.hidden_size,),
            torch.float16,
        )
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
            if config.weight_quant_mode == "asym":
                expected[f"{projection}.zeros"] = (
                    (in_features // config.weight_group_size, out_features),
                    torch.int16,
                )
    _validate_tensor_contract(
        case.tensors, expected, manifest, contract_name="decoder-stack"
    )


def _validate_decode_case(case: DecodeCase) -> None:
    if case.manifest.get("schema_version") != CASE_SCHEMA_VERSION:
        raise ValueError(
            f"unsupported case schema version {case.manifest.get('schema_version')!r}"
        )
    if case.manifest.get("case_kind") != "decode":
        raise ValueError("decode case manifest must declare case_kind=decode")
    config = case.config
    layer = config.layer
    if case.manifest.get("graph_version") != graph_version(layer, decode=True):
        raise ValueError("decode case graph version mismatch")
    total = config.total_sequence_length
    expected: dict[str, tuple[tuple[int, ...], torch.dtype]] = {
        "prompt_input": (
            (layer.batch_size, config.prompt_length, layer.hidden_size),
            torch.float16,
        ),
        "decode_inputs": (
            (config.decode_steps, layer.batch_size, 1, layer.hidden_size),
            torch.float16,
        ),
        "input_norm.weight": ((layer.hidden_size,), torch.float16),
        "post_attention_norm.weight": ((layer.hidden_size,), torch.float16),
        "prompt_position_ids": (
            (layer.batch_size, config.prompt_length),
            torch.int64,
        ),
        "decode_position_ids": (
            (config.decode_steps, layer.batch_size, 1),
            torch.int64,
        ),
        "rope_cos": ((layer.batch_size, total, layer.head_dim), torch.float16),
        "rope_sin": ((layer.batch_size, total, layer.head_dim), torch.float16),
        "causal_mask": ((1, 1, total, total), torch.float16),
        "score_scale": (
            (layer.batch_size, layer.num_attention_heads, total, total),
            torch.float16,
        ),
    }
    for projection in PROJECTION_DIMS:
        in_features, out_features = _projection_shape(layer, projection)
        expected[f"{projection}.qweight"] = (
            (in_features, out_features // 2),
            torch.int8,
        )
        expected[f"{projection}.scales"] = (
            (in_features // layer.weight_group_size, out_features),
            torch.float16,
        )
        if layer.weight_quant_mode == "asym":
            expected[f"{projection}.zeros"] = (
                (in_features // layer.weight_group_size, out_features),
                torch.int16,
            )
    _validate_tensor_contract(
        case.tensors, expected, case.manifest, contract_name="decode-layer"
    )

    prompt_positions = case.tensors["prompt_position_ids"]
    decode_positions = case.tensors["decode_position_ids"].squeeze(-1).transpose(0, 1)
    positions = torch.cat((prompt_positions, decode_positions), dim=1)
    if positions.shape[1] > 1 and not bool(torch.all(positions[:, 1:] > positions[:, :-1])):
        raise ValueError("decode position IDs must be strictly increasing")
    if not bool(torch.all(positions == positions[0:1])):
        raise ValueError("decode position IDs must agree across the batch")


def _validate_case(case: LayerCase) -> None:
    if case.manifest.get("schema_version") != CASE_SCHEMA_VERSION:
        raise ValueError(f"unsupported case schema version {case.manifest.get('schema_version')!r}")
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
        if config.weight_quant_mode == "asym":
            expected[f"{projection}.zeros"] = (
                (in_features // config.weight_group_size, out_features),
                torch.int16,
            )
    _validate_tensor_contract(
        case.tensors, expected, case.manifest, contract_name="decoder-layer"
    )
