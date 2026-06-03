from __future__ import annotations

import unittest

from tools.latency_bench.status import classify_status


class ReportTest(unittest.TestCase):
    def test_classifies_timeout_returncodes(self) -> None:
        self.assertEqual("timeout", classify_status(124, has_status=True, bench={}))
        self.assertEqual("timeout", classify_status(137, has_status=True, bench={}))
        self.assertEqual("timeout", classify_status(124, has_status=True, bench={"parse_error": "missing"}))
        self.assertEqual("timeout", classify_status(2, has_status=True, bench={}, failure_reason="timeout"))

    def test_classifies_non_timeout_statuses(self) -> None:
        self.assertEqual("not_run", classify_status(999, has_status=False, bench={}))
        self.assertEqual("parse_error", classify_status(0, has_status=True, bench={"parse_error": "bad"}))
        self.assertEqual("pass", classify_status(0, has_status=True, bench={"samples": 3}))
        self.assertEqual("fail", classify_status(1, has_status=True, bench={}))
        self.assertEqual("fail", classify_status(1, has_status=True, bench={"parse_error": "missing"}))

    def test_classifies_build_fail_phase(self) -> None:
        self.assertEqual(
            "build_fail",
            classify_status(2, has_status=True, bench={"parse_error": "missing"}, failure_phase="build"),
        )
        self.assertEqual(
            "build_fail",
            classify_status(2, has_status=True, bench={"parse_error": "missing"}, failure_reason="build"),
        )


if __name__ == "__main__":
    unittest.main()
