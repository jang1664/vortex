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
    materialize_decode_prefix,
    save_decode_case,
)
from spinquant_inference.layer_accuracy.backends import TorchBackend  # noqa: E402
from spinquant_inference.layer_accuracy.cli import _make_decode_case, _parser  # noqa: E402
from spinquant_inference.layer_accuracy.graph import DecodeExecutor, LayerExecutor  # noqa: E402
from spinquant_inference.layer_accuracy.run_artifacts import (  # noqa: E402
    load_decode_run,
    save_decode_run,
)
from spinquant_inference.layer_accuracy.specs import (  # noqa: E402
    CacheGeometry,
    CacheState,
    DecodeConfig,
    LayerConfig,
)
from spinquant_inference.layer_accuracy.tensor_io import tensor_sha256  # noqa: E402
from spinquant_inference.layer_accuracy.artifacts import _case_hash  # noqa: E402
from spinquant_inference.layer_accuracy.stages import DecodeStopPoint  # noqa: E402
from spinquant_inference.modeling.quantized_kv_cache import (  # noqa: E402
    FixedCapacityKVQuantizedCache,
)


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


class FixedCapacitySemanticCacheTests(unittest.TestCase):
    def _cache(self, *, capacity: int = 8) -> FixedCapacityKVQuantizedCache:
        return FixedCapacityKVQuantizedCache(
            batch_size=2,
            num_kv_heads=2,
            head_dim=8,
            max_sequence_length=capacity,
            device="cpu",
        )

    @staticmethod
    def _values(length: int, *, offset: float = 0.0) -> tuple[torch.Tensor, torch.Tensor]:
        values = torch.arange(2 * 2 * length * 8, dtype=torch.float16).reshape(
            2, 2, length, 8
        )
        return values + offset, values.flip(-1) - offset

    def test_prefill_and_append_mutate_preallocated_slices_only(self):
        cache = self._cache(capacity=8)
        addresses = cache.buffer_addresses()
        key, value = self._values(3)
        cache.prefill(key, value)
        before = tuple(tensor.clone() for tensor in cache.storage_tensors())

        next_key, next_value = self._values(1, offset=100.0)
        cache.append(next_key, next_value, position=3)
        self.assertEqual(cache.logical_length, 4)
        self.assertEqual(cache.buffer_addresses(), addresses)

        after = cache.storage_tensors()
        for old, new in zip(before, after):
            torch.testing.assert_close(old[:, :, :3], new[:, :, :3], rtol=0, atol=0)
            torch.testing.assert_close(old[:, :, 4:], new[:, :, 4:], rtol=0, atol=0)
        self.assertEqual(cache.get_kv()[0][0].shape, (2, 2, 4, 4))

    def test_capacity_overflow_is_rejected_before_mutation(self):
        cache = self._cache(capacity=3)
        key, value = self._values(3)
        cache.prefill(key, value)
        before = tuple(tensor.clone() for tensor in cache.storage_tensors())
        next_key, next_value = self._values(1, offset=100.0)

        with self.assertRaisesRegex(ValueError, "full"):
            cache.append(next_key, next_value, position=3)
        self.assertEqual(cache.logical_length, 3)
        for old, new in zip(before, cache.storage_tensors()):
            torch.testing.assert_close(old, new, rtol=0, atol=0)

    def test_reset_reuses_allocation_and_rejects_stale_generation(self):
        cache = self._cache()
        key, value = self._values(2)
        cache.prefill(key, value)
        addresses = cache.buffer_addresses()
        old_generation = cache.cache_generation
        cache.reset()
        new_key, new_value = self._values(1, offset=-200.0)
        cache.prefill(new_key, new_value)

        self.assertEqual(cache.buffer_addresses(), addresses)
        self.assertEqual(cache.logical_length, 1)
        with self.assertRaisesRegex(ValueError, "stale cache generation"):
            cache.get_kv(generation=old_generation)


class DecodeExecutorTests(unittest.TestCase):
    def setUp(self):
        self.case = create_random_decode_case(
            DecodeConfig(tiny_layer_config(), 3, 2, 8), seed=31
        )

    def test_stop_in_first_decode_step_prevents_later_cache_mutation(self):
        result = DecodeExecutor(TorchBackend("cpu")).run(
            self.case, stop_after=DecodeStopPoint(step=0, stage="qk")
        )
        self.assertEqual(len(result.steps), 1)
        self.assertEqual(result.steps[0].stage_order[-1], "qk")
        self.assertEqual(result.cache_descriptor["logical_length"], 4)

    def test_incremental_outputs_match_full_prefix_recomputation(self):
        result = DecodeExecutor(TorchBackend("cpu")).run(self.case)
        self.assertEqual(len(result.steps), 2)
        for step_index, step in enumerate(result.steps):
            logical_length = self.case.config.prompt_length + step_index + 1
            prefix = materialize_decode_prefix(self.case, logical_length=logical_length)
            reference = LayerExecutor(TorchBackend("cpu")).run(prefix)
            torch.testing.assert_close(
                step.captures["final_residual"],
                reference.captures["final_residual"][:, -1:],
                rtol=2e-3,
                atol=2e-3,
            )
            self.assertEqual(step.logical_length, logical_length)

    def test_decode_run_artifact_preserves_per_step_metadata(self):
        result = DecodeExecutor(TorchBackend("cpu")).run(self.case)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "decode-run"
            save_decode_run(result, path, capture_mode="semantic")
            metadata, captures, auxiliary = load_decode_run(path)

        self.assertEqual(metadata["run_kind"], "decode")
        self.assertEqual(metadata["steps"][0]["logical_length"], 4)
        self.assertEqual(metadata["steps"][1]["logical_length"], 5)
        descriptors = [
            metadata["prefill"]["cache_descriptor"],
            *(step["cache_descriptor"] for step in metadata["steps"]),
        ]
        self.assertEqual(
            len({descriptor["allocation_id"] for descriptor in descriptors}), 1
        )
        self.assertEqual(
            [descriptor["logical_length"] for descriptor in descriptors],
            [3, 4, 5],
        )
        self.assertIn("step0.qk", captures)
        self.assertIn("step1.cache_update.k_packed", auxiliary)

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA is required for the GPU oracle")
    def test_cuda_incremental_reference_matches_full_prefix_cuda(self):
        cuda = DecodeExecutor(TorchBackend("cuda")).run(self.case)
        for step_index, cuda_step in enumerate(cuda.steps):
            logical_length = self.case.config.prompt_length + step_index + 1
            prefix = materialize_decode_prefix(self.case, logical_length=logical_length)
            reference = LayerExecutor(TorchBackend("cuda")).run(prefix)
            torch.testing.assert_close(
                cuda_step.captures["final_residual"],
                reference.captures["final_residual"][:, -1:],
                rtol=2e-3,
                atol=2e-3,
            )


if __name__ == "__main__":
    unittest.main()
