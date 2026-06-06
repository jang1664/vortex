from __future__ import annotations

import json
import unittest

import pandas as pd

from tools.latency_bench.estimate import (
    LatencyEstimateOptions,
    evaluate_latency_estimator_groups,
    estimate_composed_latency,
    latency_feature_dict,
)


def _row(
    *,
    case_id: str,
    latency_us: float | None,
    m: int,
    n: int = 8,
    k: int = 8,
    calls_per_forward: int = 1,
    name: str = "attn_qkT",
    status: str = "pass",
    fpga_bin: str = "plot_bin",
) -> dict[str, object]:
    return {
        "case_id": case_id,
        "app": "sgemm_tcu",
        "name": name,
        "stage": "prefill",
        "variant": "v1",
        "args": f"-m {m} -n {n} -k {k}",
        "shape_json": json.dumps({"M": m, "N": n, "K": k, "batch": 1, "seq": m}),
        "calls_per_forward": calls_per_forward,
        "latency_us": latency_us,
        "weighted_latency_us": None if latency_us is None else latency_us * calls_per_forward,
        "compose_status": status,
        "expected_fpga_bin_label": fpga_bin,
        "source_raw_dbs": "raw_db.csv" if status == "pass" else "",
        "source_run_ids": "run_a" if status == "pass" else "",
        "selected_run_id": "run_a" if status == "pass" else "",
        "selected_timestamp_utc": "2026-01-01T00:00:00+00:00" if status == "pass" else "",
    }


class LatencyEstimateTest(unittest.TestCase):
    def test_feature_extraction_uses_shape_and_args(self) -> None:
        row = pd.Series(_row(case_id="c1", latency_us=10.0, m=2, n=3, k=4))

        features = latency_feature_dict(row)

        self.assertEqual(2.0, features["num:M"])
        self.assertEqual(3.0, features["num:N"])
        self.assertEqual(4.0, features["num:K"])
        self.assertEqual(24.0, features["num:M*N*K"])
        self.assertIn("log1p:M*N*K", features)
        self.assertEqual(1.0, features["num:batch"])

    def test_estimates_missing_case_with_auto_shape_1d_and_marks_extrapolation(self) -> None:
        composed = pd.DataFrame(
            [
                _row(case_id="m10", latency_us=100.0, m=10),
                _row(case_id="m20", latency_us=200.0, m=20),
                _row(case_id="m30", latency_us=300.0, m=30),
                _row(case_id="m40", latency_us=None, m=40, calls_per_forward=2, status="missing"),
            ]
        )

        with self.assertWarnsRegex(RuntimeWarning, "extrapolation"):
            out = estimate_composed_latency(composed, LatencyEstimateOptions(min_train_rows=3))
        target = out[out["case_id"] == "m40"].iloc[0]

        self.assertEqual("estimated", target["compose_status"])
        self.assertGreater(float(target["latency_us"]), 0.0)
        self.assertEqual(
            float(target["latency_us"]) * 2.0,
            float(target["weighted_latency_us"]),
        )
        self.assertEqual("auto_shape:linear_1d", target["estimate_model"])
        self.assertAlmostEqual(400.0, float(target["latency_us"]), places=6)
        self.assertTrue(str(target["estimate_basis"]))
        self.assertTrue(str(target["estimate_selected_by"]))
        self.assertEqual("extrapolation", target["estimate_mode"])
        self.assertEqual(3, int(target["estimate_train_rows"]))
        self.assertIn("fpga_bin_label=plot_bin", target["estimate_group"])
        self.assertEqual("raw_db.csv", target["source_raw_dbs"])

    def test_explicit_ridge_log_estimator_still_works(self) -> None:
        composed = pd.DataFrame(
            [
                _row(case_id="m10", latency_us=100.0, m=10),
                _row(case_id="m20", latency_us=200.0, m=20),
                _row(case_id="m30", latency_us=300.0, m=30),
                _row(case_id="m40", latency_us=None, m=40, status="missing"),
            ]
        )

        out = estimate_composed_latency(
            composed,
            LatencyEstimateOptions(model="ridge_log", warn_extrapolation=False),
        )
        target = out[out["case_id"] == "m40"].iloc[0]

        self.assertEqual("estimated", target["compose_status"])
        self.assertEqual("ridge_log", target["estimate_model"])
        self.assertGreater(float(target["latency_us"]), 0.0)

    def test_auto_shape_selects_2d_when_it_has_better_cv_fit(self) -> None:
        rows = []
        for m in (2, 4, 8):
            for n in (3, 5, 7):
                latency = 1.0 + 2.0 * m + 3.0 * n + 4.0 * m * n
                rows.append(_row(case_id=f"m{m}_n{n}", latency_us=latency, m=m, n=n, k=1))
        rows.append(_row(case_id="target", latency_us=None, m=16, n=11, k=1, status="missing"))
        composed = pd.DataFrame(rows)

        out = estimate_composed_latency(
            composed,
            LatencyEstimateOptions(warn_extrapolation=False),
        )
        target = out[out["case_id"] == "target"].iloc[0]

        self.assertEqual("auto_shape:linear_2d", target["estimate_model"])
        self.assertEqual("M,N,M*N", target["estimate_basis"])
        self.assertAlmostEqual(770.0, float(target["latency_us"]), places=6)

    def test_auto_shape_selects_3d_when_it_has_better_cv_fit(self) -> None:
        rows = []
        for m in (2, 4, 8):
            for n in (3, 5):
                for k in (7, 11):
                    latency = 1.0 + 2.0 * m * k + 3.0 * m * n * k
                    rows.append(_row(case_id=f"m{m}_n{n}_k{k}", latency_us=latency, m=m, n=n, k=k))
        rows.append(_row(case_id="target", latency_us=None, m=16, n=7, k=13, status="missing"))
        composed = pd.DataFrame(rows)

        out = estimate_composed_latency(
            composed,
            LatencyEstimateOptions(warn_extrapolation=False),
        )
        target = out[out["case_id"] == "target"].iloc[0]

        self.assertEqual("auto_shape:linear_3d", target["estimate_model"])
        self.assertEqual("M,N,K,M*N,M*K,N*K,M*N*K", target["estimate_basis"])
        self.assertAlmostEqual(4785.0, float(target["latency_us"]), places=6)

    def test_evaluate_latency_estimator_groups_reports_selected_strategy(self) -> None:
        composed = pd.DataFrame(
            [
                _row(case_id="m10", latency_us=100.0, m=10),
                _row(case_id="m20", latency_us=200.0, m=20),
                _row(case_id="m30", latency_us=300.0, m=30),
            ]
        )

        scores = evaluate_latency_estimator_groups(composed, LatencyEstimateOptions())
        selected = scores[scores["selected"]]

        self.assertFalse(scores.empty)
        self.assertEqual(1, len(selected))
        self.assertEqual("auto_shape:linear_1d", selected.iloc[0]["candidate_model"])
        self.assertIn(selected.iloc[0]["candidate_basis"], {"M", "M*N", "M*N*K"})

    def test_fallback_nearest_scale_when_training_rows_are_sparse(self) -> None:
        composed = pd.DataFrame(
            [
                _row(case_id="m10", latency_us=100.0, m=10),
                _row(case_id="m20", latency_us=None, m=20, status="missing"),
            ]
        )

        out = estimate_composed_latency(
            composed,
            LatencyEstimateOptions(min_train_rows=3, warn_extrapolation=False),
        )
        target = out[out["case_id"] == "m20"].iloc[0]

        self.assertEqual("estimated", target["compose_status"])
        self.assertEqual("nearest_scale", target["estimate_model"])
        self.assertAlmostEqual(200.0, float(target["latency_us"]))
        self.assertEqual("m10", target["estimate_source_case_id"])

    def test_keeps_missing_when_group_has_no_training_rows(self) -> None:
        composed = pd.DataFrame(
            [
                _row(case_id="train", latency_us=100.0, m=10, name="attn_qkT"),
                _row(case_id="target", latency_us=None, m=20, name="attn_pv", status="missing"),
            ]
        )

        out = estimate_composed_latency(
            composed,
            LatencyEstimateOptions(min_train_rows=3, warn_extrapolation=False),
        )
        target = out[out["case_id"] == "target"].iloc[0]

        self.assertEqual("missing", target["compose_status"])
        self.assertEqual("", target["estimate_model"])


if __name__ == "__main__":
    unittest.main()
