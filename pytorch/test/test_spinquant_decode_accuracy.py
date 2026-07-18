import tempfile
import unittest
from pathlib import Path

import torch


SPINQUANT_ROOT = Path(__file__).resolve().parents[1] / "spinquant"
import sys

sys.path.insert(0, str(SPINQUANT_ROOT))

from spinquant_inference.layer_accuracy.artifacts import (  # noqa: E402
    DECODE_GRAPH_VERSION,
    create_random_decode_case,
    load_decode_case,
    save_decode_case,
)
from spinquant_inference.layer_accuracy.cli import _make_decode_case, _parser  # noqa: E402
from spinquant_inference.layer_accuracy.specs import (  # noqa: E402
    CacheGeometry,
    CacheState,
    DecodeConfig,
    LayerConfig,
)
from spinquant_inference.layer_accuracy.tensor_io import tensor_sha256  # noqa: E402
from spinquant_inference.layer_accuracy.artifacts import _case_hash  # noqa: E402
from spinquant_inference.layer_accuracy.stages import DecodeStopPoint  # noqa: E402


def tiny_layer_config(*, sequence_length: int = 5) -> LayerConfig:
    return LayerConfig(
        model="test-llama",
        hidden_size=16,
        intermediate_size=32,
        num_attention_heads=2,
        head_dim=8,
        batch_size=1,
        sequence_length=sequence_length,
        weight_group_size=4,
        kv_group_size=8,
    )


class DecodeArtifactContractTests(unittest.TestCase):
    def test_random_decode_case_round_trip_preserves_hash_and_boundaries(self):
        config = DecodeConfig(
            layer=tiny_layer_config(),
            prompt_length=3,
            decode_steps=2,
            max_sequence_length=8,
        )
        case = create_random_decode_case(config, seed=19)

        self.assertEqual(case.manifest["graph_version"], DECODE_GRAPH_VERSION)
        self.assertEqual(case.tensors["prompt_input"].shape, (1, 3, 16))
        self.assertEqual(case.tensors["decode_inputs"].shape, (2, 1, 1, 16))
        self.assertEqual(case.tensors["prompt_position_ids"].tolist(), [[0, 1, 2]])
        self.assertEqual(case.tensors["decode_position_ids"].tolist(), [[[3]], [[4]]])

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "decode-case"
            save_decode_case(case, path)
            loaded = load_decode_case(path)

        self.assertEqual(loaded.manifest["case_hash"], case.manifest["case_hash"])
        self.assertEqual(loaded.config, config)
        torch.testing.assert_close(loaded.tensors["decode_inputs"], case.tensors["decode_inputs"])

    def test_decode_config_rejects_invalid_prompt_and_capacity(self):
        with self.assertRaisesRegex(ValueError, "prompt_length must be positive"):
            DecodeConfig(tiny_layer_config(), prompt_length=0, decode_steps=2, max_sequence_length=8)
        with self.assertRaisesRegex(ValueError, "exceeds max_sequence_length"):
            DecodeConfig(
                tiny_layer_config(sequence_length=6),
                prompt_length=4,
                decode_steps=2,
                max_sequence_length=5,
            )
        with self.assertRaisesRegex(ValueError, "sequence_length"):
            DecodeConfig(tiny_layer_config(sequence_length=6), 3, 2, 8)

    def test_decode_case_rejects_non_monotonic_positions(self):
        config = DecodeConfig(tiny_layer_config(), 3, 2, 8)
        case = create_random_decode_case(config, seed=23)
        case.tensors["decode_position_ids"][1, 0, 0] = 3
        case.manifest["tensor_hashes"]["decode_position_ids"] = tensor_sha256(
            case.tensors["decode_position_ids"]
        )
        case.manifest["case_hash"] = _case_hash(case.manifest)

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "strictly increasing"):
                save_decode_case(case, Path(tmp) / "decode-case")

    def test_cli_creates_random_decode_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "decode-case"
            args = _parser().parse_args(
                [
                    "make-decode-case",
                    "--source",
                    "random",
                    "--output",
                    str(path),
                    "--batch-size",
                    "1",
                    "--prompt-len",
                    "3",
                    "--decode-steps",
                    "2",
                    "--max-seq-len",
                    "8",
                ]
            )
            self.assertEqual(_make_decode_case(args), 0)
            case = load_decode_case(path)
        self.assertEqual(case.config.prompt_length, 3)
        self.assertEqual(case.config.decode_steps, 2)

    def test_decode_stop_point_validates_step_and_stage(self):
        point = DecodeStopPoint(step=0, stage="qk")
        point.validate(decode_steps=2)
        with self.assertRaisesRegex(ValueError, "decode step"):
            DecodeStopPoint(step=2, stage="qk").validate(decode_steps=2)
        with self.assertRaisesRegex(ValueError, "unknown stop stage"):
            DecodeStopPoint(step=0, stage="not-a-stage").validate(decode_steps=2)


class CacheLifecycleContractTests(unittest.TestCase):
    def setUp(self):
        self.geometry = CacheGeometry(
            batch_size=2,
            num_kv_heads=2,
            head_dim=8,
            max_sequence_length=8,
            padded_sequence_length=32,
        )

    def test_prefill_append_full_and_reset_lifecycle(self):
        state = CacheState(self.geometry, allocation_id="cache-0")
        self.assertEqual(state.lifecycle, "empty")
        state.commit_prefill(6)
        state.commit_append(position=6)
        state.commit_append(position=7)
        self.assertEqual(state.logical_length, 8)
        self.assertEqual(state.lifecycle, "full")

        with self.assertRaisesRegex(ValueError, "full"):
            state.commit_append(position=8)

        old_generation = state.cache_generation
        state.reset()
        self.assertEqual(state.logical_length, 0)
        self.assertEqual(state.lifecycle, "empty")
        self.assertEqual(state.cache_generation, old_generation + 1)
        self.assertEqual(state.allocation_id, "cache-0")

    def test_append_before_prefill_and_stale_generation_are_rejected(self):
        state = CacheState(self.geometry, allocation_id="cache-0")
        with self.assertRaisesRegex(ValueError, "prefill"):
            state.commit_append(position=0)
        state.commit_prefill(2)
        generation = state.cache_generation
        state.reset()
        with self.assertRaisesRegex(ValueError, "stale cache generation"):
            state.require_generation(generation)


if __name__ == "__main__":
    unittest.main()
