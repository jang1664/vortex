from __future__ import annotations

import csv
import json
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.idle_guard import (
    IdlePolicy,
    PowerSample,
    evaluate_idle,
    load_policy,
    read_power_samples,
    replay_idle,
    wait_for_stable_idle,
)


def _samples(values: list[float], *, interval: float = 0.1) -> list[PowerSample]:
    return [
        PowerSample(timestamp_s=index * interval, total_power_w=value)
        for index, value in enumerate(values)
    ]


class IdleGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = IdlePolicy(
            window_samples=4,
            confirmation_windows=2,
            window_step_samples=2,
            max_wait_s=1.0,
            poll_interval_s=0.01,
            max_mean_delta_w=0.05,
            max_std_w=0.10,
            max_stderr_w=0.05,
            max_abs_slope_w_per_s=0.10,
        )

    def test_stable_trace_passes_at_first_complete_window(self) -> None:
        samples = _samples([35.00, 35.01, 34.99, 35.00, 35.01, 35.00])
        decision = replay_idle(samples, self.policy)
        self.assertTrue(decision.stable)
        self.assertEqual(self.policy.required_samples, decision.observed_samples)
        self.assertEqual(4, decision.selected.samples)

    def test_drift_trace_is_rejected(self) -> None:
        samples = _samples([35.0 + index * 0.05 for index in range(20)])
        decision = replay_idle(samples, self.policy)
        self.assertFalse(decision.stable)
        self.assertIn("slope", decision.reason)

    def test_spike_is_rejected_until_it_leaves_both_windows(self) -> None:
        samples = _samples(
            [35.0, 35.0, 36.0, 35.0, 35.0, 35.0, 35.0, 35.0, 35.0]
        )
        first = evaluate_idle(samples[: self.policy.required_samples], self.policy)
        final = replay_idle(samples, self.policy)
        self.assertFalse(first.stable)
        self.assertTrue(final.stable)
        self.assertGreater(final.observed_samples, self.policy.required_samples)

    def test_csv_reader_ignores_partial_and_out_of_range_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "power.csv"
            with path.open("w", newline="") as fp:
                writer = csv.writer(fp)
                writer.writerow(("timestamp_s", "total_power_w"))
                writer.writerow((1.0, 35.0))
                writer.writerow(("partial", ""))
                writer.writerow((2.0, 36.0))
            samples = read_power_samples(path, not_before_s=1.5)
        self.assertEqual([PowerSample(2.0, 36.0)], samples)

    def test_policy_supports_per_bdf_override(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.json"
            path.write_text(
                json.dumps(
                    {
                        "default": {"max_wait_s": 2.0},
                        "devices": {"0000:3d:00.1": {"max_wait_s": 3.0}},
                    }
                )
            )
            default = load_policy(path)
            overridden = load_policy(path, device_bdf="0000:3d:00.1")
        self.assertEqual(2.0, default.max_wait_s)
        self.assertEqual(3.0, overridden.max_wait_s)

    def test_wait_times_out_for_persistently_unstable_trace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "power.csv"
            with path.open("w", newline="") as fp:
                writer = csv.writer(fp)
                writer.writerow(("timestamp_s", "total_power_w"))
                for sample in _samples([35.0 + index * 0.05 for index in range(20)]):
                    writer.writerow((sample.timestamp_s, sample.total_power_w))
            policy = IdlePolicy(
                **{
                    **self.policy.__dict__,
                    "max_wait_s": 0.02,
                    "poll_interval_s": 0.005,
                }
            )
            decision = wait_for_stable_idle(path, policy, not_before_s=0.0)
        self.assertFalse(decision.stable)
        self.assertTrue(decision.reason.startswith("timeout:"), decision.reason)


if __name__ == "__main__":
    unittest.main()
