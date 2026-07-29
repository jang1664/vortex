from __future__ import annotations

import unittest

from .interpolation import (
    interpolation_group_key,
    kernel_type,
    sample_candidates,
)
from .suite import BenchCase, BenchDefaults, BenchSuite


def _case(
    case_id: str,
    *,
    app: str,
    backend: str,
    variant: str,
    name: str,
    logical_cache_length: int,
    hidden_size: int = 4096,
) -> BenchCase:
    return BenchCase(
        case_id=case_id,
        app=app,
        args=f"-seqk {logical_cache_length}",
        backend=backend,
        variant=variant,
        name=name,
        stage="generation",
        measurement_kind="interpolated",
        shape={
            "logical_cache_length": logical_cache_length,
            "hidden_size": hidden_size,
        },
    )


class InterpolationGroupingTest(unittest.TestCase):
    def test_physical_kernel_type_ignores_variant_and_logical_name(self) -> None:
        k_case = _case(
            "k",
            app="kv_cache_dequant_w4a16",
            backend="kv_cache_dequant_w4a16",
            variant="all_sgemm_tcu_spinquant",
            name="kv_cache_dequant_k_to_attn_qkT",
            logical_cache_length=101,
        )
        v_case = _case(
            "v",
            app="kv_cache_dequant_w4a16",
            backend="kv_cache_dequant_w4a16",
            variant="attn_sgemm_tcu_fpint_gemm_naive_spinquant",
            name="kv_cache_dequant_v_to_attn_pv",
            logical_cache_length=102,
        )

        self.assertEqual(kernel_type(k_case), kernel_type(v_case))
        self.assertEqual(
            "kv_cache_dequant_w4a16|kv_cache_dequant_w4a16",
            kernel_type(k_case),
        )
        self.assertEqual(
            interpolation_group_key(k_case),
            interpolation_group_key(v_case),
        )

    def test_stable_shape_still_separates_interpolation_curves(self) -> None:
        base = _case(
            "base",
            app="softmax",
            backend="softmax",
            variant="variant_a",
            name="attn_softmax",
            logical_cache_length=101,
        )
        different_shape = _case(
            "different",
            app="softmax",
            backend="softmax",
            variant="variant_b",
            name="attn_softmax_other",
            logical_cache_length=102,
            hidden_size=8192,
        )

        self.assertEqual(kernel_type(base), kernel_type(different_shape))
        self.assertNotEqual(
            interpolation_group_key(base),
            interpolation_group_key(different_shape),
        )

    def test_sampling_uses_one_group_per_physical_kernel(self) -> None:
        cases = [
            _case(
                "dequant_k",
                app="kv_cache_dequant_w4a16",
                backend="kv_cache_dequant_w4a16",
                variant="variant_a",
                name="k",
                logical_cache_length=101,
            ),
            _case(
                "dequant_v",
                app="kv_cache_dequant_w4a16",
                backend="kv_cache_dequant_w4a16",
                variant="variant_b",
                name="v",
                logical_cache_length=102,
            ),
            _case(
                "softmax_a",
                app="softmax",
                backend="softmax",
                variant="variant_a",
                name="attn_softmax",
                logical_cache_length=101,
            ),
            _case(
                "softmax_b",
                app="softmax",
                backend="softmax",
                variant="variant_b",
                name="attn_softmax",
                logical_cache_length=102,
            ),
            _case(
                "fused",
                app="softmax_layout_fused",
                backend="softmax_layout_fused",
                variant="variant_c",
                name="attn_softmax",
                logical_cache_length=101,
            ),
        ]
        suite = BenchSuite("test", BenchDefaults(), cases)

        selected = sample_candidates(suite, samples_per_kernel=1, seed=0)

        self.assertEqual(3, len(selected))
        self.assertEqual(3, len({kernel_type(case) for case in selected}))


if __name__ == "__main__":
    unittest.main()
