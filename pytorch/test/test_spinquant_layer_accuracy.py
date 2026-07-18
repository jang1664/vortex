import json
import math
import tempfile
import unittest
from pathlib import Path

import torch


SPINQUANT_ROOT = Path(__file__).resolve().parents[1] / "spinquant"
import sys

sys.path.insert(0, str(SPINQUANT_ROOT))

from spinquant_inference.layer_accuracy.artifacts import (  # noqa: E402
    LayerCase,
    create_checkpoint_case,
    create_random_case,
    load_case,
    save_case,
)
from spinquant_inference.layer_accuracy.backends import TorchBackend  # noqa: E402
from spinquant_inference.layer_accuracy.compare import compare_runs  # noqa: E402
from spinquant_inference.layer_accuracy.graph import LayerExecutor  # noqa: E402
from spinquant_inference.layer_accuracy.generator_conformance import (  # noqa: E402
    check_generator_conformance,
)
from spinquant_inference.layer_accuracy.run_artifacts import load_run, save_run  # noqa: E402
from spinquant_inference.layer_accuracy.specs import (  # noqa: E402
    LayerConfig,
    PhysicalSpec,
    QuantSpec,
    TensorSpec,
)
from spinquant_inference.layer_accuracy.stages import STAGE_NAMES  # noqa: E402
from spinquant_inference.layer_accuracy.tensor_io import (  # noqa: E402
    pack_signed_int4,
    unpack_signed_int4,
)


def tiny_config() -> LayerConfig:
    return LayerConfig(
        model="test-llama",
        hidden_size=16,
        intermediate_size=32,
        num_attention_heads=2,
        head_dim=8,
        batch_size=1,
        sequence_length=4,
        weight_group_size=4,
        kv_group_size=8,
    )


class TensorContractTests(unittest.TestCase):
    def test_signed_int4_low_nibble_first_round_trip(self):
        values = torch.tensor([[-8, -1, 0, 7]], dtype=torch.int8)
        packed = pack_signed_int4(values)
        self.assertEqual(packed.view(torch.uint8).tolist(), [[0xF8, 0x70]])
        torch.testing.assert_close(unpack_signed_int4(packed), values, rtol=0, atol=0)

    def test_tensor_specs_reject_semantic_axis_mismatch(self):
        quant = QuantSpec(
            bits=4,
            signed=True,
            mode="sym",
            group_size=8,
            group_axis="D",
            scale_dtype="float16",
            zero_dtype=None,
            nibble_order="low_first",
        )
        lhs = TensorSpec("x", ("B", "H", "S", "D"), (1, 2, 4, 8), "float16", quant)
        rhs = TensorSpec("x", ("B", "S", "H", "D"), (1, 4, 2, 8), "float16", quant)
        with self.assertRaisesRegex(ValueError, "semantic tensor mismatch"):
            lhs.require_compatible(rhs)

    def test_physical_spec_validates_buffer_extent(self):
        with self.assertRaisesRegex(ValueError, "buffer extent"):
            PhysicalSpec(
                layout="row_major",
                padded_shape=(4, 8),
                strides=(8, 1),
                base_offset=0,
                buffer_extent=16,
            )


class ArtifactTests(unittest.TestCase):
    def test_random_case_is_reproducible_and_checksum_protected(self):
        first = create_random_case(tiny_config(), seed=7)
        second = create_random_case(tiny_config(), seed=7)
        self.assertEqual(first.manifest["tensor_hashes"], second.manifest["tensor_hashes"])

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "case"
            save_case(first, path)
            loaded = load_case(path)
            self.assertEqual(loaded.manifest["case_hash"], first.manifest["case_hash"])

            tensors_path = path / "tensors.pt"
            tensors = torch.load(tensors_path, map_location="cpu", weights_only=True)
            tensors["input"][0, 0, 0] += 1
            torch.save(tensors, tensors_path)
            with self.assertRaisesRegex(ValueError, "checksum"):
                load_case(path)

    def test_random_case_has_expected_projection_contract(self):
        case = create_random_case(tiny_config(), seed=0)
        self.assertEqual(case.tensors["q_proj.qweight"].shape, (16, 8))
        self.assertEqual(case.tensors["down_proj.qweight"].shape, (32, 8))
        self.assertEqual(case.tensors["gate_proj.scales"].shape, (4, 32))
        self.assertEqual(case.manifest["rotation_contract"]["residual_basis"], "spinquant_rotated")

    def test_case_validation_rejects_tensor_shape_even_with_matching_hash(self):
        case = create_random_case(tiny_config(), seed=2)
        case.tensors["input"] = case.tensors["input"][:, :-1].contiguous()
        from spinquant_inference.layer_accuracy.tensor_io import tensor_sha256

        case.manifest["tensor_hashes"]["input"] = tensor_sha256(case.tensors["input"])
        from spinquant_inference.layer_accuracy.artifacts import _case_hash

        case.manifest["case_hash"] = _case_hash(case.manifest)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "expected shape"):
                save_case(case, Path(tmp) / "case")

    def test_checkpoint_loader_rejects_missing_or_wrong_tensors(self):
        config = tiny_config()
        random_case = create_random_case(config, seed=5)
        prefix = "model.layers.2."
        projection_names = {
            "q_proj": "self_attn.q_proj",
            "k_proj": "self_attn.k_proj",
            "v_proj": "self_attn.v_proj",
            "o_proj": "self_attn.o_proj",
            "gate_proj": "mlp.gate_proj",
            "up_proj": "mlp.up_proj",
            "down_proj": "mlp.down_proj",
        }
        state = {
            f"{prefix}input_layernorm.weight": random_case.tensors["input_norm.weight"],
            f"{prefix}post_attention_layernorm.weight": random_case.tensors[
                "post_attention_norm.weight"
            ],
        }
        for local, checkpoint in projection_names.items():
            state[f"{prefix}{checkpoint}.qweight"] = random_case.tensors[f"{local}.qweight"]
            state[f"{prefix}{checkpoint}.scales"] = random_case.tensors[f"{local}.scales"]

        with tempfile.TemporaryDirectory() as tmp:
            checkpoint = Path(tmp) / "layer.pt"
            torch.save(state, checkpoint)
            loaded = create_checkpoint_case(
                checkpoint,
                layer_index=2,
                checkpoint_profile="spinquant-w4a16-r3r4",
                config=config,
                seed=17,
            )
            self.assertEqual(loaded.tensors["q_proj.qweight"].shape, (16, 8))
            self.assertEqual(loaded.manifest["seed"], 17)

            del state[f"{prefix}self_attn.q_proj.scales"]
            torch.save(state, checkpoint)
            with self.assertRaisesRegex(ValueError, "missing required"):
                create_checkpoint_case(
                    checkpoint,
                    layer_index=2,
                    checkpoint_profile="spinquant-w4a16-r3r4",
                    config=config,
                )


class GraphExecutionTests(unittest.TestCase):
    def setUp(self):
        self.case = create_random_case(tiny_config(), seed=11)
        self.backend = TorchBackend(device="cpu")

    def test_every_stop_stage_returns_the_complete_prefix(self):
        for index, stage in enumerate(STAGE_NAMES):
            result = LayerExecutor(self.backend).run(self.case, stop_after=stage)
            self.assertEqual(result.stage_order, list(STAGE_NAMES[: index + 1]))
            self.assertIn(stage, result.captures)

    def test_r3_preserves_attention_dot_products(self):
        q = torch.randn(2, 4, 8, dtype=torch.float32)
        k = torch.randn(2, 4, 8, dtype=torch.float32)
        q_rot = self.backend.hadamard(q)
        k_rot = self.backend.hadamard(k)
        before = q @ k.transpose(-1, -2)
        after = q_rot @ k_rot.transpose(-1, -2)
        torch.testing.assert_close(after, before, rtol=1e-5, atol=1e-5)

    def test_invalid_stop_stage_is_rejected_before_execution(self):
        with self.assertRaisesRegex(ValueError, "unknown stop stage"):
            LayerExecutor(self.backend).run(self.case, stop_after="not_a_stage")

    def test_run_artifact_round_trip_preserves_metadata_and_captures(self):
        result = LayerExecutor(self.backend).run(self.case, stop_after="qk")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "run"
            save_run(result, path, capture_mode="semantic")
            metadata, captures, auxiliary = load_run(path)
            self.assertEqual(metadata["case_hash"], self.case.manifest["case_hash"])
            self.assertEqual(metadata["stop_after"], "qk")
            torch.testing.assert_close(captures["qk"], result.captures["qk"])
            self.assertIn("k_quant.packed", auxiliary)


class ComparatorTests(unittest.TestCase):
    def test_comparator_reports_worst_index_and_fails_non_finite(self):
        reference = {"input_norm": torch.tensor([1.0, 2.0])}
        candidate = {"input_norm": torch.tensor([1.0, 2.5])}
        report = compare_runs(reference, candidate, profile="llama2_fp16_w4kv4_v1")
        metric = report["stages"]["input_norm"]
        self.assertEqual(metric["worst_index"], [1])
        self.assertFalse(report["passed"])

        candidate["input_norm"][0] = math.nan
        report = compare_runs(reference, candidate, profile="llama2_fp16_w4kv4_v1")
        self.assertFalse(report["stages"]["input_norm"]["finite"])

    def test_quantized_stage_allows_sparse_bin_boundary_outliers(self):
        reference = {"k_quant": torch.ones(1000)}
        candidate = {"k_quant": torch.ones(1000)}
        candidate["k_quant"][:5] += 0.1
        report = compare_runs(reference, candidate)
        metric = report["stages"]["k_quant"]
        self.assertTrue(metric["passed"])
        self.assertEqual(metric["exceed_count"], 5)
        self.assertEqual(metric["exceed_fraction"], 0.005)

        candidate["k_quant"][:20] += 0.1
        report = compare_runs(reference, candidate)
        self.assertFalse(report["stages"]["k_quant"]["passed"])

    def test_pointwise_stage_still_rejects_any_threshold_outlier(self):
        reference = {"input_norm": torch.ones(1000)}
        candidate = {"input_norm": torch.ones(1000)}
        candidate["input_norm"][0] += 0.1
        report = compare_runs(reference, candidate)
        self.assertFalse(report["stages"]["input_norm"]["passed"])

    def test_post_quantization_layout_stage_keeps_upstream_error_budget(self):
        reference = {"head_concat": torch.ones(1000)}
        candidate = {"head_concat": torch.ones(1000)}
        candidate["head_concat"][:25] += 0.1
        report = compare_runs(reference, candidate)
        self.assertTrue(report["stages"]["head_concat"]["passed"])

        candidate["head_concat"][:35] += 0.1
        report = compare_runs(reference, candidate)
        self.assertFalse(report["stages"]["head_concat"]["passed"])


class GeneratorConformanceTests(unittest.TestCase):
    def test_v1_contract_matches_workload_generator_layout_intent(self):
        report = check_generator_conformance()
        self.assertTrue(report["passed"], report["mismatches"])
        self.assertTrue(report["advisory_only"])


if __name__ == "__main__":
    unittest.main()
