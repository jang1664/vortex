import json
import tempfile
import unittest
from pathlib import Path

import torch


SPINQUANT_ROOT = Path(__file__).resolve().parents[1] / "spinquant"
import sys

sys.path.insert(0, str(SPINQUANT_ROOT))

from spinquant_inference.layer_accuracy.artifacts import (  # noqa: E402
    StackLayerSource,
    create_checkpoint_stack_case,
    create_random_stack_case,
    load_stack_case,
    save_stack_case,
)
from spinquant_inference.layer_accuracy.backends import TorchBackend  # noqa: E402
from spinquant_inference.layer_accuracy.cli import (  # noqa: E402
    _make_stack_case,
    _parser,
    _run,
)
from spinquant_inference.layer_accuracy.compare import (  # noqa: E402
    _semantic_stage,
    compare_runs,
)
from spinquant_inference.layer_accuracy.graph import (  # noqa: E402
    LayerExecutor,
    StackExecutor,
)
from spinquant_inference.layer_accuracy.run_artifacts import (  # noqa: E402
    load_stack_run,
    save_stack_run,
)
from spinquant_inference.layer_accuracy.specs import (  # noqa: E402
    LayerConfig,
    StackConfig,
)


def tiny_config(*, model: str = "test-llama", gqa: bool = False) -> LayerConfig:
    return LayerConfig(
        model=model,
        hidden_size=32 if gqa else 16,
        intermediate_size=64 if gqa else 32,
        num_attention_heads=4 if gqa else 2,
        num_key_value_heads=2 if gqa else 2,
        head_dim=8,
        batch_size=1,
        sequence_length=4,
        weight_group_size=4,
        kv_group_size=8,
    )


def stack_config(*, layers: int = 3, layer_start: int = 0, gqa: bool = False):
    return StackConfig(
        layer=tiny_config(model="test-llama-gqa" if gqa else "test-llama", gqa=gqa),
        num_hidden_layers=8,
        layer_start=layer_start,
        layer_count=layers,
    )


def checkpoint_state(config: StackConfig, *, seed: int = 90) -> dict[str, torch.Tensor]:
    state = {}
    for layer_index in config.layer_indices:
        layer = create_random_stack_case(
            StackConfig(config.layer, config.num_hidden_layers, layer_index, 1),
            seed=seed + layer_index,
            random_weight_mode="shared",
        )
        prefix = f"model.layers.{layer_index}."
        state[f"{prefix}input_layernorm.weight"] = layer.tensors["input_norm.weight"]
        state[f"{prefix}post_attention_layernorm.weight"] = layer.tensors[
            "post_attention_norm.weight"
        ]
        names = {
            "q_proj": "self_attn.q_proj",
            "k_proj": "self_attn.k_proj",
            "v_proj": "self_attn.v_proj",
            "o_proj": "self_attn.o_proj",
            "gate_proj": "mlp.gate_proj",
            "up_proj": "mlp.up_proj",
            "down_proj": "mlp.down_proj",
        }
        for local_name, checkpoint_name in names.items():
            state[f"{prefix}{checkpoint_name}.qweight"] = layer.tensors[
                f"{local_name}.qweight"
            ]
            state[f"{prefix}{checkpoint_name}.scales"] = layer.tensors[
                f"{local_name}.scales"
            ]
    return state


class StackArtifactTests(unittest.TestCase):
    def test_stack_config_uses_model_global_layer_indices(self):
        config = stack_config(layers=3, layer_start=2)
        self.assertEqual(config.layer_indices, (2, 3, 4))
        with self.assertRaisesRegex(ValueError, "layer range"):
            StackConfig(config.layer, num_hidden_layers=4, layer_start=2, layer_count=3)

    def test_shared_random_stack_round_trip_and_source(self):
        case = create_random_stack_case(
            stack_config(), seed=7, random_weight_mode="shared"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "stack"
            save_stack_case(case, path)
            loaded = load_stack_case(path)
            self.assertEqual(loaded.manifest["case_hash"], case.manifest["case_hash"])
            source = StackLayerSource(loaded)
            layer0 = source.layer_case(0)
            layer2 = source.layer_case(2)
            self.assertIs(layer0.tensors["q_proj.qweight"], layer2.tensors["q_proj.qweight"])

    def test_independent_random_stack_is_reproducible_per_layer(self):
        case = create_random_stack_case(
            stack_config(layer_start=2), seed=11, random_weight_mode="independent"
        )
        first = StackLayerSource(case)
        second = StackLayerSource(case)
        torch.testing.assert_close(
            first.layer_case(3).tensors["q_proj.qweight"],
            second.layer_case(3).tensors["q_proj.qweight"],
            rtol=0,
            atol=0,
        )
        self.assertFalse(
            torch.equal(
                first.layer_case(2).tensors["q_proj.qweight"],
                first.layer_case(3).tensors["q_proj.qweight"],
            )
        )

    def test_checkpoint_stack_selects_distinct_layers_and_checks_signature(self):
        config = stack_config(layer_start=2)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            checkpoint = root / "checkpoint.pt"
            torch.save(checkpoint_state(config), checkpoint)
            case = create_checkpoint_stack_case(
                checkpoint,
                config=config,
                checkpoint_profile="spinquant-w4a16-r3r4",
                seed=13,
            )
            path = root / "stack"
            save_stack_case(case, path)
            loaded = load_stack_case(path)
            source = StackLayerSource(loaded)
            self.assertFalse(
                torch.equal(
                    source.layer_case(2).tensors["q_proj.qweight"],
                    source.layer_case(3).tensors["q_proj.qweight"],
                )
            )
            checkpoint.touch()
            with self.assertRaisesRegex(ValueError, "checkpoint signature"):
                load_stack_case(path)


class StackExecutionTests(unittest.TestCase):
    def test_stack_matches_manual_backend_native_chaining(self):
        case = create_random_stack_case(
            stack_config(), seed=17, random_weight_mode="independent"
        )
        result = StackExecutor(TorchBackend("cpu")).run(case)
        self.assertEqual(
            list(result.captures),
            ["layer0.final_residual", "layer1.final_residual", "layer2.final_residual"],
        )

        source = StackLayerSource(case)
        backend = TorchBackend("cpu")
        current = case.tensors["input"]
        manual = []
        for offset, layer_index in enumerate(case.config.layer_indices):
            layer_result = LayerExecutor(backend).run(
                source.layer_case(layer_index),
                input_override=current,
                capture_stages={"final_residual"},
                preflight=offset == 0,
            )
            current = layer_result.terminal_value
            manual.append(layer_result.captures["final_residual"])
        for layer_index, expected in zip(case.config.layer_indices, manual):
            torch.testing.assert_close(
                result.captures[f"layer{layer_index}.final_residual"], expected
            )

    def test_stack_stop_targets_model_global_layer_and_stage(self):
        case = create_random_stack_case(
            stack_config(layer_start=2), seed=19, random_weight_mode="shared"
        )
        result = StackExecutor(TorchBackend("cpu")).run(
            case, stop_after_layer=3, stop_after="qk"
        )
        self.assertIn("layer2.final_residual", result.captures)
        self.assertIn("layer3.qk", result.captures)
        self.assertNotIn("layer4.final_residual", result.captures)
        self.assertEqual(result.layers[-1].layer_index, 3)
        self.assertEqual(result.layers[-1].stage_order[-1], "qk")

    def test_checkpoint_layer_change_propagates_only_from_that_layer(self):
        config = stack_config(layer_start=2)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline_state = checkpoint_state(config, seed=120)
            changed_state = dict(baseline_state)
            changed_name = "model.layers.3.self_attn.q_proj.qweight"
            changed_state[changed_name] = torch.zeros_like(changed_state[changed_name])
            baseline_path = root / "baseline.pt"
            changed_path = root / "changed.pt"
            torch.save(baseline_state, baseline_path)
            torch.save(changed_state, changed_path)
            baseline_case = create_checkpoint_stack_case(
                baseline_path,
                config=config,
                checkpoint_profile="spinquant-w4a16-r3r4",
                seed=37,
            )
            changed_case = create_checkpoint_stack_case(
                changed_path,
                config=config,
                checkpoint_profile="spinquant-w4a16-r3r4",
                seed=37,
            )
            baseline = StackExecutor(TorchBackend("cpu")).run(baseline_case)
            changed = StackExecutor(TorchBackend("cpu")).run(changed_case)
            torch.testing.assert_close(
                baseline.captures["layer2.final_residual"],
                changed.captures["layer2.final_residual"],
                rtol=0,
                atol=0,
            )
            self.assertFalse(
                torch.equal(
                    baseline.captures["layer3.final_residual"],
                    changed.captures["layer3.final_residual"],
                )
            )
            self.assertFalse(
                torch.equal(
                    baseline.captures["layer4.final_residual"],
                    changed.captures["layer4.final_residual"],
                )
            )

    def test_capture_filter_preserves_stage_order(self):
        case = create_random_stack_case(stack_config(layers=1), seed=23)
        source = StackLayerSource(case)
        result = LayerExecutor(TorchBackend("cpu")).run(
            source.layer_case(0), capture_stages={"final_residual"}
        )
        self.assertEqual(list(result.captures), ["final_residual"])
        self.assertGreater(len(result.stage_order), 1)
        self.assertIsNotNone(result.terminal_value)

    def test_capture_filter_accepts_one_shot_iterable_for_every_layer(self):
        case = create_random_stack_case(stack_config(layers=2), seed=27)
        result = StackExecutor(TorchBackend("cpu")).run(
            case, capture_stages=iter(("input_norm", "final_residual"))
        )
        self.assertEqual(
            list(result.captures),
            [
                "layer0.input_norm",
                "layer0.final_residual",
                "layer1.input_norm",
                "layer1.final_residual",
            ],
        )

    def test_physical_descriptor_buffers_are_layer_qualified(self):
        case = create_random_stack_case(stack_config(layers=2), seed=28)
        result = StackExecutor(TorchBackend("cpu")).run(
            case, capture_physical=True
        )
        for descriptor in result.physical_descriptors.values():
            for buffer_name in descriptor["buffers"]:
                self.assertIn(buffer_name, result.physical_captures)

    def test_small_gqa_stack_uses_layer_qualified_boundaries(self):
        case = create_random_stack_case(
            stack_config(layers=2, gqa=True), seed=29, random_weight_mode="shared"
        )
        result = StackExecutor(TorchBackend("cpu")).run(case)
        self.assertEqual(result.captures["layer0.final_residual"].shape, (1, 4, 32))
        self.assertEqual(result.captures["layer1.final_residual"].shape, (1, 4, 32))


class StackArtifactAndCliTests(unittest.TestCase):
    def test_stack_run_round_trip_and_first_failing_layer(self):
        case = create_random_stack_case(stack_config(layers=2), seed=31)
        result = StackExecutor(TorchBackend("cpu")).run(case)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "run"
            save_stack_run(result, path, capture_mode="semantic")
            metadata, captures, auxiliary = load_stack_run(path)
            self.assertEqual(metadata["run_kind"], "decoder_stack")
            self.assertEqual(metadata["layers"][1]["layer_index"], 1)
            self.assertFalse(auxiliary)
            torch.testing.assert_close(
                captures["layer1.final_residual"],
                result.captures["layer1.final_residual"],
            )

            candidate = dict(captures)
            candidate["layer1.final_residual"] = candidate[
                "layer1.final_residual"
            ].clone()
            candidate["layer1.final_residual"][0, 0, 0] += 4
            report = compare_runs(captures, candidate)
            self.assertFalse(report["passed"])
            self.assertEqual(report["first_failing_layer"], 1)

    def test_semantic_stage_strips_layer_qualifier(self):
        self.assertEqual(_semantic_stage("layer12.qk"), "qk")
        self.assertEqual(_semantic_stage("layer12.k_quant.packed"), "k_quant")

    def test_cli_creates_and_runs_stack_case(self):
        parser = _parser()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            case_path = root / "case"
            make_args = parser.parse_args(
                [
                    "make-stack-case",
                    "--source",
                    "random",
                    "--model",
                    "llama2-7b",
                    "--num-layers",
                    "2",
                    "--random-weight-mode",
                    "shared",
                    "--output",
                    str(case_path),
                ]
            )
            self.assertEqual(_make_stack_case(make_args), 0)
            manifest = json.loads((case_path / "manifest.json").read_text())
            self.assertEqual(manifest["case_kind"], "decoder_stack")

            run_path = root / "run"
            run_args = parser.parse_args(
                [
                    "run",
                    "--case",
                    str(case_path),
                    "--backend",
                    "cpu",
                    "--stop-after-layer",
                    "0",
                    "--stop-after",
                    "input_norm",
                    "--output",
                    str(run_path),
                ]
            )
            self.assertEqual(_run(run_args), 0)
            metadata, captures, _ = load_stack_run(run_path)
            self.assertEqual(metadata["stop_after"], {"layer": 0, "stage": "input_norm"})
            self.assertEqual(list(captures), ["layer0.input_norm"])


if __name__ == "__main__":
    unittest.main()
