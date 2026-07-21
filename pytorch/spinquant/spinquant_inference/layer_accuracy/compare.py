"""Stage-aware numerical comparison and machine-readable reports."""

from __future__ import annotations

import math
from typing import Mapping

import torch


PROFILE_V1 = {
    "pointwise": {
        "atol": 0.02, "rtol": 0.02, "rel_l2": 0.01, "cosine": 0.9999,
        "max_exceed_fraction": 0.0,
    },
    # INT4 bin boundaries amplify tiny pre-quantization FP16 differences into
    # sparse one-code changes.  Keep aggregate accuracy strict while allowing
    # up to 1% isolated element outliers for quantized and matmul stages.
    "quantized": {
        "atol": 0.02, "rtol": 0.02, "rel_l2": 0.03, "cosine": 0.999,
        "max_exceed_fraction": 0.01,
    },
    "matmul": {
        "atol": 0.5, "rtol": 0.05, "rel_l2": 0.03, "cosine": 0.999,
        "max_exceed_fraction": 0.01, "max_exceed_count": 1,
    },
    # These operations are locally pointwise/layout-only but consume values
    # that have already crossed a W4/KV4 boundary.  Their end-to-end captures
    # should preserve the upstream aggregate error budget rather than require
    # bit-local agreement with a separately quantized CUDA path.
    "propagated": {
        "atol": 0.02, "rtol": 0.02, "rel_l2": 0.03, "cosine": 0.999,
        "max_exceed_fraction": 0.035, "max_exceed_count": 2,
    },
    # QK scaling preserves the matmul's strong aggregate agreement but can
    # move a sparse set of small values across a tight elementwise FP16 bound.
    # Softmax/PV and the final residual retain their independent stricter gates.
    "scores": {
        "atol": 0.02, "rtol": 0.02, "rel_l2": 0.03, "cosine": 0.999,
        "max_exceed_fraction": 0.05, "max_exceed_count": 2,
    },
    "softmax": {
        "atol": 0.02, "rtol": 0.02, "rel_l2": 0.03, "cosine": 0.999,
        "max_exceed_fraction": 0.0,
    },
    "residual": {
        "atol": 1.0, "rtol": 0.05, "rel_l2": 0.05, "cosine": 0.995,
        "max_exceed_fraction": 0.0,
    },
}

STAGE_FAMILY = {
    "q_proj": "matmul",
    "k_proj": "matmul",
    "v_proj": "matmul",
    "qk": "matmul",
    "pv": "matmul",
    "o_proj": "matmul",
    "gate_proj": "matmul",
    "up_proj": "matmul",
    "down_proj": "matmul",
    "k_quant": "quantized",
    "v_quant": "quantized",
    "cache_update": "quantized",
    "scaled_masked_scores": "scores",
    "head_concat": "propagated",
    "post_attn_norm": "propagated",
    "silu": "propagated",
    "mlp_mul": "propagated",
    "r4": "propagated",
    "softmax": "softmax",
    "attn_residual": "residual",
    "final_residual": "residual",
}

COMPARISON_PROFILES = ("llama2_fp16_w4kv4_v1", "llama_fp16_w4kv4_v1")


def _threshold(stage: str) -> dict:
    return PROFILE_V1[STAGE_FAMILY.get(stage, "pointwise")]


def _semantic_stage(capture_name: str) -> str:
    """Strip a decode step qualifier while preserving auxiliary stage names."""
    parts = capture_name.split(".")
    if _qualified_layer(capture_name) is not None or parts[0] == "prefill" or (
        parts[0].startswith("step") and parts[0][4:].isdigit()
    ):
        parts = parts[1:]
    return parts[0]


def _qualified_layer(capture_name: str) -> int | None:
    qualifier = capture_name.split(".", 1)[0]
    if qualifier.startswith("layer") and qualifier[5:].isdigit():
        return int(qualifier[5:])
    return None


def _unravel(flat_index: int, shape: tuple[int, ...]) -> list[int]:
    if not shape:
        return []
    indices = []
    remaining = flat_index
    for size in reversed(shape):
        indices.append(remaining % size)
        remaining //= size
    return list(reversed(indices))


def _metric(stage: str, reference: torch.Tensor, candidate: torch.Tensor) -> dict:
    if tuple(reference.shape) != tuple(candidate.shape):
        return {
            "passed": False,
            "reason": "shape_mismatch",
            "reference_shape": list(reference.shape),
            "candidate_shape": list(candidate.shape),
        }
    if reference.dtype != candidate.dtype:
        dtype_match = False
    else:
        dtype_match = True
    if reference.numel() == 0:
        return {"passed": dtype_match, "finite": True, "dtype_match": dtype_match}

    ref = reference.detach().cpu().float()
    dut = candidate.detach().cpu().float()
    finite = bool(torch.isfinite(ref).all() and torch.isfinite(dut).all())
    if not finite:
        return {"passed": False, "finite": False, "dtype_match": dtype_match}

    difference = (dut - ref).abs()
    worst_flat = int(difference.reshape(-1).argmax().item())
    worst_index = _unravel(worst_flat, tuple(reference.shape))
    ref_norm = float(torch.linalg.vector_norm(ref).item())
    diff_norm = float(torch.linalg.vector_norm(dut - ref).item())
    rel_l2 = diff_norm / max(ref_norm, 1e-12)
    if ref.numel() == 1:
        cosine = 1.0 if float(ref.item()) == float(dut.item()) else 0.0
    else:
        cosine = float(torch.nn.functional.cosine_similarity(
            ref.reshape(1, -1), dut.reshape(1, -1), dim=1, eps=1e-12
        ).item())
    threshold = _threshold(stage)
    allowed = threshold["atol"] + threshold["rtol"] * ref.abs()
    exceed_count = int((difference > allowed).sum().item())
    exceed_fraction = exceed_count / reference.numel()
    passed = (
        dtype_match
        and (
            exceed_fraction <= threshold["max_exceed_fraction"]
            or exceed_count <= threshold.get("max_exceed_count", 0)
        )
        and rel_l2 <= threshold["rel_l2"]
        and cosine >= threshold["cosine"]
    )
    worst_tuple = tuple(worst_index)
    return {
        "passed": passed,
        "finite": finite,
        "dtype_match": dtype_match,
        "max_abs": float(difference.max().item()),
        "mean_abs": float(difference.mean().item()),
        "relative_l2": rel_l2,
        "cosine": cosine,
        "exceed_count": exceed_count,
        "exceed_fraction": exceed_fraction,
        "worst_index": worst_index,
        "reference_at_worst": float(ref[worst_tuple].item()),
        "candidate_at_worst": float(dut[worst_tuple].item()),
        "threshold": threshold,
    }


def compare_runs(
    reference: Mapping[str, torch.Tensor],
    candidate: Mapping[str, torch.Tensor],
    *,
    profile: str = "llama2_fp16_w4kv4_v1",
) -> dict:
    if profile not in COMPARISON_PROFILES:
        raise ValueError(f"unknown comparison profile {profile!r}")
    all_stages = list(dict.fromkeys((*reference.keys(), *candidate.keys())))
    stages = {}
    for stage in all_stages:
        if stage not in reference or stage not in candidate:
            stages[stage] = {
                "passed": False,
                "reason": "missing_capture",
                "missing_from": "reference" if stage not in reference else "candidate",
            }
            continue
        stages[stage] = _metric(
            _semantic_stage(stage), reference[stage], candidate[stage]
        )
    failing_layers = [
        layer
        for stage, metric in stages.items()
        if not metric["passed"]
        for layer in [_qualified_layer(stage)]
        if layer is not None
    ]
    report = {
        "profile": profile,
        "passed": bool(stages) and all(metric["passed"] for metric in stages.values()),
        "stages": stages,
    }
    if failing_layers:
        report["first_failing_layer"] = min(failing_layers)
    return report
