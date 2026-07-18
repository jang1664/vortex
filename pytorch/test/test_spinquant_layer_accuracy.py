import json
import math
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace

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
from spinquant_inference.layer_accuracy.backends import (  # noqa: E402
    DeferredScaledMaskedScores,
    TorchBackend,
    VortexBackend,
    decode_physical_tensor,
)
from spinquant_inference.layer_accuracy.cli import _make_case, _parser, _run  # noqa: E402
from spinquant_inference.layer_accuracy.compare import compare_runs  # noqa: E402
from spinquant_inference.layer_accuracy.graph import LayerExecutor  # noqa: E402
from spinquant_inference.layer_accuracy.generator_conformance import (  # noqa: E402
    check_generator_conformance,
)
from spinquant_inference.layer_accuracy.run_artifacts import (  # noqa: E402
    load_physical_run,
    load_run,
    save_run,
)
from spinquant_inference.layer_accuracy.specs import (  # noqa: E402
    LayerConfig,
    PhysicalSpec,
    QuantSpec,
    TensorSpec,
    TensorHandle,
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


def batched_tiny_config() -> LayerConfig:
    return LayerConfig(
        model="test-llama",
        hidden_size=16,
        intermediate_size=32,
        num_attention_heads=2,
        head_dim=8,
        batch_size=2,
        sequence_length=3,
        weight_group_size=4,
        kv_group_size=8,
    )


class TensorContractTests(unittest.TestCase):
    @staticmethod
    def _encode_tiled_weight(values: torch.Tensor, wtrans: int) -> torch.Tensor:
        k_dim, n_dim = values.shape
        encoded = []
        for kt in range(0, k_dim, 128):
            current = values[kt:kt + 128]
            for nt in range(0, n_dim, 32):
                for kb in range(0, current.shape[0], 32):
                    block = current[kb:kb + 32, nt:nt + 32]
                    if wtrans == 0:
                        encoded.append(pack_signed_int4(block).view(torch.uint8).reshape(-1))
                    else:
                        transposed = block.transpose(0, 1).contiguous()
                        encoded.append(pack_signed_int4(transposed).view(torch.uint8).reshape(-1))
        return torch.cat(encoded).reshape(k_dim, n_dim // 2)

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

    def test_gemm_c_physical_tensor_decodes_without_device_detile(self):
        # M=2, N=64 in the GEMM-C tile order used by C4.  Within one
        # 32-column tile, rows are interleaved before the next column tile.
        semantic = torch.arange(2 * 64, dtype=torch.float16).reshape(2, 64)
        physical = torch.empty_like(semantic)
        physical[:, :32] = semantic[:, :32]
        physical[:, 32:] = semantic[:, 32:]
        physical = physical.reshape(2, 2, 32).permute(1, 0, 2).contiguous().reshape(2, 64)
        spec = TensorSpec(
            "projection",
            ("M", "N"),
            (2, 64),
            "float16",
            physical=PhysicalSpec.contiguous(
                "gemm_c_tiled",
                (2, 64),
                grouping="matrix",
                parameters={"m": 2, "m_pad": 2, "n": 64},
            ),
        )
        handle = TensorHandle(spec, physical, "test")
        torch.testing.assert_close(decode_physical_tensor(handle), semantic, rtol=0, atol=0)
        buffers, descriptor = TorchBackend("cpu").capture_physical(handle)
        torch.testing.assert_close(buffers[0], physical, rtol=0, atol=0)
        self.assertEqual(
            descriptor["tensor_spec"]["physical"]["layout"], "gemm_c_tiled"
        )

    def test_packed_wtrans1_decodes_to_semantic_head_major_capture(self):
        weight = ((torch.arange(128 * 32).reshape(128, 32) % 16) - 8).to(torch.int8)
        tiled = self._encode_tiled_weight(weight, wtrans=1)
        spec = TensorSpec(
            "k.packed",
            ("B", "H", "S", "Dp"),
            (1, 1, 32, 64),
            "uint8",
            physical=PhysicalSpec.contiguous(
                "gemm_w_packed_grouped",
                tuple(tiled.shape),
                grouping="head",
                parameters={
                    "weight_k": 128,
                    "weight_n": 32,
                    "wtrans": 1,
                    "source_transposed": 1,
                },
            ),
        )
        handle = TensorHandle(spec, (tiled,), "test")
        expected = pack_signed_int4(weight.transpose(0, 1).contiguous()).reshape(1, 1, 32, 64)
        torch.testing.assert_close(decode_physical_tensor(handle), expected, rtol=0, atol=0)

    def test_packed_wtrans0_decodes_to_semantic_capture(self):
        weight = ((torch.arange(32 * 128).reshape(32, 128) % 16) - 8).to(torch.int8)
        tiled = self._encode_tiled_weight(weight, wtrans=0)
        spec = TensorSpec(
            "v.packed",
            ("B", "H", "S", "Dp"),
            (1, 1, 32, 64),
            "uint8",
            physical=PhysicalSpec.contiguous(
                "gemm_w_packed_grouped",
                tuple(tiled.shape),
                grouping="head",
                parameters={
                    "weight_k": 32,
                    "weight_n": 128,
                    "wtrans": 0,
                    "source_transposed": 0,
                },
            ),
        )
        handle = TensorHandle(spec, (tiled,), "test")
        expected = pack_signed_int4(weight).reshape(1, 1, 32, 64)
        torch.testing.assert_close(decode_physical_tensor(handle), expected, rtol=0, atol=0)


class ArtifactTests(unittest.TestCase):
    def test_random_case_expands_position_tables_for_each_batch(self):
        case = create_random_case(batched_tiny_config(), seed=0)
        self.assertEqual(case.tensors["input"].shape, (2, 3, 16))
        self.assertEqual(case.tensors["position_ids"].shape, (2, 3))
        self.assertEqual(case.tensors["rope_cos"].shape, (2, 3, 8))
        self.assertEqual(case.tensors["rope_sin"].shape, (2, 3, 8))
        torch.testing.assert_close(
            case.tensors["position_ids"][0], case.tensors["position_ids"][1]
        )

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

    def test_cpu_reference_runs_batched_variable_length_prefill(self):
        case = create_random_case(batched_tiny_config(), seed=12)
        result = LayerExecutor(TorchBackend("cpu")).run(
            case, stop_after="final_residual"
        )
        self.assertEqual(result.captures["qk"].shape, (2, 2, 3, 3))
        self.assertEqual(result.captures["final_residual"].shape, (2, 3, 16))

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

    def test_split_heads_is_owned_by_backend(self):
        self.backend.bind(self.case)
        linear = torch.arange(1 * 4 * 16, dtype=torch.float16).reshape(1, 4, 16)
        split = self.backend.split_heads(linear)
        self.assertEqual(split.shape, (1, 2, 4, 8))
        torch.testing.assert_close(split[:, 0], linear[:, :, :8], rtol=0, atol=0)

    def test_stopping_at_deferred_scores_does_not_launch_softmax(self):
        class DeferredBackend(TorchBackend):
            def __init__(self):
                super().__init__("cpu")
                self.softmax_calls = 0

            def scaled_masked_scores(self, qk, head_dim):
                return DeferredScaledMaskedScores(qk, head_dim)

            def canonicalize(self, value):
                if isinstance(value, DeferredScaledMaskedScores):
                    qk = super().canonicalize(value.qk)
                    return (
                        qk.float() / math.sqrt(value.head_dim)
                        + self.tensor("causal_mask").float()
                    ).half()
                return super().canonicalize(value)

            def softmax(self, scores):
                self.softmax_calls += 1
                return super().softmax(scores)

        backend = DeferredBackend()
        result = LayerExecutor(backend).run(self.case, stop_after="scaled_masked_scores")
        self.assertEqual(result.stage_order[-1], "scaled_masked_scores")
        self.assertEqual(backend.softmax_calls, 0)

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

    def test_capture_modes_serialize_distinct_artifacts(self):
        result = LayerExecutor(self.backend).run(
            self.case, stop_after="input_norm", capture_physical=True
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            semantic_path = root / "semantic"
            save_run(result, semantic_path, capture_mode="semantic")
            self.assertTrue((semantic_path / "captures.pt").is_file())
            self.assertFalse((semantic_path / "physical_captures.pt").exists())

            both_path = root / "both"
            save_run(result, both_path, capture_mode="both")
            _, physical, descriptors = load_physical_run(both_path)
            torch.testing.assert_close(physical["input_norm"], result.captures["input_norm"])
            self.assertEqual(
                descriptors["input_norm"]["tensor_spec"]["physical"]["layout"],
                "row_major",
            )

            physical_path = root / "physical"
            save_run(result, physical_path, capture_mode="physical")
            self.assertFalse((physical_path / "captures.pt").exists())
            with self.assertRaisesRegex(ValueError, "physical captures only"):
                load_run(physical_path)


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
        self.assertEqual(report["variant"], report["variants"]["standalone"])
        self.assertIsInstance(report["checked_kernels"], list)
        self.assertEqual(
            report["checked_kernels"],
            report["checked_kernels_by_plan"]["standalone"],
        )
        self.assertIn("attn_softmax", report["checked_kernels_by_plan"]["fused"])


class PhysicalPlanInterfaceTests(unittest.TestCase):
    @staticmethod
    def _fused_case(batch_size: int, sequence_length: int):
        config = LayerConfig(
            batch_size=batch_size,
            sequence_length=sequence_length,
        )
        return SimpleNamespace(
            config=config,
            tensors={
                "score_scale": torch.full(
                    (
                        batch_size,
                        config.num_attention_heads,
                        sequence_length,
                        sequence_length,
                    ),
                    1.0 / math.sqrt(config.head_dim),
                    dtype=torch.float16,
                ),
                "causal_mask": torch.triu(
                    torch.full(
                        (1, 1, sequence_length, sequence_length),
                        torch.finfo(torch.float16).min,
                    ),
                    diagonal=1,
                ),
            },
        )

    def test_make_case_cli_accepts_batch_and_sequence_length(self):
        parser = _parser()
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "case"
            args = parser.parse_args(
                [
                    "make-case",
                    "--source",
                    "random",
                    "--batch-size",
                    "2",
                    "--seq-len",
                    "3",
                    "--output",
                    str(output),
                ]
            )
            self.assertEqual(_make_case(args), 0)
            case = load_case(output)
            self.assertEqual(case.config.batch_size, 2)
            self.assertEqual(case.config.sequence_length, 3)

    def test_cli_accepts_both_physical_plans_and_defaults_to_standalone(self):
        parser = _parser()
        common = [
            "run", "--case", "case", "--backend", "vortex", "--strict-native",
            "--output", "run",
        ]
        self.assertEqual(parser.parse_args(common).physical_plan, "standalone")
        self.assertEqual(
            parser.parse_args(common + ["--physical-plan", "fused"]).physical_plan,
            "fused",
        )

    def test_vortex_backend_selects_explicit_strategy(self):
        standalone = VortexBackend(physical_plan="standalone")
        fused = VortexBackend(physical_plan="fused")
        self.assertEqual(standalone.physical_plan, "standalone")
        self.assertEqual(fused.physical_plan, "fused")
        self.assertNotEqual(type(standalone.layout_plan), type(fused.layout_plan))
        self.assertIn("hadamard_layout_fused", fused.layout_plan.required_ops)
        self.assertNotIn("hadamard_butterfly", fused.layout_plan.required_ops)
        self.assertNotIn("hadamard_base", fused.layout_plan.required_ops)
        self.assertNotIn("tile_input_a", fused.COMMON_REQUIRED_OPS)
        self.assertIn("tile_input_a", standalone.layout_plan.required_ops)
        with self.assertRaisesRegex(ValueError, "physical plan"):
            VortexBackend(physical_plan="unknown")

    def test_fused_plan_is_rejected_for_cpu_before_case_loading(self):
        args = Namespace(
            backend="cpu",
            physical_plan="fused",
            case=Path("does-not-exist"),
        )
        with self.assertRaisesRegex(SystemExit, "valid only with --backend vortex"):
            _run(args)

    def test_fused_case_rejects_noncanonical_score_inputs(self):
        config = LayerConfig()
        scale = torch.full(
            (1, 32, 32, 32), 1.0 / math.sqrt(config.head_dim), dtype=torch.float16
        )
        mask = torch.triu(
            torch.full((1, 1, 32, 32), torch.finfo(torch.float16).min),
            diagonal=1,
        )
        case = SimpleNamespace(
            config=config, tensors={"score_scale": scale, "causal_mask": mask}
        )
        VortexBackend._validate_fused_case(case)
        case.tensors["score_scale"] = scale.clone()
        case.tensors["score_scale"][0, 0, 0, 0] = 1
        with self.assertRaisesRegex(ValueError, "score_scale"):
            VortexBackend._validate_fused_case(case)
        case.tensors["score_scale"] = scale
        case.tensors["causal_mask"] = mask.clone()
        case.tensors["causal_mask"][0, 0, 0, 0] = -1
        with self.assertRaisesRegex(ValueError, "causal mask"):
            VortexBackend._validate_fused_case(case)

    def test_fused_case_accepts_multiple_m_tiles(self):
        for batch_size, sequence_length in ((2, 32), (4, 32), (1, 160), (1, 256)):
            with self.subTest(
                batch_size=batch_size,
                sequence_length=sequence_length,
            ):
                VortexBackend._validate_fused_case(
                    self._fused_case(batch_size, sequence_length)
                )

    def test_fused_case_rejects_partial_sequence_micro_tile(self):
        case = self._fused_case(2, 16)
        with self.assertRaisesRegex(ValueError, "32-column"):
            VortexBackend._validate_fused_case(case)


if __name__ == "__main__":
    unittest.main()
