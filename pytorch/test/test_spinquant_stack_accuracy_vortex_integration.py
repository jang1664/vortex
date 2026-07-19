"""Strict-native full decoder-stack smoke tests on a real C4/U55C."""

import os
import unittest


@unittest.skipUnless(
    os.environ.get("RUN_VORTEX_TESTS") == "1",
    "Vortex runtime test not requested",
)
@unittest.skipUnless(
    os.environ.get("RUN_SPINQUANT_STACK_FULL") == "1",
    "full decoder-stack test not requested",
)
class SpinQuantStackVortexIntegrationTests(unittest.TestCase):
    def test_llama2_stack_runs_full_fused_layers(self):
        from spinquant_inference.layer_accuracy.artifacts import (
            create_random_stack_case,
        )
        from spinquant_inference.layer_accuracy.backends import VortexBackend
        from spinquant_inference.layer_accuracy.graph import StackExecutor
        from spinquant_inference.layer_accuracy.specs import StackConfig

        layer_count = int(os.environ.get("SPINQUANT_STACK_LAYERS", "2"))
        case = create_random_stack_case(
            StackConfig.for_model(
                "llama2-7b",
                layer_count=layer_count,
                batch_size=1,
                sequence_length=32,
            ),
            seed=79,
            random_weight_mode="shared",
        )
        result = StackExecutor(
            VortexBackend(strict_native=True, physical_plan="fused")
        ).run(case)

        self.assertEqual(
            [layer.layer_index for layer in result.layers],
            list(range(layer_count)),
        )
        self.assertEqual(len(result.captures), layer_count)
        self.assertEqual(
            result.captures[f"layer{layer_count - 1}.final_residual"].shape,
            (1, 32, 4096),
        )
        self.assertTrue(result.placement["strict_native"])
        self.assertEqual(result.placement["fallback_count"], 0)
        self.assertTrue(
            all(
                layer["strict_native"] and layer["fallback_count"] == 0
                for layer in result.placement["layers"]
            )
        )


if __name__ == "__main__":
    unittest.main()
