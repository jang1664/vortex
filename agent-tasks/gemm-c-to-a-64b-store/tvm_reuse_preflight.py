"""Read-only compiler preflight for the new RTL output layout.

The scoped descriptor override models the new hardware contract only. It does
not implement a TVM ABI migration or execute the resulting device code.
"""

import dataclasses
import json
from pathlib import Path
import sys
from unittest.mock import patch

import torch
import tvm
from tvm import relax
from tvm.relax.backend.vortex.layout import ImproveLayoutPlan, ImproveProfile, plan_improve_layout
from tvm.relax.backend.vortex.pipeline import _w4a16_lowering_pass
from tvm.relax.frontend.torch import from_exported_program

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "analysis_workspace/latency_on_hw/docs/gemm_c_to_a_layout_64b_store_results/tvm_preflight"
sys.path.insert(0, str(ROOT / "pytorch/spinquant"))
import spinquant_inference.vortex_export_ops  # noqa: E402,F401


class Chain(torch.nn.Module):
    def forward(self, a, w1, s1, z1, w2, s2, z2):
        c = torch.ops.vortex.mm_w4a16(
            a, w1, s1, z1, [256, 256], 32, 0, 1, "signed_asymmetric_int4", False
        )
        return torch.ops.vortex.mm_w4a16(
            c, w2, s2, z2, [256, 256], 32, 0, 1, "signed_asymmetric_int4", False
        )


def inventory(mod):
    calls = []
    gemm_bindings = []

    for block in mod["main"].body.blocks:
        for binding in block.bindings:
            value = binding.value
            if (isinstance(value, relax.Call) and isinstance(value.op, tvm.ir.Op)
                    and value.op.name == "relax.call_tir"
                    and value.args[0].name_hint.startswith("vortex_mm_w4a16_improve")):
                gemm_bindings.append((binding.var, value))

    def visit(expr):
        if isinstance(expr, relax.Call) and isinstance(expr.op, tvm.ir.Op):
            if expr.op.name == "relax.call_tir":
                calls.append(expr.args[0].name_hint)

    relax.analysis.post_order_visit(mod["main"].body, visit)
    return {
        "reused_c": int((mod.attrs or {}).get("vortex.improve.reused_c_layouts", 0)),
        "a_pack_calls": sum(name.startswith("vortex_gemm_a_tiled") for name in calls),
        "c_detile_calls": sum(name.startswith("vortex_gemm_c_detile") for name in calls),
        "gemm_calls": sum(name.startswith("vortex_mm_w4a16_improve") for name in calls),
        "direct_c_to_a": len(gemm_bindings) == 2 and
            gemm_bindings[1][1].args[1][0].same_as(gemm_bindings[0][0]),
        "calls": calls,
    }


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    target = tvm.target.Target(
        {
            "kind": "vortex", "vortex_gemm_mode": "improve",
            "thread_warp_size": 16, "vortex_mxu_row": 16, "vortex_mxu_col": 16,
            "vortex_mxu_col_tile": 16, "vortex_num_dma_channels": 4,
            "vortex_num_tmem_banks": 8, "vortex_tmem_bank_size": 32768,
            "vortex_gemm_acc_mem_depth": 1024,
        }, host="llvm"
    )
    original_c = ImproveLayoutPlan.c_descriptor.fget

    def packed_c(plan):
        return dataclasses.replace(original_c(plan), row_padding="dma_tile")

    results = []
    for rows in (1, 4, 8, 9, 132, 256):
        inputs = (torch.ones((rows, 256), dtype=torch.float16),) + tuple(
            value for _ in range(2) for value in (
                torch.ones((256, 128), dtype=torch.uint8),
                torch.ones((8, 256), dtype=torch.float16),
                torch.zeros((8, 256), dtype=torch.int16),
            )
        )
        ep = torch.export.export(Chain(), inputs)
        logical = from_exported_program(ep, run_ep_decomposition=False, unwrap_unit_return_tuple=True)
        row = {"m": rows, "k": 256, "n": 256}
        for mode in ("current_tvm", "new_c_descriptor_only"):
            context = patch.object(ImproveLayoutPlan, "c_descriptor", property(packed_c))
            if mode == "new_c_descriptor_only":
                with context:
                    lowered = _w4a16_lowering_pass(target)(logical)
            else:
                lowered = _w4a16_lowering_pass(target)(logical)
            lowered = relax.transform.DeadCodeElimination()(lowered)
            info = inventory(lowered)
            (OUT / f"m{rows}_{mode}.py").write_text(lowered.script())
            assert info["gemm_calls"] == 2, info
            expected_reuse = mode == "new_c_descriptor_only" or rows % 8 == 0
            assert info["reused_c"] == int(expected_reuse), info
            assert info["direct_c_to_a"] == expected_reuse, info
            assert info["a_pack_calls"] == (1 if expected_reuse else 2), info
            assert info["c_detile_calls"] == (1 if expected_reuse else 2), info
            row[mode] = info
        results.append(row)
        print(json.dumps(row), flush=True)

    profile = ImproveProfile.from_target(target)
    p = plan_improve_layout(1, 33, 256, 32, profile=profile)
    c = plan_improve_layout(1, 256, 33, 32, profile=profile)
    assert p.execution_n == 48 and c.execution_k == 64
    assert not packed_c(p).compatible_gemm_input(c.a_descriptor)
    mismatch = {"producer_execution_n": p.execution_n, "consumer_execution_k": c.execution_k,
                "reuse": False}

    p = plan_improve_layout(1, 256, 256, 32,
                            profile=dataclasses.replace(profile, dma_nt=64))
    c = plan_improve_layout(1, 256, 256, 32, profile=profile)
    # Record this existing descriptor-check limitation rather than hiding it.
    dma_check = {"producer_dma_nt": 64, "consumer_dma_kt": 128,
                 "current_checker_accepts": packed_c(p).compatible_gemm_input(c.a_descriptor),
                 "safe_to_reuse": False}
    result = {"scope": "Lowering preflight only; descriptor override is process-local. No TVM source edits or new device execution.",
              "tvm_source": tvm.__file__, "chains": results,
              "execution_padding_mismatch": mismatch, "dma_width_check_gap": dma_check}
    (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print("TVM REUSE PREFLIGHT PASSED", flush=True)


if __name__ == "__main__":
    main()
