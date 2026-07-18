"""Focused native-op tests for the SpinQuant layer accuracy backend.

Run with RUN_VORTEX_TESTS=1 and a configured VORTEX_DRIVER (simx or xrt).
"""

import os
import unittest

import torch


@unittest.skipUnless(os.environ.get("RUN_VORTEX_TESTS") == "1", "Vortex runtime test not requested")
class SpinQuantVortexOpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["TORCH_VORTEX_STRICT_NATIVE"] = "1"
        import torch_vortex  # noqa: F401

    def test_fp16_add_and_mul_stay_native(self):
        lhs_cpu = torch.linspace(-1, 1, 32, dtype=torch.float16).reshape(4, 8)
        rhs_cpu = torch.linspace(1, 2, 32, dtype=torch.float16).reshape(4, 8)
        lhs = lhs_cpu.to("vortex")
        rhs = rhs_cpu.to("vortex")
        torch.testing.assert_close((lhs + rhs).cpu(), lhs_cpu + rhs_cpu, rtol=0, atol=0)
        torch.testing.assert_close((lhs * rhs).cpu(), lhs_cpu * rhs_cpu, rtol=0, atol=0)

    def test_quantize_pack_matches_signed_low_nibble_contract(self):
        source = torch.tensor(
            [[-1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5]], dtype=torch.float16
        ).to("vortex")
        packed, scale, zero = torch.ops.vortex.quantize_pack_per_token(source, 1)
        self.assertEqual(packed.cpu().view(torch.uint8).tolist(), [[0xA8, 0xEC, 0x31, 0x75]])
        torch.testing.assert_close(
            scale.cpu(), torch.tensor([[3.5 / 15]], dtype=torch.float16), rtol=0, atol=0
        )
        torch.testing.assert_close(
            zero.cpu(), torch.tensor([[-8 + 1 / (3.5 / 15)]], dtype=torch.float16), rtol=0, atol=0
        )

    def test_qk_asymmetric_zero_correction(self):
        scores_cpu = torch.arange(12, dtype=torch.float16).reshape(3, 4) / 8
        query_cpu = torch.arange(24, dtype=torch.float16).reshape(3, 8) / 16 - 0.5
        scale_cpu = torch.tensor([0.1, 0.2, 0.3, 0.4], dtype=torch.float16)
        zero_cpu = torch.tensor([-2.5, -1.0, 0.5, 2.0], dtype=torch.float16)
        output = torch.ops.vortex.qk_asym_correction(
            scores_cpu.to("vortex"),
            query_cpu.to("vortex"),
            scale_cpu.to("vortex"),
            zero_cpu.to("vortex"),
        ).cpu()
        expected = scores_cpu.float() - (
            query_cpu.float().sum(-1, keepdim=True)
            * scale_cpu.float().unsqueeze(0)
            * zero_cpu.float().unsqueeze(0)
        )
        torch.testing.assert_close(output, expected.half(), rtol=2e-3, atol=2e-3)

    def test_head_concat_has_bshd_semantics(self):
        source_cpu = torch.arange(2 * 3 * 4 * 8, dtype=torch.float16).reshape(2, 3, 4, 8)
        output = torch.ops.vortex.head_concat(source_cpu.to("vortex")).cpu()
        expected = source_cpu.transpose(1, 2).contiguous().reshape(2, 4, 24)
        torch.testing.assert_close(output, expected, rtol=0, atol=0)

    def test_hadamard_base_matrix_stays_native(self):
        source_cpu = torch.arange(48, dtype=torch.float16).reshape(2, 24) / 16
        matrix_cpu = torch.tensor(
            [[1, 1, 1], [1, -1, 1], [1, 1, -1]], dtype=torch.float16
        )
        output = torch.ops.vortex.hadamard_base(
            source_cpu.to("vortex"), matrix_cpu.to("vortex"), 3
        ).cpu()
        expected = (
            matrix_cpu.float().unsqueeze(0)
            @ source_cpu.float().reshape(2, 3, 8)
        ).reshape(2, 24).half()
        torch.testing.assert_close(output, expected, rtol=1e-3, atol=1e-3)

    def test_contiguous_offset_view_uses_parent_device_buffer(self):
        source_cpu = torch.arange(2 * 8 * 32, dtype=torch.float16).reshape(2, 8, 32)
        source = source_cpu.to("vortex")
        second_slice = source[1]
        self.assertTrue(second_slice.is_contiguous())
        output = torch.ops.vortex.tile_input_a(second_slice, 8, 32).cpu()
        expected = (
            source_cpu[1]
            .view(8, 1, 32)
            .permute(1, 0, 2)
            .contiguous()
            .view(8, 32)
        )
        torch.testing.assert_close(output, expected, rtol=0, atol=0)

    def test_strict_native_rejects_unregistered_aten_fallback(self):
        source = torch.ones((2, 8), dtype=torch.float16).to("vortex")
        with self.assertRaisesRegex(RuntimeError, "strict-native.*CPU fallback"):
            torch.sum(source)

if __name__ == "__main__":
    unittest.main()
