"""CPU-only checks for the narrowly scoped IP reference policy."""
import unittest

import torch

from dual_reference import xilinx_half_mul


class HalfMultiplierPolicyTest(unittest.TestCase):
    def test_normal_product(self):
        a = torch.tensor([1.5, -2.0, 2**-7], dtype=torch.float16)
        b = torch.tensor([2.0, 3.0, 2**-7], dtype=torch.float16)
        torch.testing.assert_close(xilinx_half_mul(a, b), a * b, rtol=0, atol=0)

    def test_normal_inputs_can_produce_flushed_result(self):
        a = torch.tensor([2**-10], dtype=torch.float16)
        b = torch.tensor([2**-5], dtype=torch.float16)
        self.assertEqual((a * b).item(), 2**-15)
        self.assertEqual(xilinx_half_mul(a, b).item(), 0)

    def test_input_flush_before_multiplication(self):
        a = torch.tensor([2**-15], dtype=torch.float16)
        b = torch.tensor([8.0], dtype=torch.float16)
        self.assertEqual((a * b).item(), 2**-12)
        self.assertEqual(xilinx_half_mul(a, b).item(), 0)

    def test_boundary_does_not_round_to_ieee_subnormal_first(self):
        a = torch.tensor([2**-7], dtype=torch.float16)
        b = torch.nextafter(a, torch.zeros_like(a))
        # IEEE subnormal rounding reaches the smallest normal, whereas the IP
        # rounds at normal precision and then flushes this underflow.
        self.assertEqual((a * b).item(), 2**-14)
        self.assertEqual(xilinx_half_mul(a, b).item(), 0)


if __name__ == '__main__':
    unittest.main()
