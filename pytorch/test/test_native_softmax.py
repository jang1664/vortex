"""Tests for native Vortex softmax kernel (aten::_softmax).

The Vortex softmax kernel operates on the last dimension.
For non-last-dim softmax, the implementation falls back to CPU.
"""
import os
import unittest

os.environ.setdefault("VORTEX_HOME", "/root/workspace/vortex")

import torch
import torch.nn.functional as F
import torch_vortex  # noqa: F401 — registers the backend


class TestSoftmaxBasic(unittest.TestCase):
    """Basic softmax correctness on the last dimension."""

    def test_1d(self):
        """softmax over a 1-D tensor (the only dim IS the last dim)."""
        x = torch.randn(8)
        expected = F.softmax(x, dim=-1)

        x_dev = x.to("vortex")
        result = F.softmax(x_dev, dim=-1)
        result_cpu = result.cpu()

        self.assertEqual(result_cpu.shape, expected.shape)
        self.assertTrue(
            torch.allclose(result_cpu, expected, rtol=1e-2, atol=1e-3),
            f"max diff = {(result_cpu - expected).abs().max().item():.8f}",
        )

    def test_2d_last_dim(self):
        """softmax on dim=-1 of a 2-D tensor — native kernel path."""
        x = torch.randn(4, 16)
        expected = F.softmax(x, dim=-1)

        x_dev = x.to("vortex")
        result = F.softmax(x_dev, dim=-1).cpu()

        self.assertTrue(
            torch.allclose(result, expected, rtol=1e-2, atol=1e-3),
            f"max diff = {(result - expected).abs().max().item():.8f}",
        )

    def test_3d_last_dim(self):
        """softmax on dim=-1 of a 3-D tensor [B, S, V]."""
        x = torch.randn(2, 4, 32)
        expected = F.softmax(x, dim=-1)

        result = F.softmax(x.to("vortex"), dim=-1).cpu()

        self.assertTrue(
            torch.allclose(result, expected, rtol=1e-2, atol=1e-3),
            f"max diff = {(result - expected).abs().max().item():.8f}",
        )

    def test_4d_attention_shape(self):
        """Typical attention shape [B, H, Q, K] — softmax on last dim."""
        x = torch.randn(2, 8, 16, 16)
        expected = F.softmax(x, dim=-1)

        result = F.softmax(x.to("vortex"), dim=-1).cpu()

        self.assertTrue(
            torch.allclose(result, expected, rtol=1e-2, atol=1e-3),
            f"max diff = {(result - expected).abs().max().item():.8f}",
        )


class TestSoftmaxProperties(unittest.TestCase):
    """Verify softmax mathematical properties."""

    def test_sums_to_one(self):
        """Each row of softmax output should sum to 1.0."""
        x = torch.randn(4, 32).to("vortex")
        result = F.softmax(x, dim=-1).cpu()

        row_sums = result.sum(dim=-1)
        self.assertTrue(
            torch.allclose(row_sums, torch.ones_like(row_sums), rtol=1e-2, atol=1e-3),
            f"row sums: {row_sums}",
        )

    def test_non_negative(self):
        """All softmax outputs must be >= 0."""
        x = torch.randn(8, 64).to("vortex")
        result = F.softmax(x, dim=-1).cpu()
        self.assertTrue((result >= 0).all())

    def test_known_values(self):
        """Verify with hand-computable values: softmax([0,0,0,0]) = [0.25]*4."""
        x = torch.zeros(4)
        result = F.softmax(x.to("vortex"), dim=-1).cpu()
        expected = torch.full((4,), 0.25)
        self.assertTrue(
            torch.allclose(result, expected, rtol=1e-2, atol=1e-3),
            f"result = {result.tolist()}",
        )

    def test_large_input_stability(self):
        """Numerical stability: softmax([1000, 1000, 1000]) should not NaN."""
        x = torch.tensor([1000.0, 1000.0, 1000.0])
        result = F.softmax(x.to("vortex"), dim=-1).cpu()
        self.assertFalse(torch.isnan(result).any(), f"got NaN: {result}")
        self.assertFalse(torch.isinf(result).any(), f"got Inf: {result}")
        expected = torch.full((3,), 1.0 / 3.0)
        self.assertTrue(torch.allclose(result, expected, rtol=1e-2, atol=1e-3))


class TestSoftmaxNonLastDim(unittest.TestCase):
    """Non-last-dim softmax should fall back to CPU and still give correct results."""

    def test_2d_dim0(self):
        """softmax on dim=0 → CPU fallback."""
        x = torch.randn(4, 8)
        expected = F.softmax(x, dim=0)
        result = F.softmax(x.to("vortex"), dim=0).cpu()
        self.assertTrue(
            torch.allclose(result, expected, rtol=1e-2, atol=1e-3),
            f"max diff = {(result - expected).abs().max().item():.8f}",
        )

    def test_3d_dim1(self):
        """softmax on dim=1 of a 3-D tensor → CPU fallback."""
        x = torch.randn(2, 8, 16)
        expected = F.softmax(x, dim=1)
        result = F.softmax(x.to("vortex"), dim=1).cpu()
        self.assertTrue(
            torch.allclose(result, expected, rtol=1e-2, atol=1e-3),
            f"max diff = {(result - expected).abs().max().item():.8f}",
        )


class TestSoftmaxChained(unittest.TestCase):
    """Softmax chained with other native ops."""

    def test_add_then_softmax(self):
        """add on device → softmax on device, no round-trip to CPU."""
        a = torch.randn(4, 16).to("vortex")
        b = torch.randn(4, 16).to("vortex")
        c = a + b                              # native eladd
        result = F.softmax(c, dim=-1).cpu()    # native softmax

        # Reference
        a_cpu, b_cpu = a.cpu(), b.cpu()
        expected = F.softmax(a_cpu + b_cpu, dim=-1)

        self.assertTrue(
            torch.allclose(result, expected, rtol=1e-2, atol=1e-3),
            f"max diff = {(result - expected).abs().max().item():.8f}",
        )


if __name__ == "__main__":
    unittest.main()
