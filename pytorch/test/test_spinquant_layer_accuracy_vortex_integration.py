"""Strict-native SpinQuant graph integration tests on real Vortex hardware."""

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
            batch_size=2,
            sequence_length=32,
            weight_group_size=32,
            kv_group_size=32,
        )
        case = create_random_case(config, seed=1)
        result = LayerExecutor(VortexBackend(strict_native=True)).run(case, stop_after="qk")
        self.assertEqual(result.stage_order[-1], "qk")
        self.assertEqual(result.captures["qk"].shape, (2, 2, 32, 32))
        self.assertEqual(result.placement["fallback_count"], 0)
        self.assertGreater(result.placement["kernel_launches"]["attention_w4a16"], 0)

    @unittest.skipUnless(
        os.environ.get("RUN_SPINQUANT_FUSED_FULL") == "1",
        "full Llama2-7B fused integration test not requested",
    )
    def test_fused_plan_runs_full_decoder_layer(self):
        from spinquant_inference.layer_accuracy.artifacts import create_random_case
        from spinquant_inference.layer_accuracy.backends import VortexBackend
        from spinquant_inference.layer_accuracy.graph import LayerExecutor
        from spinquant_inference.layer_accuracy.specs import LayerConfig

        case = create_random_case(
            LayerConfig(batch_size=1, sequence_length=160), seed=3
        )
        result = LayerExecutor(
            VortexBackend(strict_native=True, physical_plan="fused")
        ).run(case, stop_after="final_residual")
        self.assertEqual(len(result.stage_order), 25)
        self.assertEqual(result.stage_order[-1], "final_residual")
        self.assertEqual(result.captures["final_residual"].shape, (1, 160, 4096))
        self.assertEqual(result.placement["physical_plan"], "fused")
        self.assertEqual(result.placement["fallback_count"], 0)
        launches = result.placement["kernel_launches"]
        self.assertEqual(launches["qk_asym_correction_out"], 32)
        self.assertEqual(launches["softmax_layout_fused"], 1)
        self.assertEqual(launches["head_concat_layout_fused"], 1)
        self.assertEqual(launches["eladd_layout_fused"], 2)
        self.assertEqual(launches["hadamard_layout_fused"], 3)
        self.assertNotIn("hadamard_butterfly", launches)
        self.assertNotIn("hadamard_base", launches)
        self.assertNotIn("tile_input_a", launches)


if __name__ == "__main__":
    unittest.main()
