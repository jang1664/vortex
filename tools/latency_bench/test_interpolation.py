from __future__ import annotations

import unittest
import argparse
import csv
import io
import json
import random
import tempfile
from contextlib import redirect_stdout
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from . import interpolation as interpolation_module
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

    def test_decode_maxseq_does_not_split_interpolation_curve(self) -> None:
        first = _case(
            "first",
            app="rope",
            backend="rope",
            variant="variant_a",
            name="rope_q",
            logical_cache_length=4097,
        )
        second = replace(
            first,
            case_id="second",
            args="-seqk 4098",
            output_token_index=2,
            shape={
                **first.shape,
                "logical_cache_length": 4098,
                "maxseq": 4098,
            },
        )
        first = replace(first, shape={**first.shape, "maxseq": 4097})

        self.assertEqual(
            interpolation_group_key(first),
            interpolation_group_key(second),
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
                    "run_id": "fixture-source",
                    "status": "pass",
                    "app": case.app,
                    "args": case.args,
                    "xclbin_sha256": case.xclbin_sha256,
                    "exec_key": case.exec_key,
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
        kernel_types: list[str] | None = None,
        include_extra_kernel: bool = False,
        expected_return: int = 0,
    ) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
        softmax_cases = [
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
        extra_cases = [
            _case(
                f"kv_case_{length}",
                app="kv_cache",
                backend="kv_cache",
                variant="v",
                name="kv_cache",
                logical_cache_length=length,
            )
            for length in lengths
        ] if include_extra_kernel else []
        cases = softmax_cases + extra_cases
        suite = BenchSuite("test", BenchDefaults(), cases)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main_raw = root / "raw_db.csv"
            probe_raw = root / "probe.csv"
            anchor_cases = [softmax_cases[0], softmax_cases[-1]]
            if extra_cases:
                anchor_cases.extend((extra_cases[0], extra_cases[-1]))
            self.write_raw(
                main_raw,
                [(case, 100.0 if index % 2 == 0 else 200.0)
                 for index, case in enumerate(anchor_cases)],
            )
            self.write_raw(
                probe_raw,
                [
                    (
                        case,
                        100.0 + 100.0 * int(case.shape["logical_cache_length"])
                        / lengths[-1],
                    )
                    for group in (softmax_cases, extra_cases)
                    for case in group[1:-1]
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
                kernel_types=kernel_types or [],
                sampling_strategy=strategy,
                seed=seed,
                metric="p50_us",
            )
            with patch(
                "tools.latency_bench.interpolation._load_suite_for_raw",
                return_value=suite,
            ), redirect_stdout(io.StringIO()):
                self.assertEqual(expected_return, refine_command(args))
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
        history, _ = self.run_refine(
            probe_has_sample=False,
            expected_return=1,
        )

        self.assertEqual(0, len(history))
        self.assertNotIn("converged", {item["status"] for item in history})

    def test_kernel_type_filter_selects_requested_type(self) -> None:
        history, _ = self.run_refine(
            probe_has_sample=True,
            kernel_types=["softmax|softmax"],
            include_extra_kernel=True,
        )

        self.assertEqual(
            {"softmax|softmax"},
            {item["kernel_type"] for item in history},
        )

    def test_kernel_type_filter_accepts_comma_separated_types(self) -> None:
        history, _ = self.run_refine(
            probe_has_sample=True,
            kernel_types=["softmax|softmax, kv_cache|kv_cache"],
            include_extra_kernel=True,
        )

        self.assertEqual(
            {"softmax|softmax", "kv_cache|kv_cache"},
            {item["kernel_type"] for item in history},
        )

    def test_kernel_type_filter_rejects_unknown_type(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown --kernel-type"):
            self.run_refine(
                probe_has_sample=True,
                kernel_types=["missing|missing"],
            )

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

    def test_interruption_after_selection_writes_recovery_checkpoint(self) -> None:
        class AbruptLoss(BaseException):
            pass

        cases = [
            _case(
                f"case_{length}",
                app="softmax",
                backend="softmax",
                variant="v",
                name="softmax",
                logical_cache_length=length,
            )
            for length in (0, 5, 10)
        ]
        suite = BenchSuite("test", BenchDefaults(), cases)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main_raw = root / "raw_db.csv"
            probe_raw = root / "probe.csv"
            self.write_raw(main_raw, [(cases[0], 100.0), (cases[-1], 200.0)])
            self.write_raw(probe_raw, [])
            args = argparse.Namespace(
                suite=str(root / "suite.yaml"),
                output_root=None,
                raw_db=str(main_raw),
                probe_raw_db=None,
                measure_command="measure {suite} {out}",
                out=str(root / "refine"),
                refinement_id=None,
                target_error=0.01,
                samples_per_iteration=2,
                validation_samples=1,
                max_iterations=2,
                kernel_types=[],
                sampling_strategy="midpoint",
                seed=0,
                metric="p50_us",
                require_convergence=False,
            )
            with patch(
                "tools.latency_bench.interpolation._load_suite_for_raw",
                return_value=suite,
            ), patch(
                "tools.latency_bench.interpolation.run_measurement_command",
                side_effect=AbruptLoss,
            ), redirect_stdout(io.StringIO()), self.assertRaises(AbruptLoss):
                refine_command(args)

            checkpoint_path = root / "refine" / "recovery.json"
            self.assertTrue(checkpoint_path.exists())
            checkpoint = json.loads(checkpoint_path.read_text())
            self.assertEqual(1, checkpoint["schema_version"])
            self.assertEqual("selected", checkpoint["active_iteration"]["phase"])
            self.assertEqual([cases[1].exec_key], checkpoint["active_iteration"]["selected_exec_keys"])


class DurableRefinementRecoveryTest(unittest.TestCase):
    class AbruptLoss(BaseException):
        pass

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.cases = [
            _case(
                f"case_{length}",
                app="softmax",
                backend="softmax",
                variant="v",
                name="softmax",
                logical_cache_length=length,
            )
            for length in (0, 2, 4, 6, 8, 10)
        ]
        self.suite = BenchSuite("recovery", BenchDefaults(), self.cases)
        self.main_raw = self.root / "raw_db.csv"
        self._write_raw(
            self.main_raw, [(self.cases[0], 100.0), (self.cases[-1], 200.0)]
        )
        self.args = argparse.Namespace(
            suite=str(self.root / "suite.yaml"),
            output_root=None,
            raw_db=str(self.main_raw),
            probe_raw_db=None,
            measure_command="fixture {suite} {out}",
            out=str(self.root / "refine"),
            refinement_id=None,
            target_error=0.01,
            samples_per_iteration=2,
            validation_samples=2,
            max_iterations=3,
            kernel_types=[],
            sampling_strategy="midpoint",
            seed=0,
            metric="p50_us",
            require_convergence=False,
        )
        self.selected_by_suite: dict[Path, list[BenchCase]] = {}
        self.probe_values: dict[Path, dict[str, tuple[BenchCase, float]]] = {}
        self.measurement_exec_keys: list[str] = []
        self._real_write_candidate_suite = interpolation_module.write_candidate_suite

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_raw(
        self, path: Path, values: list[tuple[BenchCase, float]]
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=RAW_DB_COLUMNS)
            writer.writeheader()
            for case, value in values:
                row = {column: "" for column in RAW_DB_COLUMNS}
                row.update({
                    "run_id": f"original-{case.case_id}",
                    "status": "pass",
                    "app": case.app,
                    "args": case.args,
                    "xclbin_sha256": case.xclbin_sha256,
                    "exec_key": case.exec_key,
                    "p50_us": value,
                })
                writer.writerow(row)

    def _capture_suite(
        self, suite: BenchSuite, cases: list[BenchCase], path: Path
    ) -> None:
        self.selected_by_suite[path] = list(cases)
        self._real_write_candidate_suite(suite, cases, path)

    def _measure(self, template: str, suite_path: Path, out_dir: Path) -> Path:
        del template
        selected = self.selected_by_suite[suite_path]
        self.measurement_exec_keys.extend(case.exec_key for case in selected)
        path = out_dir / "raw_db.csv"
        values = self.probe_values.setdefault(path, {})
        for case in selected:
            length = int(case.shape["logical_cache_length"])
            values[case.exec_key] = (case, 100.0 + 10.0 * length)
        self._write_raw(path, list(values.values()))
        return path

    def _run(self, **patches: object) -> int:
        active_patches = [
            patch(
                "tools.latency_bench.interpolation._load_suite_for_raw",
                return_value=self.suite,
            ),
            patch(
                "tools.latency_bench.interpolation.write_candidate_suite",
                side_effect=self._capture_suite,
            ),
            patch(
                "tools.latency_bench.interpolation.run_measurement_command",
                side_effect=self._measure,
            ),
        ]
        active_patches.extend(patches.values())
        for active in active_patches:
            active.start()
        try:
            with redirect_stdout(io.StringIO()):
                return refine_command(self.args)
        finally:
            for active in reversed(active_patches):
                active.stop()

    def _checkpoint(self) -> dict[str, object]:
        return json.loads((self.root / "refine" / "recovery.json").read_text())

    def test_every_saved_boundary_resumes_once_with_original_errors(self) -> None:
        self.assertEqual(0, self._run())
        reference_errors = self._checkpoint()["errors"]
        self.assertEqual(2, len(self.measurement_exec_keys))

        for boundary in ("selected", "probed", "promoted", "committed", "partial"):
            with self.subTest(boundary=boundary):
                self.tearDown()
                self.setUp()
                crashed = False
                if boundary in {"selected", "probed", "committed"}:
                    real_save = interpolation_module._save_recovery_checkpoint

                    def save_then_crash(path, checkpoint, *, wanted=boundary):
                        nonlocal crashed
                        real_save(path, checkpoint)
                        if not crashed and checkpoint["phase"] == wanted:
                            crashed = True
                            raise self.AbruptLoss()

                    injected = patch(
                        "tools.latency_bench.interpolation._save_recovery_checkpoint",
                        side_effect=save_then_crash,
                    )
                elif boundary == "promoted":
                    real_promote = interpolation_module.promote_probe_rows

                    def promote_then_crash(*args, **kwargs):
                        nonlocal crashed
                        result = real_promote(*args, **kwargs)
                        if not crashed:
                            crashed = True
                            raise self.AbruptLoss()
                        return result

                    injected = patch(
                        "tools.latency_bench.interpolation.promote_probe_rows",
                        side_effect=promote_then_crash,
                    )
                else:
                    normal_measure = self._measure

                    def partial_then_crash(template, suite_path, out_dir):
                        nonlocal crashed
                        if crashed:
                            return normal_measure(template, suite_path, out_dir)
                        crashed = True
                        selected = self.selected_by_suite[suite_path]
                        self.measurement_exec_keys.append(selected[0].exec_key)
                        path = out_dir / "raw_db.csv"
                        self.probe_values[path] = {
                            selected[0].exec_key: (
                                selected[0],
                                100.0
                                + 10.0 * int(selected[0].shape["logical_cache_length"]),
                            )
                        }
                        self._write_raw(path, list(self.probe_values[path].values()))
                        raise self.AbruptLoss()

                    injected = patch(
                        "tools.latency_bench.interpolation.run_measurement_command",
                        side_effect=partial_then_crash,
                    )
                with self.assertRaises(self.AbruptLoss):
                    self._run(injected=injected)
                self.assertEqual(0, self._run())
                checkpoint = self._checkpoint()
                self.assertEqual(1, checkpoint["completed_budget"])
                self.assertEqual(1, len(checkpoint["history"]))
                self.assertEqual(reference_errors, checkpoint["errors"])
                self.assertEqual(2, len(self.measurement_exec_keys))
                with self.main_raw.open(newline="") as source:
                    promoted = [
                        row for row in csv.DictReader(source)
                        if row["exec_key"] in set(self.measurement_exec_keys)
                    ]
                self.assertEqual(
                    {f"original-{case.case_id}" for case in self.cases[1:-1]
                     if case.exec_key in set(self.measurement_exec_keys)},
                    {row["run_id"] for row in promoted},
                )

    def test_self_promotions_and_unrelated_rows_keep_epoch(self) -> None:
        self.assertEqual(0, self._run())
        original = self._checkpoint()
        initial_measurements = len(self.measurement_exec_keys)

        unrelated = _case(
            "unrelated", app="other", backend="other", variant="v",
            name="other", logical_cache_length=5,
        )
        current: list[tuple[BenchCase, float]] = []
        with self.main_raw.open(newline="") as source:
            for row in csv.DictReader(source):
                matching = next(
                    (case for case in self.cases if case.exec_key == row["exec_key"]),
                    None,
                )
                if matching is not None:
                    current.append((matching, float(row["p50_us"])))
        current.append((unrelated, 1.0))
        self._write_raw(self.main_raw, current)

        self.assertEqual(0, self._run())
        restored = self._checkpoint()
        self.assertEqual(original["epoch_id"], restored["epoch_id"])
        self.assertEqual(initial_measurements, len(self.measurement_exec_keys))
        self.assertEqual(1, len(restored["history"]))

    def test_zero_exit_with_partial_probes_retries_same_iteration(self) -> None:
        normal_measure = self._measure
        returned_partial = False

        def partial_success(template, suite_path, out_dir):
            nonlocal returned_partial
            if returned_partial:
                return normal_measure(template, suite_path, out_dir)
            returned_partial = True
            selected = self.selected_by_suite[suite_path]
            self.measurement_exec_keys.append(selected[0].exec_key)
            path = out_dir / "raw_db.csv"
            self.probe_values[path] = {
                selected[0].exec_key: (
                    selected[0],
                    100.0 + 10.0 * int(selected[0].shape["logical_cache_length"]),
                )
            }
            self._write_raw(path, list(self.probe_values[path].values()))
            return path

        with patch.object(self, "_measure", side_effect=partial_success):
            self.assertEqual(1, self._run())
            failed = self._checkpoint()
            self.assertEqual("failed", failed["phase"])
            self.assertEqual(0, failed["completed_budget"])
            self.assertEqual(0, self._run())

        recovered = self._checkpoint()
        self.assertEqual(1, recovered["completed_budget"])
        self.assertEqual(1, len(recovered["history"]))
        self.assertEqual(2, len(self.measurement_exec_keys))

    def test_budget_and_gate_changes_reuse_completed_iterations(self) -> None:
        self.args.validation_samples = 1
        self.args.target_error = 0.0001
        self.args.max_iterations = 3

        def nonlinear_measure(template, suite_path, out_dir):
            del template
            selected = self.selected_by_suite[suite_path]
            self.measurement_exec_keys.extend(case.exec_key for case in selected)
            path = out_dir / "raw_db.csv"
            values = self.probe_values.setdefault(path, {})
            for case in selected:
                values[case.exec_key] = (
                    case, 500.0 + int(case.shape["logical_cache_length"])
                )
            self._write_raw(path, list(values.values()))
            return path

        with patch.object(self, "_measure", side_effect=nonlinear_measure):
            self.assertEqual(0, self._run())
            self.assertEqual(3, self._checkpoint()["completed_budget"])
            count_at_exhaustion = len(self.measurement_exec_keys)
            self.assertEqual(0, self._run())
            self.assertEqual(count_at_exhaustion, len(self.measurement_exec_keys))

            self.args.require_convergence = True
            self.assertEqual(2, self._run())
            self.assertEqual(count_at_exhaustion, len(self.measurement_exec_keys))
            self.args.require_convergence = False

            self.args.max_iterations = 2
            self.assertEqual(0, self._run())
            self.assertEqual(count_at_exhaustion, len(self.measurement_exec_keys))

            self.args.max_iterations = 5
            self.assertEqual(0, self._run())
            self.assertLessEqual(
                len(self.measurement_exec_keys) - count_at_exhaustion, 2
            )
            count_after_delta = len(self.measurement_exec_keys)
            self.args.target_error = 10.0
            self.assertEqual(0, self._run())
            self.assertEqual(count_after_delta, len(self.measurement_exec_keys))

    def test_sampling_change_creates_epoch_but_reuses_physical_rows(self) -> None:
        self.assertEqual(0, self._run())
        first = self._checkpoint()
        first_measurements = len(self.measurement_exec_keys)
        self.args.sampling_strategy = "random"
        self.args.seed = 17

        self.assertEqual(0, self._run())
        second = self._checkpoint()

        self.assertNotEqual(first["epoch_id"], second["epoch_id"])
        self.assertEqual(1, len(second["archived_epochs"]))
        self.assertTrue(set(first["accepted_post_state"]) <= set(second["external_anchor_values"]))
        self.assertGreaterEqual(len(self.measurement_exec_keys), first_measurements)

    def test_random_resume_preserves_saved_remaining_order(self) -> None:
        self.args.sampling_strategy = "random"
        self.args.seed = 7
        self.args.validation_samples = 2
        self.args.max_iterations = 2
        self.args.target_error = 0.0001
        expected = [case.exec_key for case in self.cases[1:-1]]
        random.Random(self.args.seed).shuffle(expected)
        real_save = interpolation_module._save_recovery_checkpoint
        crashed = False

        def save_after_first_commit(path, checkpoint):
            nonlocal crashed
            real_save(path, checkpoint)
            if (
                not crashed
                and checkpoint["phase"] == "committed"
                and checkpoint["completed_budget"] == 1
            ):
                crashed = True
                raise self.AbruptLoss()

        def nonlinear_measure(template, suite_path, out_dir):
            del template
            selected = self.selected_by_suite[suite_path]
            self.measurement_exec_keys.extend(case.exec_key for case in selected)
            path = out_dir / "raw_db.csv"
            values = self.probe_values.setdefault(path, {})
            for case in selected:
                values[case.exec_key] = (
                    case, 500.0 + int(case.shape["logical_cache_length"])
                )
            self._write_raw(path, list(values.values()))
            return path

        with patch.object(self, "_measure", side_effect=nonlinear_measure):
            with self.assertRaises(self.AbruptLoss):
                self._run(injected=patch(
                    "tools.latency_bench.interpolation._save_recovery_checkpoint",
                    side_effect=save_after_first_commit,
                ))
            self.assertEqual(0, self._run())

        checkpoint = self._checkpoint()
        self.assertEqual(expected, [row["exec_key"] for row in checkpoint["selections"]])
        self.assertEqual(expected, self.measurement_exec_keys)
        self.assertEqual(2, checkpoint["completed_budget"])

    def test_validation_suite_and_external_anchor_changes_start_new_epochs(self) -> None:
        self.assertEqual(0, self._run())
        first = self._checkpoint()

        self.args.validation_samples = 1
        self.assertEqual(0, self._run())
        validation_changed = self._checkpoint()
        self.assertNotEqual(first["epoch_id"], validation_changed["epoch_id"])

        self.suite = replace(self.suite, name="recovery-v2")
        self.assertEqual(0, self._run())
        suite_changed = self._checkpoint()
        self.assertNotEqual(
            validation_changed["epoch_id"], suite_changed["epoch_id"]
        )

        unselected = next(
            case for case in self.cases
            if case.exec_key not in suite_changed["accepted_post_state"]
            and case not in (self.cases[0], self.cases[-1])
        )
        existing: list[tuple[BenchCase, float]] = []
        with self.main_raw.open(newline="") as source:
            rows = list(csv.DictReader(source))
        for case in self.cases:
            matching = next(
                (row for row in rows if row["exec_key"] == case.exec_key), None
            )
            if matching is not None:
                existing.append((case, float(matching["p50_us"])))
        existing.append((unselected, 333.0))
        self._write_raw(self.main_raw, existing)

        self.assertEqual(0, self._run())
        anchor_changed = self._checkpoint()
        self.assertNotEqual(suite_changed["epoch_id"], anchor_changed["epoch_id"])
        self.assertIn("relevant external anchors", anchor_changed["archived_epochs"][-1]["superseded_reason"])

    def test_legacy_progress_report_does_not_certify_recovery(self) -> None:
        out = Path(self.args.out)
        out.mkdir(parents=True)
        (out / "state.json").write_text(json.dumps({
            "status": "completed", "completed_budget": 99,
        }))
        self.args.max_iterations = 0

        self.assertEqual(0, self._run())

        checkpoint = self._checkpoint()
        self.assertEqual(0, checkpoint["completed_budget"])
        self.assertEqual([], checkpoint["history"])
        self.assertEqual(0, len(self.measurement_exec_keys))


if __name__ == "__main__":
    unittest.main()
