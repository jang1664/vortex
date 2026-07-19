"""Strict-native persistent decode integration tests on a real C4 FPGA."""

import os
import unittest


@unittest.skipUnless(
    os.environ.get("RUN_VORTEX_TESTS") == "1",
    "Vortex runtime test not requested",
)
class SpinQuantDecodeVortexIntegrationTests(unittest.TestCase):
    @staticmethod
    def _buffer_addresses(descriptor):
        return {
            cache_kind: [
                {
                    name: buffer["address"]
                    for name, buffer in group.items()
                }
                for group in descriptor["buffers"][cache_kind]
            ]
            for cache_kind in ("key", "value")
        }

    @staticmethod
    def _run(
        *, prompt_length, decode_steps, capacity, stop_step, stop_stage,
        model="llama2-7b"
    ):
        from spinquant_inference.layer_accuracy.artifacts import (
            create_random_decode_case,
        )
        from spinquant_inference.layer_accuracy.backends import VortexBackend
        from spinquant_inference.layer_accuracy.graph import DecodeExecutor
        from spinquant_inference.layer_accuracy.specs import DecodeConfig, LayerConfig
        from spinquant_inference.layer_accuracy.stages import DecodeStopPoint

        config = DecodeConfig(
            layer=LayerConfig.for_model(
                model,
                batch_size=1,
                sequence_length=prompt_length + decode_steps,
            ),
            prompt_length=prompt_length,
            decode_steps=decode_steps,
            max_sequence_length=capacity,
        )
        case = create_random_decode_case(config, seed=11)
        return DecodeExecutor(
            VortexBackend(strict_native=True, physical_plan="fused")
        ).run(
            case,
            stop_after=DecodeStopPoint(step=stop_step, stage=stop_stage),
            capture_physical=True,
        )

    def test_llama3_gqa_decode_groups_queries_into_eight_m4_gemms(self):
        result = self._run(
            prompt_length=1,
            decode_steps=1,
            capacity=32,
            stop_step=0,
            stop_stage="qk",
            model="llama3-8b",
        )
        self.assertEqual(result.steps[0].captures["qk"].shape, (1, 32, 1, 2))
        self.assertEqual(result.cache_descriptor["geometry"]["num_kv_heads"], 8)
        self.assertEqual(len(result.cache_descriptor["buffers"]["key"]), 8)
        qk_steps = [
            step for step in result.placement["physical_steps"]
            if step.get("op") == "mm_w4a16_gemm_core_out"
            and step.get("operation") == "qk"
        ]
        self.assertTrue(qk_steps)
        self.assertEqual(qk_steps[-1]["launches"], 8)
        self.assertEqual(qk_steps[-1]["M"], 4)
        self.assertEqual(qk_steps[-1]["query_heads_per_matrix"], 4)
        self.assertEqual(result.placement["fallback_count"], 0)

    @unittest.skipUnless(
        os.environ.get("RUN_SPINQUANT_LLAMA3_FULL") == "1",
        "full Llama3 decode test not requested",
    )
    def test_llama3_decode_reaches_final_residual(self):
        result = self._run(
            prompt_length=1,
            decode_steps=1,
            capacity=32,
            stop_step=0,
            stop_stage="final_residual",
            model="llama3-8b",
        )
        self.assertEqual(
            result.steps[0].captures["final_residual"].shape, (1, 1, 4096)
        )
        self.assertEqual(result.placement["fallback_count"], 0)

    def test_persistent_decode_reaches_qk_without_fallback(self):
        result = self._run(
            prompt_length=1,
            decode_steps=1,
            capacity=32,
            stop_step=0,
            stop_stage="qk",
        )
        self.assertEqual(result.prefill.stage_order[-1], "final_residual")
        self.assertEqual(result.steps[0].stage_order[-1], "qk")
        self.assertEqual(result.steps[0].logical_length, 2)
        self.assertEqual(result.steps[0].captures["qk"].shape, (1, 32, 1, 2))
        self.assertEqual(result.placement["fallback_count"], 0)
        descriptor = result.cache_descriptor
        self.assertEqual(descriptor["device"], "vortex")
        self.assertEqual(descriptor["logical_length"], 2)
        self.assertEqual(descriptor["geometry"]["max_sequence_length"], 32)
        self.assertEqual(descriptor["lifecycle"], "valid_prefix")
        self.assertEqual(
            descriptor["quantization"],
            {
                "key": "signed_asymmetric_int4",
                "value": "signed_symmetric_int4",
            },
        )
        self.assertEqual(len(descriptor["buffers"]["key"]), 32)
        self.assertEqual(len(descriptor["buffers"]["value"]), 32)
        self.assertGreater(
            descriptor["per_head_buffer_bytes"]["key"]["weight"], 0
        )
        self.assertEqual(
            descriptor["buffers"]["key"][0]["weight"]["address"],
            descriptor["key_addresses"][0],
        )
        snapshots = [
            result.prefill.cache_descriptor,
            result.steps[0].cache_descriptor,
        ]
        self.assertEqual(
            len({snapshot["allocation_id"] for snapshot in snapshots}), 1
        )
        self.assertEqual(
            snapshots[0]["key_addresses"], snapshots[1]["key_addresses"]
        )
        self.assertEqual(
            snapshots[0]["value_addresses"], snapshots[1]["value_addresses"]
        )
        self.assertEqual(
            self._buffer_addresses(snapshots[0]),
            self._buffer_addresses(snapshots[1]),
        )

    def test_reset_reuses_every_persistent_buffer(self):
        from spinquant_inference.layer_accuracy.artifacts import (
            create_random_decode_case,
        )
        from spinquant_inference.layer_accuracy.backends import VortexBackend
        from spinquant_inference.layer_accuracy.specs import DecodeConfig, LayerConfig

        config = DecodeConfig(
            layer=LayerConfig(batch_size=1, sequence_length=2),
            prompt_length=1,
            decode_steps=1,
            max_sequence_length=32,
        )
        case = create_random_decode_case(config, seed=29)
        backend = VortexBackend(strict_native=True, physical_plan="fused")
        backend.preflight(case, "decode:0:qk")
        backend.bind(case)
        cache = backend.create_persistent_cache(config)
        before = cache.descriptor()

        cache.reset()
        after = cache.descriptor()

        self.assertEqual(after["allocation_id"], before["allocation_id"])
        self.assertEqual(after["cache_generation"], before["cache_generation"] + 1)
        self.assertEqual(after["logical_length"], 0)
        self.assertEqual(after["lifecycle"], "empty")
        self.assertEqual(
            self._buffer_addresses(after), self._buffer_addresses(before)
        )

    @unittest.skipUnless(
        os.environ.get("RUN_SPINQUANT_DECODE_FULL") == "1",
        "tile-crossing full decode test not requested",
    )
    def test_tile_crossing_decode_reaches_final_residual(self):
        result = self._run(
            prompt_length=31,
            decode_steps=2,
            capacity=64,
            stop_step=1,
            stop_stage="final_residual",
        )
        self.assertEqual([step.logical_length for step in result.steps], [32, 33])
        self.assertTrue(
            all(step.stage_order[-1] == "final_residual" for step in result.steps)
        )
        self.assertEqual(
            result.steps[-1].captures["final_residual"].shape,
            (1, 1, 4096),
        )
        self.assertEqual(result.placement["fallback_count"], 0)
        descriptor = result.cache_descriptor
        self.assertEqual(descriptor["logical_length"], 33)
        self.assertEqual(descriptor["geometry"]["max_sequence_length"], 64)
        self.assertEqual(descriptor["cache_generation"], 0)
        snapshots = [
            result.prefill.cache_descriptor,
            *(step.cache_descriptor for step in result.steps),
        ]
        self.assertEqual(
            [snapshot["logical_length"] for snapshot in snapshots], [31, 32, 33]
        )
        self.assertEqual(
            len({tuple(snapshot["key_addresses"]) for snapshot in snapshots}), 1
        )
        self.assertEqual(
            len({tuple(snapshot["value_addresses"]) for snapshot in snapshots}), 1
        )
        self.assertTrue(
            all(
                self._buffer_addresses(snapshot)
                == self._buffer_addresses(snapshots[0])
                for snapshot in snapshots[1:]
            )
        )


if __name__ == "__main__":
    unittest.main()
