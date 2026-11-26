"""Verify the pre-KIVI SpinQuant generator digest and all Qwen workload shapes."""

from collections import Counter
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.workload import gen_kernel_cfgs as gen


def snapshot():
    entries = []
    for base in (
        gen.ALL_SGEMM_TCU_VARIANT,
        gen.ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT,
        gen.ALL_FPINT_GEMM_NAIVE_VARIANT,
        gen.LAYOUT_FUSED_VARIANT,
    ):
        for stage in ("prefill", "generation"):
            for batch in ((1,) if stage == "prefill" else (1, 4, 64)):
                for length in (1024, 2048, 4096, 8192, 16384, 32768):
                    payload = gen.build_llm_kernels(
                        "llama3-8b",
                        [stage],
                        batch,
                        length,
                        length,
                        32,
                        variant=base + "_spinquant",
                        max_seq_len=65536,
                        out_tokens=128,
                        decode_measurement="sampled",
                        decode_sample_interval=32,
                    )
                    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
                    entries.append(
                        {
                            "variant": base,
                            "stage": stage,
                            "batch": batch,
                            "length": length,
                            "sha256": hashlib.sha256(encoded).hexdigest(),
                        }
                    )
    return entries


# SHA-256 of the 96 canonical payload identities generated at 4b5891823.
expected = "052314142b3e49570be97f406debbf830cb25824a36d512e7823261274b81b25"
digest = hashlib.sha256((json.dumps(snapshot(), indent=2) + "\n").encode()).hexdigest()
if digest != expected:
    raise SystemExit(f"Llama3-8B SpinQuant generator changed: {digest}")
print("96 Llama3-8B SpinQuant workload payloads match the baseline", flush=True)

totals = {}
for v in gen.KIVI_VARIANTS:
    count = 0
    for stage, batches in (("prefill", (1,)), ("generation", (1, 4, 64))):
        for b in batches:
            for n in (1024, 2048, 4096, 8192, 16384, 32768):
                p = gen.build_llm_kernels(
                    "qwen3-8b",
                    [stage],
                    b,
                    n,
                    n,
                    128,
                    variant=v,
                    max_seq_len=65536,
                    out_tokens=128,
                    decode_measurement="sampled",
                )
                cases = p["kernels"]
                names = Counter(k["name"] for k in cases)
                steps = 128 if stage == "generation" else 1
                assert names["q_head_norm"] == names["k_head_norm"] == steps
                assert all(
                    not any(word in k["name"] for word in ("hadamard", "rotation")) for k in cases
                )
                for k in cases:
                    name, shape = k["name"], k["shape"]
                    if name in ("q_head_norm", "k_head_norm"):
                        assert (
                            k["kind"] == "rmsnorm"
                            and shape["hidden"] == 128
                            and k["calls_per_forward"] == 36
                        )
                        assert (
                            k["inputs"][0]["source"] == name[0] + "_proj"
                            and k["outputs"][0]["target"] == "rope_" + name[0]
                        )
                    if name in ("attn_qkT", "attn_pv") and k["app"] != "sgemm_tcu":
                        assert (
                            shape["QDIR"] == 1
                            and shape["QBLK"] == 32
                            and shape["WTRANS"] == int(name == "attn_qkT")
                        )
                        if stage == "generation" and k["app"].endswith("_naive") and n >= 8192:
                            assert shape["padded_cache_length"] % 128 == 0
                    if name in (
                        "kv_cache_quant_rope_k_to_attn_qkT",
                        "kv_cache_quant_v_cache_to_attn_pv",
                    ):
                        assert k["calls_per_forward"] == 36 * b * 8
                        assert shape["QBLK"] == 32 and "--quant-mode kivi_int_zp" in k["args"]
                        if stage == "generation":
                            valid = (
                                (shape["cache_position"] % 32 + 1)
                                if name.startswith("kv_cache_quant_rope")
                                else 1
                            )
                            assert shape["source_token_count"] == valid and k["args"].startswith(
                                f"-k {valid} "
                            )
                count += 1
    totals[v] = count
print(totals)
