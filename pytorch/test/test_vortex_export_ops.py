"""Tests for the logical Vortex custom operators used by torch.export."""

import torch

from spinquant.spinquant_inference import vortex_export_ops  # noqa: F401


def test_quantize_dequantize_uses_coupled_uint8_fp16_int16_value():
    source = torch.tensor(
        [[-3.0, -1.0, 0.0, 2.0, 4.0], [1.0, 1.5, -2.0, 3.0, 0.5]],
        dtype=torch.float16,
    )
    packed, scale, zero = torch.ops.vortex.quantize_int4(
        source, 1, 3, 1, "signed_asymmetric_int4"
    )
    restored = torch.ops.vortex.dequantize_int4(
        packed,
        scale,
        zero,
        list(source.shape),
        1,
        3,
        1,
        "signed_asymmetric_int4",
    )

    assert packed.dtype == torch.uint8
    assert packed.shape == (2, 3)
    assert scale.dtype == torch.float16
    assert zero.dtype == torch.int16
    assert scale.shape == zero.shape == (2, 2)
    torch.testing.assert_close(restored, source, atol=0.35, rtol=0)


def test_symmetric_quantization_returns_explicit_int16_zeros_and_zero_tail():
    source = torch.tensor([[7.0, -8.0, 1.0]], dtype=torch.float16)
    packed, scale, zero = torch.ops.vortex.quantize_int4(
        source, -1, 3, -1, "signed_symmetric_int4"
    )

    assert zero.dtype == torch.int16
    assert torch.count_nonzero(zero) == 0
    assert int(packed[0, -1]) >> 4 == 0


def test_mm_w4a16_models_qk_transpose_without_materialized_k_copy():
    query = torch.tensor([[1.0, 2.0, -1.0, 0.5]], dtype=torch.float16)
    key = torch.tensor(
        [[1.0, 0.0, 2.0, -1.0], [-2.0, 1.0, 0.5, 3.0]], dtype=torch.float16
    )
    packed, scale, zero = torch.ops.vortex.quantize_int4(
        key, 1, 4, 1, "signed_asymmetric_int4"
    )
    dequantized = torch.ops.vortex.dequantize_int4(
        packed, scale, zero, list(key.shape), 1, 4, 1, "signed_asymmetric_int4"
    )
    scores = torch.ops.vortex.mm_w4a16(
        query,
        packed,
        scale,
        zero,
        list(key.shape),
        4,
        1,
        1,
        "signed_asymmetric_int4",
        True,
    )

    torch.testing.assert_close(scores, query @ dequantized.T)
    assert key.data_ptr() == key.data_ptr()


def test_causal_softmax_respects_each_batch_query_position_and_valid_length():
    scores = torch.arange(2 * 2 * 2 * 3 * 5, dtype=torch.float16).reshape(
        2, 2, 2, 3, 5
    )
    positions = torch.tensor([[0, 2, 4], [1, 3, 4]], dtype=torch.int64)
    valid_length = torch.tensor(4, dtype=torch.int64)

    masked, probabilities = torch.ops.vortex.causal_softmax(
        scores, positions, valid_length, 4
    )

    keys = torch.arange(5).reshape(1, 1, 1, 1, 5)
    valid = (keys < valid_length) & (
        keys <= positions.reshape(2, 1, 1, 3, 1)
    )
    expected_masked = torch.where(
        valid,
        scores.float() / 2.0,
        torch.full_like(scores.float(), float("-inf")),
    )
    torch.testing.assert_close(masked, expected_masked, rtol=0, atol=0)
    torch.testing.assert_close(
        probabilities,
        torch.softmax(expected_masked, dim=-1).half(),
        rtol=0,
        atol=0,
    )
    assert torch.all(probabilities.masked_select(~valid) == 0)


class _ExportedAttention(torch.nn.Module):
    def forward(self, query, key):
        packed, scale, zero = torch.ops.vortex.quantize_int4(
            key, 1, 4, 1, "signed_asymmetric_int4"
        )
        return torch.ops.vortex.mm_w4a16(
            query,
            packed,
            scale,
            zero,
            [2, 4],
            4,
            1,
            1,
            "signed_asymmetric_int4",
            True,
        )


def test_torch_export_preserves_logical_names_and_transpose_attribute():
    query = torch.ones((1, 4), dtype=torch.float16)
    key = torch.ones((2, 4), dtype=torch.float16)
    exported = torch.export.export(_ExportedAttention(), (query, key))
    targets = [
        node.target for node in exported.graph.nodes if node.op == "call_function"
    ]

    assert targets.count(torch.ops.vortex.quantize_int4.default) == 1
    assert targets.count(torch.ops.vortex.mm_w4a16.default) == 1
    assert all(
        "naive" not in str(target) and "improve" not in str(target)
        for target in targets
    )
    mm_node = next(
        node
        for node in exported.graph.nodes
        if node.target == torch.ops.vortex.mm_w4a16.default
    )
    assert mm_node.args[-1] is True


def test_kv_cache_update_is_functional_and_preserves_other_positions():
    cache_payload = torch.zeros((1, 4, 2), dtype=torch.uint8)
    cache_scale = torch.zeros((1, 4, 1), dtype=torch.float16)
    cache_zero = torch.zeros((1, 4, 1), dtype=torch.int16)
    update_payload = torch.tensor([[[3, 4]]], dtype=torch.uint8)
    update_scale = torch.tensor([[[0.5]]], dtype=torch.float16)
    update_zero = torch.tensor([[[2]]], dtype=torch.int16)

    updated = torch.ops.vortex.kv_cache_update(
        cache_payload,
        cache_scale,
        cache_zero,
        update_payload,
        update_scale,
        update_zero,
        2,
        4,
    )

    assert torch.count_nonzero(cache_payload) == 0
    assert updated[0][0, 2].tolist() == [3, 4]
    assert updated[1][0, 2, 0] == 0.5
    assert updated[2][0, 2, 0] == 2
