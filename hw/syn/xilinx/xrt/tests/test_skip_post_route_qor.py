#!/usr/bin/env python3
"""Check the generated-script edit without launching Vivado or synthesis."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[1] / "skip_post_route_qor.tcl"
QOR_BLOCK = '''if {[catch {report_qor_assessment -file qor_assessment_post_route_design.rpt } _error]} {
  puts "The report_qor_assessment command failed with message '${_error}', the flow will continue but this report will be missing."
}'''


@unittest.skipUnless(shutil.which("tclsh"), "tclsh is required")
class QorHookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="qor hook ")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.cwd = root / "prj/prj.runs/impl_1"
        self.cwd.mkdir(parents=True)
        self.script = root / "scripts/_vpl_post_route.tcl"
        self.script.parent.mkdir()
        self.runner = root / "run.tcl"
        # Catch Tcl failures explicitly: tclsh on stdin otherwise exits zero.
        self.runner.write_text(
            'if {[catch {source [lindex $argv 0]} message]} {\n'
            '  puts stderr $message\n  exit 1\n}\n'
        )

    def run_hook(self):
        return subprocess.run(["tclsh", str(self.runner), str(HOOK)], cwd=self.cwd,
                              capture_output=True, text=True)

    def test_removes_only_qor_and_preserves_backup_on_repeated_run(self):
        before = "report_timing_summary\n" + QOR_BLOCK + "\nwrite_checkpoint routed.dcp\n"
        self.script.write_text(before)
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.script.read_text()
        self.assertIn("report_timing_summary\n", after)
        self.assertIn("write_checkpoint routed.dcp\n", after)
        self.assertNotIn(QOR_BLOCK, after)
        backup = Path(str(self.script) + ".before_skip_qor")
        self.assertEqual(backup.read_text(), before)
        self.assertEqual(self.run_hook().returncode, 0)
        self.assertEqual(self.script.read_text(), after)
        self.assertEqual(backup.read_text(), before)

    def test_unknown_and_duplicate_blocks_leave_script_unchanged(self):
        for before in ("report_qor_assessment -new-option\n", QOR_BLOCK + "\n" + QOR_BLOCK):
            with self.subTest(before=before):
                self.script.write_text(before)
                self.assertNotEqual(self.run_hook().returncode, 0)
                self.assertEqual(self.script.read_text(), before)
                self.assertFalse(Path(str(self.script) + ".before_skip_qor").exists())

    def test_missing_generated_hook_fails(self):
        result = self.run_hook()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated hook missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
