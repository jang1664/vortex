#!/usr/bin/env python3
"""Focused tests for the streaming eladd trace analyzer."""

import hashlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import analyze_trace


class AnalyzeTraceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.dump_path = Path(self.temp_dir.name) / "kernel.dump"
        self.dump_path.write_bytes(b"trusted synthetic dump")
        self.dump_digest = hashlib.sha256(self.dump_path.read_bytes()).hexdigest()

    def run_analyzer(self, trace: str, expected_digest: str | None = None):
        stdout = io.StringIO()
        stderr = io.StringIO()
        digest = self.dump_digest if expected_digest is None else expected_digest
        with patch.object(analyze_trace, "EXPECTED_DUMP_SHA256", digest):
            status = analyze_trace.analyze_trace(
                io.StringIO(trace), self.dump_path, stdout, stderr
            )
        return status, stdout.getvalue(), stderr.getvalue()

    @staticmethod
    def debug(pc: int, tmask: str = "1") -> str:
        return f"DEBUG Instr: tmask={tmask}, PC=0x{pc:x}\n"

    def successful_trace(self, pc: int = analyze_trace.KERNEL_RANGE[0]) -> str:
        return self.debug(pc) + "PERF: instrs=1, cycles=2\nPASSED!\n"

    def test_known_successful_trace(self):
        status, stdout, stderr = self.run_analyzer(self.successful_trace())

        self.assertEqual(0, status)
        self.assertEqual("", stderr)
        self.assertIn("kernel_lane_instructions=1\n", stdout)
        self.assertIn(f"kernel_dump_sha256={self.dump_digest}\n", stdout)
        self.assertTrue(stdout.endswith("PERF: instrs=1, cycles=2\nPASSED!\n"))

    def test_malformed_debug_record_fails(self):
        status, stdout, stderr = self.run_analyzer(
            "DEBUG Instr: missing fields\nPERF: instrs=1\nPASSED!\n"
        )

        self.assertEqual(1, status)
        self.assertEqual("", stdout)
        self.assertIn("malformed DEBUG instruction", stderr)

    def test_empty_and_missing_evidence_fail(self):
        cases = {
            "empty": "",
            "missing_perf": self.debug(analyze_trace.KERNEL_RANGE[0]) + "PASSED!\n",
            "missing_result": self.debug(analyze_trace.KERNEL_RANGE[0]) + "PERF: instrs=1\n",
        }
        for name, trace in cases.items():
            with self.subTest(name=name):
                status, stdout, stderr = self.run_analyzer(trace)
                self.assertEqual(1, status)
                self.assertEqual("", stdout)
                self.assertTrue(stderr.startswith("error:"))

    def test_failed_terminal_result_fails(self):
        trace = self.debug(analyze_trace.KERNEL_RANGE[0]) + "PERF: instrs=1\nFAILED!\n"
        status, stdout, stderr = self.run_analyzer(trace)

        self.assertEqual(1, status)
        self.assertEqual("", stdout)
        self.assertIn("terminal result is FAILED!", stderr)

    def test_dump_hash_mismatch_fails_before_trace_result(self):
        status, stdout, stderr = self.run_analyzer(
            self.successful_trace(), expected_digest="0" * 64
        )

        self.assertEqual(1, status)
        self.assertEqual("", stdout)
        self.assertIn("kernel dump SHA-256 mismatch", stderr)

    def test_zero_kernel_pcs_fails(self):
        status, stdout, stderr = self.run_analyzer(self.successful_trace(pc=0x1000))

        self.assertEqual(1, status)
        self.assertEqual("", stdout)
        self.assertIn("no active kernel instructions", stderr)

    def test_incomplete_trace_vs_perf_count_fails(self):
        trace = self.debug(analyze_trace.KERNEL_RANGE[0]) + "PERF: instrs=130\nPASSED!\n"
        status, stdout, stderr = self.run_analyzer(trace)

        self.assertEqual(1, status)
        self.assertEqual("", stdout)
        self.assertIn("trace lane count is incomplete", stderr)

    def test_inclusive_kernel_and_address_control_endpoints(self):
        endpoints = (
            analyze_trace.KERNEL_RANGE[0],
            analyze_trace.KERNEL_RANGE[1],
            analyze_trace.ADDRESS_CONTROL_RANGES[0][0],
            analyze_trace.ADDRESS_CONTROL_RANGES[0][1],
            analyze_trace.ADDRESS_CONTROL_RANGES[-1][0],
            analyze_trace.ADDRESS_CONTROL_RANGES[-1][1],
        )
        trace = "".join(self.debug(pc) for pc in endpoints)
        trace += f"PERF: instrs={len(endpoints)}\nPASSED!\n"

        status, stdout, stderr = self.run_analyzer(trace)

        self.assertEqual(0, status)
        self.assertEqual("", stderr)
        self.assertIn(f"kernel_lane_instructions={len(endpoints)}\n", stdout)
        self.assertIn("address_control_lane_instructions=4\n", stdout)


if __name__ == "__main__":
    unittest.main()
