"""Strict-native SpinQuant graph integration test through QK attention."""

import os
import unittest


@unittest.skipUnless(os.environ.get("RUN_VORTEX_TESTS") == "1", "Vortex runtime test not requested")
class SpinQuantVortexIntegrationTests(unittest.TestCase):
    def test_layer_executor_runs_native_layout_path_through_qk(self):
        from spinquant_inference.layer_accuracy.artifacts import create_random_case
        from spinquant_inference.layer_accuracy.backends import VortexBackend
        from spinquant_inference.layer_accuracy.graph import LayerExecutor
        from spinquant_inference.layer_accuracy.specs import LayerConfig

        config = LayerConfig(
            model="integration-test",
            hidden_size=64,
            intermediate_size=64,
            num_attention_heads=2,
            head_dim=32,
            batch_size=1,
            sequence_length=32,
            weight_group_size=32,
            kv_group_size=32,
        )
        case = create_random_case(config, seed=1)
        result = LayerExecutor(VortexBackend(strict_native=True)).run(case, stop_after="qk")
        self.assertEqual(result.stage_order[-1], "qk")
        self.assertEqual(result.captures["qk"].shape, (1, 2, 32, 32))
        self.assertEqual(result.placement["fallback_count"], 0)
        self.assertGreater(result.placement["kernel_launches"]["attention_w4a16"], 0)


if __name__ == "__main__":
    unittest.main()
