from __future__ import annotations

import unittest
import argparse
import csv
import io
import random
import tempfile
from contextlib import redirect_stdout
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from .interpolation import (
    bracketed_intervals,
    interpolation_group_key,
    kernel_type,
    refine_command,
    sample_candidates,
    select_midpoint_candidates,
)
from .raw_db import RAW_DB_COLUMNS
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


class MidpointSamplingTest(unittest.TestCase):
    def make_curve(
        self,
        lengths: list[int],
        *,
        hidden_size: int = 4096,
        duplicate_args: dict[int, str] | None = None,
    ) -> list[BenchCase]:
        duplicate_args = duplicate_args or {}
        cases = [
            _case(
                f"h{hidden_size}_{length}",
                app="softmax",
                backend="softmax",
                variant="v",
                name="softmax",
                logical_cache_length=length,
                hidden_size=hidden_size,
            )
            for length in lengths
        ]
        return [
            replace(case, args=duplicate_args.get(length, case.args))
            for case, length in zip(cases, lengths)
        ]

    def intervals_for(
        self,
        cases: list[BenchCase],
        anchor_lengths: set[int],
    ) -> tuple[list, list, dict[str, float]]:
        suite = BenchSuite("test", BenchDefaults(), cases)
        raw_values = {
            case.exec_key: float(case.shape["logical_cache_length"])
            for case in cases
            if int(case.shape["logical_cache_length"]) in anchor_lengths
        }
        intervals, unbracketed = bracketed_intervals(
            suite,
            raw_values,
            physical_kernel="softmax|softmax",
        )
        return intervals, unbracketed, raw_values

    def test_selects_case_nearest_interval_midpoint(self) -> None:
        cases = self.make_curve([0, 4, 6, 10])
        intervals, _, _ = self.intervals_for(cases, {0, 10})

        selected = select_midpoint_candidates(intervals, 1)

        self.assertEqual([4], [item.case.shape["logical_cache_length"] for item in selected])

    def test_spreads_first_samples_across_high_priority_intervals(self) -> None:
        cases = (
            self.make_curve([0, 10, 20, 30, 40, 50, 100], hidden_size=4096)
            + self.make_curve([0, 50, 100, 150, 200], hidden_size=8192)
        )
        intervals, _, _ = self.intervals_for(cases, {0, 100, 200})

        selected = select_midpoint_candidates(intervals, 2)

        self.assertEqual(2, len({item.interval.stable_group_id for item in selected}))
        self.assertEqual(5, selected[0].interval.unique_exec_keys)

    def test_virtual_bisection_fills_quarter_points(self) -> None:
        cases = self.make_curve([0, 25, 50, 75, 100])
        intervals, _, _ = self.intervals_for(cases, {0, 100})

        selected = select_midpoint_candidates(intervals, 3)

        self.assertEqual(
            [50, 25, 75],
            [item.case.shape["logical_cache_length"] for item in selected],
        )
        self.assertEqual(
            ["distinct_interval_midpoint", "virtual_bisection_midpoint", "virtual_bisection_midpoint"],
            [item.reason for item in selected],
        )

    def test_excludes_and_counts_extrapolation_candidates(self) -> None:
        cases = self.make_curve([-5, 0, 5, 10, 15])
        intervals, unbracketed, _ = self.intervals_for(cases, {0, 10})

        self.assertEqual([5], [case.shape["logical_cache_length"] for case in intervals[0].candidates])
        self.assertEqual([-5, 15], [case.shape["logical_cache_length"] for case in unbracketed])

    def test_deduplicates_exec_key_using_nearest_representative(self) -> None:
        cases = self.make_curve(
            [0, 4, 6, 10],
            duplicate_args={4: "same", 6: "same"},
        )
        intervals, _, _ = self.intervals_for(cases, {0, 10})

        selected = select_midpoint_candidates(intervals, 2)

        self.assertEqual(1, len(selected))
        self.assertEqual(4, selected[0].case.shape["logical_cache_length"])

    def test_promoted_midpoint_becomes_anchor_on_next_iteration(self) -> None:
        cases = self.make_curve([0, 25, 50, 75, 100])
        intervals, _, raw_values = self.intervals_for(cases, {0, 100})
        first = select_midpoint_candidates(intervals, 1)[0]
        raw_values[first.case.exec_key] = 50.0
        suite = BenchSuite("test", BenchDefaults(), cases)

        split_intervals, _ = bracketed_intervals(
            suite, raw_values, physical_kernel="softmax|softmax"
        )
        second = select_midpoint_candidates(split_intervals, 1)

        self.assertEqual([(0, 50), (50, 100)], [
            (item.lower_anchor, item.upper_anchor) for item in split_intervals
        ])
        self.assertEqual(25, second[0].case.shape["logical_cache_length"])


class RefineCommandTest(unittest.TestCase):
    def write_raw(
        self,
        path: Path,
        values: list[tuple[BenchCase, float]],
    ) -> None:
        with path.open("w", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
            writer.writeheader()
            for case, value in values:
                row = {column: "" for column in RAW_DB_COLUMNS}
                row.update({
                    "status": "pass",
                    "app": case.app,
                    "args": case.args,
                    "xclbin_sha256": case.xclbin_sha256,
                    "p50_us": value,
                })
                writer.writerow(row)

    def run_refine(
        self,
        probe_has_sample: bool,
        *,
        lengths: tuple[int, ...] = (0, 5, 10),
        strategy: str = "midpoint",
        validation_samples: int = 1,
        max_iterations: int = 2,
        seed: int = 0,
    ) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
        cases = [
            _case(
                f"case_{length}",
                app="softmax",
                backend="softmax",
                variant="v",
                name="softmax",
                logical_cache_length=length,
            )
            for length in lengths
        ]
        suite = BenchSuite("test", BenchDefaults(), cases)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main_raw = root / "raw_db.csv"
            probe_raw = root / "probe.csv"
            self.write_raw(main_raw, [(cases[0], 100.0), (cases[-1], 200.0)])
            self.write_raw(
                probe_raw,
                [
                    (
                        case,
                        100.0 + 100.0 * int(case.shape["logical_cache_length"])
                        / lengths[-1],
                    )
                    for case in cases[1:-1]
                ] if probe_has_sample else [],
            )
            args = argparse.Namespace(
                suite=str(root / "suite.yaml"),
                output_root=None,
                raw_db=str(main_raw),
                probe_raw_db=str(probe_raw),
                measure_command=None,
                out=str(root / "refine"),
                refinement_id=None,
                target_error=0.01,
                samples_per_iteration=2,
                validation_samples=validation_samples,
                max_iterations=max_iterations,
                sampling_strategy=strategy,
                seed=seed,
                metric="p50_us",
            )
            with patch(
                "tools.latency_bench.interpolation._load_suite_for_raw",
                return_value=suite,
            ), redirect_stdout(io.StringIO()):
                self.assertEqual(0, refine_command(args))
            with (root / "refine" / "iterations.csv").open(newline="") as fp:
                history = list(csv.DictReader(fp))
            with (root / "refine" / "selections.csv").open(newline="") as fp:
                selections = list(csv.DictReader(fp))
            return history, selections

    def test_converges_after_one_complete_low_error_batch(self) -> None:
        history, _ = self.run_refine(probe_has_sample=True)

        self.assertEqual(1, len(history))
        self.assertEqual("converged", history[0]["status"])
        self.assertEqual("midpoint", history[0]["sampling_strategy"])

    def test_empty_measurement_errors_do_not_converge(self) -> None:
        history, _ = self.run_refine(probe_has_sample=False)

        self.assertEqual(2, len(history))
        self.assertNotIn("converged", {item["status"] for item in history})

    def test_random_strategy_preserves_seeded_shuffle_order(self) -> None:
        lengths = (0, 2, 4, 6, 8, 10)
        seed = 7
        expected = [f"case_{length}" for length in lengths[1:-1]]
        random.Random(seed).shuffle(expected)

        history, selections = self.run_refine(
            probe_has_sample=True,
            lengths=lengths,
            strategy="random",
            validation_samples=len(expected),
            max_iterations=1,
            seed=seed,
        )

        self.assertEqual(expected, [item["case_id"] for item in selections])
        self.assertEqual("random", history[0]["sampling_strategy"])


if __name__ == "__main__":
    unittest.main()
