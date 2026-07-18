"""Focused native-op tests for the SpinQuant layer accuracy backend.

Run with RUN_VORTEX_TESTS=1 and a configured VORTEX_DRIVER (simx or xrt).
"""

import os
import sys
import unittest
from pathlib import Path

import torch


SPINQUANT_ROOT = Path(__file__).resolve().parents[1] / "spinquant"
sys.path.insert(0, str(SPINQUANT_ROOT))

from spinquant_inference.layer_accuracy.backends import (  # noqa: E402
    _decode_gemm_matrix,
    _decode_packed_gemm_weight,
)
from spinquant_inference.layer_accuracy.tensor_io import (  # noqa: E402
    pack_signed_int4,
    unpack_signed_int4,
)


@unittest.skipUnless(os.environ.get("RUN_VORTEX_TESTS") == "1", "Vortex runtime test not requested")
class SpinQuantVortexOpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["TORCH_VORTEX_STRICT_NATIVE"] = "1"
        import torch_vortex  # noqa: F401

    @staticmethod
    def _encode_gemm_tile(value, m_pad):
        m, n = value.shape
        padded = torch.zeros((m_pad, n), dtype=value.dtype)
        padded[:m] = value
        chunks = []
        for mt_start in range(0, m_pad, 128):
            block = padded[mt_start:mt_start + 128]
            chunks.append(
                block.reshape(block.shape[0], n // 32, 32)
                .permute(1, 0, 2)
                .contiguous()
                .reshape(-1)
            )
        return torch.cat(chunks).reshape(m_pad, n)

    def test_rms_norm_layout_fused_matches_standalone_composition(self):
        source_cpu = torch.randn((8, 128), dtype=torch.float16)
        gamma_cpu = torch.linspace(0.9, 1.1, 128, dtype=torch.float16)
        with torch.vortex.memory_alignment(512):
            source = source_cpu.to("vortex")
            gamma = gamma_cpu.to("vortex")
        fused = torch.ops.vortex.rms_norm_layout_fused(source, gamma, 1e-6, 8)
        fused_row = torch.ops.vortex.detile_output(fused, 8, 8, 128).cpu()
        standalone = torch.ops.vortex.rms_norm(
            source.reshape(1, 8, 128), gamma, 1e-6
        ).reshape(8, 128).cpu()
        torch.testing.assert_close(fused_row, standalone, rtol=2e-3, atol=2e-3)

    def test_rope_layout_fused_produces_contiguous_bhsd(self):
        batch, seq, heads, dim = 1, 8, 2, 32
        projection = torch.randn((seq, heads * dim), dtype=torch.float16)
        tiled_cpu = self._encode_gemm_tile(projection, seq)
        cos = torch.randn((seq, dim // 2), dtype=torch.float16)
        sin = torch.randn((seq, dim // 2), dtype=torch.float16)
        with torch.vortex.memory_alignment(512):
            tiled = tiled_cpu.to("vortex")
            cos_device = cos.to("vortex")
            sin_device = sin.to("vortex")
        fused = torch.ops.vortex.rope_layout_fused(
            tiled, cos_device, sin_device, batch, seq, heads, dim, seq, 3, 0
        ).cpu()
        source_bshd = projection.reshape(batch, seq, heads, dim)
        standalone = torch.ops.vortex.apply_rotary_pos_emb(
            source_bshd.to("vortex"), cos_device, sin_device, 0
        ).cpu().transpose(1, 2).contiguous()
        torch.testing.assert_close(fused, standalone, rtol=2e-3, atol=2e-3)

    def test_fused_softmax_head_concat_and_residual_layout_contracts(self):
        heads, seq, dim = 2, 8, 32
        scores = torch.randn((heads, seq, 32), dtype=torch.float16)
        scores[:, :, seq:] = -20
        tiled_scores_cpu = torch.stack(
            [self._encode_gemm_tile(head, seq) for head in scores]
        )
        with torch.vortex.memory_alignment(512):
            tiled_scores = tiled_scores_cpu.to("vortex")
        probabilities = torch.ops.vortex.softmax_layout_fused(
            tiled_scores, 1, heads, seq, 32, seq, 1, 0.125
        )
        decoded = torch.stack(
            [_decode_gemm_matrix(head.cpu(), m=seq, m_pad=seq, n=32)
             for head in probabilities]
        )
        causal = torch.triu(torch.full((seq, 32), float("-inf")), diagonal=1)
        expected = torch.softmax(scores.float() * 0.125 + causal, dim=-1).half()
        torch.testing.assert_close(decoded, expected, rtol=3e-3, atol=3e-3)

        pv = torch.randn((heads, seq, dim), dtype=torch.float16)
        pv_tiled_cpu = torch.stack([self._encode_gemm_tile(head, seq) for head in pv])
        with torch.vortex.memory_alignment(512):
            pv_tiled = pv_tiled_cpu.to("vortex")
        concatenated = torch.ops.vortex.head_concat_layout_fused(
            pv_tiled, 1, seq, heads, dim, seq, seq
        )
        concat_row = torch.ops.vortex.detile_output(
            concatenated, seq, seq, heads * dim
        ).cpu()
        expected_concat = pv.transpose(0, 1).contiguous().reshape(seq, heads * dim)
        torch.testing.assert_close(concat_row, expected_concat, rtol=0, atol=0)

        residual = torch.randn_like(expected_concat)
        projection = torch.randn_like(expected_concat)
        projection_tiled_cpu = self._encode_gemm_tile(projection, seq)
        with torch.vortex.memory_alignment(512):
            projection_tiled = projection_tiled_cpu.to("vortex")
            residual_device = residual.to("vortex")
        added = torch.ops.vortex.eladd_layout_fused(
            projection_tiled, residual_device, seq, seq, heads * dim
        ).cpu()
        torch.testing.assert_close(added, projection + residual, rtol=0, atol=0)

    def test_signed_asymmetric_fused_kv_quantization_contract(self):
        source_cpu = torch.linspace(-3, 2, 32 * 128, dtype=torch.float16).reshape(32, 128)
        with torch.vortex.memory_alignment(512):
            source = source_cpu.to("vortex")
        weight, _, _, scale, zero = torch.ops.vortex.kv_cache_quant_layout_fused_w4a16(
            source, 32, 128, 128, 1, 0, 1, 0, 1, 1, 128, 0
        )
        tiled_source = torch.ops.vortex.tile_input_a(source, 32, 128)
        tiled_weight, _, _, tiled_scale, tiled_zero = (
            torch.ops.vortex.kv_cache_quant_layout_fused_w4a16(
                tiled_source, 32, 128, 128, 1, 0, 1, 2, 1, 1, 128, 0, 32, 0
            )
        )
        decoded_tiled_source = torch.ops.vortex.detile_output(
            tiled_source, 32, 32, 128
        ).cpu()
        torch.testing.assert_close(decoded_tiled_source, source_cpu, rtol=0, atol=0)
        source_fp32 = source_cpu.float()
        minimum = source_fp32.amin(-1, keepdim=True)
        maximum = source_fp32.amax(-1, keepdim=True)
        expected_scale = (maximum - minimum).clamp_min(1e-8) / 15
        expected_zero = -8 - minimum / expected_scale
        expected_q = torch.round(source_fp32 / expected_scale + expected_zero)
        expected_q = expected_q.clamp(-8, 7).to(torch.int8)
        decoded_packed = _decode_packed_gemm_weight(
            weight.cpu(), k=128, n=32, wtrans=1
        )
        torch.testing.assert_close(
            unpack_signed_int4(decoded_packed).transpose(0, 1),
            expected_q,
            rtol=0,
            atol=0,
        )
        torch.testing.assert_close(scale.cpu(), expected_scale.half(), rtol=0, atol=0)
        torch.testing.assert_close(zero.cpu(), expected_zero.half(), rtol=0, atol=0)
        torch.testing.assert_close(tiled_scale.cpu(), scale.cpu(), rtol=0, atol=0)
        torch.testing.assert_close(tiled_zero.cpu(), zero.cpu(), rtol=0, atol=0)
        torch.testing.assert_close(tiled_weight.cpu(), weight.cpu(), rtol=0, atol=0)

    def test_signed_symmetric_fused_kv_quantization_contract(self):
        source_cpu = torch.linspace(-2, 3, 32 * 128, dtype=torch.float16).reshape(32, 128)
        with torch.vortex.memory_alignment(512):
            source = source_cpu.to("vortex")
        weight, _, _, scale, zero = torch.ops.vortex.kv_cache_quant_layout_fused_w4a16(
            source, 32, 128, 128, 1, 1, 0, 0, 0, 2, 128, 0, 32, 0
        )
        expected_scale = source_cpu.float().abs().amax(-1, keepdim=True) / 7.5
        expected_q = torch.round(source_cpu.float() / expected_scale).clamp(-8, 7).to(torch.int8)
        decoded_packed = _decode_packed_gemm_weight(
            weight.cpu(), k=32, n=128, wtrans=0
        )
        torch.testing.assert_close(
            unpack_signed_int4(decoded_packed), expected_q, rtol=0, atol=0
        )
        torch.testing.assert_close(scale.cpu(), expected_scale.half(), rtol=0, atol=0)
        torch.testing.assert_close(zero.cpu(), torch.zeros_like(zero.cpu()), rtol=0, atol=0)

    def test_fused_kv_quantization_selects_batch_rows_from_gemm_c(self):
        source_cpu = torch.cat(
            (
                torch.full((32, 128), -1.0, dtype=torch.float16),
                torch.linspace(-2, 3, 32 * 128, dtype=torch.float16).reshape(32, 128),
            )
        )
        tiled_cpu = self._encode_gemm_tile(source_cpu, 64)
        with torch.vortex.memory_alignment(512):
            tiled = tiled_cpu.to("vortex")
        weight, _, _, scale, zero = (
            torch.ops.vortex.kv_cache_quant_layout_fused_w4a16(
                tiled, 32, 128, 128, 1, 1, 0, 1, 0, 2, 128, 0, 64, 32
            )
        )
        selected = source_cpu[32:].float()
        expected_scale = selected.abs().amax(-1, keepdim=True) / 7.5
        expected_q = torch.round(selected / expected_scale).clamp(-8, 7).to(torch.int8)
        decoded_packed = _decode_packed_gemm_weight(
            weight.cpu(), k=32, n=128, wtrans=0
        )
        torch.testing.assert_close(
            unpack_signed_int4(decoded_packed), expected_q, rtol=0, atol=0
        )
        torch.testing.assert_close(scale.cpu(), expected_scale.half(), rtol=0, atol=0)
        torch.testing.assert_close(zero.cpu(), torch.zeros_like(zero.cpu()), rtol=0, atol=0)

    def test_grouped_gemm_and_qk_correction_out_preserve_output_storage(self):
        m, k_dim, n_dim = 8, 32, 32
        activation_cpu = torch.randn((m, k_dim), dtype=torch.float16)
        weight_q = ((torch.arange(k_dim * n_dim).reshape(k_dim, n_dim) % 16) - 8).to(torch.int8)
        packed_cpu = pack_signed_int4(weight_q)
        scales_cpu = torch.full((1, n_dim), 0.125, dtype=torch.float16)
        zeros_cpu = torch.zeros((1, n_dim), dtype=torch.int16)
        with torch.vortex.memory_alignment(512):
            activation = activation_cpu.to("vortex")
            packed = packed_cpu.view(torch.uint8).to("vortex")
            scales = scales_cpu.to("vortex")
            zeros = zeros_cpu.to("vortex")
            output_parent = torch.empty((2, m, n_dim), dtype=torch.float16, device="vortex")
        input_tiled = torch.ops.vortex.tile_input_a(activation, m, k_dim)
        weight_tiled = torch.ops.vortex.tile_weight_w4a16(packed, k_dim, n_dim, 0)
        scale_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
            scales, k_dim, n_dim, k_dim, 0
        )
        zero_tiled = torch.ops.vortex.tile_scale_zp_w4a16(
            zeros, k_dim, n_dim, k_dim, 0
        )
        expected_physical = torch.ops.vortex.mm_w4a16_gemm_core(
            input_tiled, weight_tiled, scale_tiled, zero_tiled,
            k_dim, n_dim, k_dim, 0, 0,
        ).cpu()
        returned = torch.ops.vortex.mm_w4a16_gemm_core_out(
            input_tiled, weight_tiled, scale_tiled, zero_tiled,
            k_dim, n_dim, k_dim, 0, 0, output_parent[1],
        )
        self.assertEqual(returned.data_ptr(), output_parent[1].data_ptr())
        torch.testing.assert_close(output_parent[1].cpu(), expected_physical, rtol=0, atol=0)

        scores_cpu = torch.randn((m, n_dim), dtype=torch.float16)
        query_cpu = torch.randn((m, k_dim), dtype=torch.float16)
        scale_cpu = torch.linspace(0.05, 0.2, n_dim, dtype=torch.float16)
        zero_cpu = torch.linspace(-2, 2, n_dim, dtype=torch.float16)
        scores_tiled_cpu = self._encode_gemm_tile(scores_cpu, m)
        with torch.vortex.memory_alignment(512):
            scores_parent = torch.empty((2, m, n_dim), dtype=torch.float16, device="vortex")
            scores_parent[1].copy_(scores_tiled_cpu.to("vortex"))
            query = self._encode_gemm_tile(query_cpu, m).to("vortex")
            scale = scale_cpu.to("vortex")
            zero = zero_cpu.to("vortex")
        returned = torch.ops.vortex.qk_asym_correction_out(
            scores_parent[1], query, scale, zero, m, m, n_dim, 1, 1,
            scores_parent[1]
        )
        self.assertEqual(returned.data_ptr(), scores_parent[1].data_ptr())
        decoded = _decode_gemm_matrix(scores_parent[1].cpu(), m=m, m_pad=m, n=n_dim)
        expected = scores_cpu.float() - (
            query_cpu.float().sum(-1, keepdim=True)
            * scale_cpu.float().unsqueeze(0)
            * zero_cpu.float().unsqueeze(0)
        )
        torch.testing.assert_close(decoded, expected.half(), rtol=3e-3, atol=3e-3)

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

    def test_hadamard_layout_fused_matches_standalone_composition(self):
        cases = (
            (torch.randn((2, 8, 32), dtype=torch.float16), torch.ones((1, 1), dtype=torch.float16), 1),
            (
                torch.arange(2 * 96, dtype=torch.float16).reshape(1, 2, 96) / 64,
                torch.tensor([[1, 1, 1], [1, -1, 1], [1, 1, -1]], dtype=torch.float16),
                3,
            ),
        )
        for source_cpu, matrix_cpu, base_k in cases:
            with self.subTest(base_k=base_k):
                matrix_count, rows, dim = source_cpu.shape
                m_pad = (rows + 7) & ~7
                with torch.vortex.memory_alignment(512):
                    source = source_cpu.to("vortex")
                    matrix = matrix_cpu.to("vortex")
                fused = torch.ops.vortex.hadamard_layout_fused(
                    source, matrix, base_k, matrix_count, rows, m_pad
                ).cpu()
                butterfly = torch.ops.vortex.hadamard_butterfly(
                    source.reshape(matrix_count * rows, dim), base_k
                )
                if base_k > 1:
                    butterfly = torch.ops.vortex.hadamard_base(
                        butterfly, matrix, base_k
                    )
                if matrix_count > 1:
                    expected = torch.stack([
                        self._encode_gemm_tile(
                            butterfly.reshape(matrix_count, rows, dim)[index].cpu(), rows
                        )
                        for index in range(matrix_count)
                    ])
                else:
                    expected = torch.ops.vortex.tile_input_a(
                        butterfly.reshape(rows, dim), m_pad, dim
                    ).cpu()
                    expected = expected.reshape(matrix_count, m_pad, dim)
                decoded_fused = torch.stack([
                    _decode_gemm_matrix(value, m=rows, m_pad=m_pad, n=dim)
                    for value in fused
                ])
                decoded_expected = torch.stack([
                    _decode_gemm_matrix(value, m=rows, m_pad=m_pad, n=dim)
                    for value in expected
                ])
                torch.testing.assert_close(
                    decoded_fused, decoded_expected, rtol=0, atol=0
                )

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
