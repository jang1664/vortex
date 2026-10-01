"""Report parsing, category accounting, and driver fallback contracts."""

from contextlib import redirect_stdout, redirect_stderr
import csv
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import main as driver
import util_reports as util


def flat_report(path: Path, design: str = "level0_wrapper") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = ["| Site Type | Used | Fixed | Prohibited | Available | Util% |"]
    for site, used, available in (
        ("CLB LUTs*", "1,000", 1303680), ("CLB Registers", 2000, 2607360),
        ("DSPs", 10, 9024), ("Block RAM Tile", 5.5, 2016), ("URAM", 2, 960),
    ):
        rows.append(f"| {site} | {used} | 0 | 0 | {available} | 99.99 |")
    path.write_text(f"| Design : {design}\n| Device : xcu55c-fsvh2892-2L-e\n| Command : report_utilization -file output.rpt\n" + "\n".join(rows))


def hierarchy_report(path: Path, nested_cache: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = ["| Instance | Module | Total PPLOCs | Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | RAMB36 | RAMB18 | URAM | DSP Blocks |"]
    # Tuple counts are LUT, FF, RAMB36, RAMB18, URAM, DSP.
    nodes = [
        (0, "level0_wrapper", (150, 300, 8, 0, 3, 12)),
        (1, "vortex_axi", (100, 200, 5, 0, 2, 10)),
        (2, "execute", (20, 40, 1, 0, 0, 1)),
        (3, "alu_unit", (20, 40, 1, 0, 0, 1)),
        (4, "(alu_unit)", (2, 4, 0, 0, 0, 0)),
        (2, "mem_unit", (20, 40, 2, 0, 1, 0)),
        (3, "local_mem", (20, 40, 2, 0, 1, 0)),
    ]
    if nested_cache:
        nodes.append((4, "l2cache", (10, 20, 1, 0, 0, 0)))
    nodes.extend([
        (2, "gemm_node", (50, 100, 1, 1, 1, 8)),
        (3, "u_VX_gemm_unit", (25, 50, 0, 0, 1, 7)),
        (3, "u_tmem_subsystem", (20, 40, 1, 1, 0, 1)),
        (4, "g_bank0.u_bank", (10, 20, 0, 1, 0, 0)),
        (4, "u_dma_engine", (10, 20, 1, 0, 0, 1)),
    ])
    for depth, name, counts in nodes:
        lut, ff, r36, r18, uram, dsp = counts
        fields = ["  " * depth + name, "module", "-", lut, lut, 0, 0, ff, r36, r18, uram, dsp]
        rows.append("| " + " | ".join(f"{item}(99.99%)" if isinstance(item, int) else item for item in fields) + " |")
    rows.append("+--------------------+")
    path.write_text("| Design : level0_wrapper\n| Device : xcu55c-fsvh2892-2L-e\n| Command : report_utilization -hierarchical -hierarchical_percentages\n| Design State : Physopt postRoute\n" + "\n".join(rows))


class UtilReportsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_full_device_totals_ignore_report_percentages(self):
        path = self.root / "total.rpt"
        flat_report(path)
        analysis = util.analyze_report(path, "total", "routed", False)
        rows = driver.analysis_rows("C1", "total", analysis)
        self.assertEqual(1000, rows[0]["used"])
        self.assertAlmostEqual(1000 / 1303680 * 100, rows[0]["device_pct"])
        self.assertEqual(5.5, analysis.values["Full FPGA"]["BRAM"])

    def test_hierarchy_counts_half_brams_and_nonoverlapping_categories(self):
        path = self.root / "hier.rpt"
        hierarchy_report(path, nested_cache=True)
        analysis = util.analyze_report(path, "breakdown", "pre_opt", False)
        self.assertEqual(30, analysis.values["Cache/LMEM/TMEM"]["LUT"])
        self.assertEqual(2.5, analysis.values["Cache/LMEM/TMEM"]["BRAM"])
        self.assertEqual(15, analysis.values["Misc"]["LUT"])
        for resource in util.RESOURCES:
            self.assertEqual(analysis.values["Total Vortex_axi"][resource], sum(analysis.values[category][resource] for category in util.CATEGORIES[:-1]))
        self.assertEqual(util.U55C_CAPACITY, analysis.capacity)

    def test_absent_architecture_blocks_are_zero(self):
        report = util.Report(self.root / "hier", {"Device": "xcu55c"})
        report.hierarchy = {
            "vortex_axi": dict.fromkeys(util.RESOURCES, 20),
            "vortex_axi/execute/tcu_unit": dict.fromkeys(util.RESOURCES, 10),
        }
        values = util.breakdown(report)
        self.assertEqual(10, values["SIMT"]["DSP"])
        self.assertEqual(0, values["MXU"]["LUT"])
        self.assertEqual(0, values["DMA"]["LUT"])

    def test_invalid_primary_falls_back_to_same_stage_copy(self):
        primary = self.root / "bin/impl_1_full_util_routed.rpt"
        primary.parent.mkdir()
        primary.write_text("partial report")
        fallback = util.implementation_dir(self.root) / "full_util_routed.rpt"
        flat_report(fallback)
        analysis, notes = util.select_report(self.root, "total")
        self.assertEqual(fallback.resolve(), analysis.report.path)
        self.assertEqual("routed", analysis.stage)
        self.assertTrue(analysis.fallback)
        self.assertIn("Rejected", notes[1])

    def test_placed_then_linked_fallback_priority(self):
        impl = util.implementation_dir(self.root)
        flat_report(impl / "init_report_utilization_0.rpt")
        flat_report(impl / "full_util_placed.rpt")
        analysis, _ = util.select_report(self.root, "total")
        self.assertEqual("placed", analysis.stage)

    def test_hierarchy_fallback_can_supply_full_design_total(self):
        hierarchy_report(util.implementation_dir(self.root) / "hier_utilization.rpt")
        analysis, _ = util.select_report(self.root, "total")
        self.assertEqual("pre_opt", analysis.stage)
        self.assertEqual(150, analysis.values["Full FPGA"]["LUT"])

    def test_kernel_total_is_rejected(self):
        path = self.root / "total.rpt"
        flat_report(path, design="ulp_vortex_afu_1_0")
        with self.assertRaisesRegex(ValueError, "full level0_wrapper"):
            util.analyze_report(path, "total", "synth", True)

    def test_truncated_hierarchy_is_rejected(self):
        path = self.root / "hier.rpt"
        hierarchy_report(path)
        path.write_text(path.read_text().rsplit("\n", 1)[0])
        with self.assertRaisesRegex(ValueError, "incomplete"):
            util.read_report(path)

    def test_checkpoint_order_and_synth_scope(self):
        impl = util.implementation_dir(self.root)
        impl.mkdir(parents=True)
        for suffix in ("opt", "routed", "postroute_physopt"):
            (impl / f"level0_wrapper_{suffix}.dcp").touch()
        synth = impl.parent / "ulp_vortex_afu_1_0_synth_1/ulp_vortex_afu_1_0.dcp"
        synth.parent.mkdir()
        synth.touch()
        self.assertEqual(["postroute_physopt", "routed", "opt"], [stage for _, stage in util.checkpoint_candidates(self.root, "total")])
        self.assertEqual("synth", util.checkpoint_candidates(self.root, "breakdown")[-1][1])

    def test_category_patterns_match_existing_tcl(self):
        script = driver.ROOT / "hw/syn/xilinx/xrt/export_util.tcl"
        code = "namespace eval ::vortex_util {variable library_only 1}\n" + f"source {{{script}}}\n" + """
foreach key {simt memory mxu dma} {
    foreach pattern [dict get [::vortex_util::category_specs] $key patterns] {
        puts "$key\t$pattern"
    }
}
"""
        result = subprocess.run(["tclsh"], input=code, text=True, capture_output=True, check=True)
        patterns = {}
        for line in result.stdout.splitlines():
            key, pattern = line.split("\t")
            patterns.setdefault(key, []).append(pattern)
        for key, category in zip(("simt", "memory", "mxu", "dma"), util.CATEGORY_PATTERNS):
            self.assertEqual(tuple(patterns[key]), util.CATEGORY_PATTERNS[category])

    def test_report_only_driver_does_not_launch_vivado(self):
        build = self.root / "build"
        flat_report(build / "bin/impl_1_full_util_routed.rpt")
        hierarchy_report(build / "bin/hier_utilization.rpt")
        config = self.root / "candidates.yaml"
        config.write_text(f"schema_version: 1\ncandidates:\n  C1: {build}\n")
        out = self.root / "results"
        with patch.object(driver, "extract_report", side_effect=AssertionError("must not extract")), redirect_stdout(io.StringIO()):
            code = driver.main(["--config", str(config), "--candidates", "C1", "--action", "total,breakdown", "--output-dir", str(out)])
        self.assertEqual(0, code)
        with (out / "total.csv").open() as stream:
            self.assertEqual(5, len(list(csv.DictReader(stream))))
        with (out / "breakdown.csv").open() as stream:
            self.assertEqual(30, len(list(csv.DictReader(stream))))
        self.assertTrue((out / "summary.md").is_file())

    def test_extraction_uses_arguments_and_validates_exported_report(self):
        impl = util.implementation_dir(self.root)
        impl.mkdir(parents=True)
        (impl / "level0_wrapper_routed.dcp").touch()
        def fake_vivado(command, work, stream):
            self.assertEqual("vivado", command[0])
            flat_report(Path(command[command.index("-tclargs") + 3]))
            return 0
        with patch.object(driver, "run_vivado", side_effect=fake_vivado), redirect_stdout(io.StringIO()):
            analysis, _ = driver.extract_report(self.root, "C1", "total", self.root / "results", "vivado", [])
        self.assertEqual("routed", analysis.stage)
        self.assertTrue(analysis.fallback)
        self.assertEqual(1000, analysis.values["Full FPGA"]["LUT"])

    def test_missing_candidate_does_not_stop_other_candidates(self):
        build = self.root / "build"
        flat_report(build / "bin/impl_1_full_util_routed.rpt")
        config = self.root / "candidates.yaml"
        config.write_text(f"schema_version: 1\ncandidates:\n  Missing: {self.root / 'missing'}\n  Good: {build}\n")
        out = self.root / "results"
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = driver.main(["--config", str(config), "--action", "total", "--output-dir", str(out)])
        self.assertEqual(1, code)
        with (out / "total.csv").open() as stream:
            rows = list(csv.DictReader(stream))
        self.assertEqual("", rows[0]["used"])
        self.assertEqual("unavailable", rows[0]["status"])
        self.assertEqual("ok", rows[-1]["status"])

    def test_alias_bin_and_repo_relative_paths(self):
        aliases = self.root / "aliases.yaml"
        aliases.write_text(f"aliases:\n  chosen:\n    path: {self.root / 'build/bin'}\n")
        config = self.root / "candidates.yaml"
        config.write_text("schema_version: 1\ncandidates:\n  C1: chosen\n  C2: build/example\n")
        values = driver.load_candidates(config, aliases)
        self.assertEqual(self.root / "build", values["C1"])
        self.assertEqual(driver.ROOT / "build/example", values["C2"])

    def test_list_arguments_and_invalid_actions(self):
        self.assertEqual(["C1", "C2"], driver.list_argument(["C1,C2", "C1"]))
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            driver.main(["--action", "invalid"])
        self.assertEqual(2, error.exception.code)

    def test_invalid_yaml_is_an_input_error(self):
        config = self.root / "bad.yaml"
        config.write_text("candidates: [invalid YAML")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            driver.main(["--config", str(config)])
        self.assertEqual(2, error.exception.code)

    def test_timeout_kills_launcher_and_vivado_process_group(self):
        with patch.object(driver.subprocess, "Popen") as launcher, patch.object(driver.os, "killpg") as kill:
            process = launcher.return_value.__enter__.return_value
            process.pid = 42
            process.wait.side_effect = [subprocess.TimeoutExpired("vivado", 1800), 0]
            with self.assertRaises(subprocess.TimeoutExpired):
                driver.run_vivado(["vivado"], self.root, io.StringIO())
            kill.assert_called_once_with(42, driver.signal.SIGKILL)
            self.assertTrue(launcher.call_args.kwargs["start_new_session"])

    def test_both_missing_reports_share_one_checkpoint_open(self):
        build = self.root / "build"
        impl = util.implementation_dir(build)
        impl.mkdir(parents=True)
        (impl / "level0_wrapper_routed.dcp").touch()
        config = self.root / "candidates.yaml"
        config.write_text(f"schema_version: 1\ncandidates:\n  C1: {build}\n")
        def fake_vivado(command, work, stream):
            self.assertEqual("1", command[-1])
            path = Path(command[command.index("-tclargs") + 3])
            flat_report(path)
            hierarchy_report(path.parent / "breakdown.rpt")
            return 0
        with patch.object(driver, "run_vivado", side_effect=fake_vivado) as runner, redirect_stdout(io.StringIO()):
            code = driver.main(["--config", str(config), "--action", "breakdown,total", "--output-dir", str(self.root / "results")])
        self.assertEqual(0, code)
        self.assertEqual(1, runner.call_count)

    def test_generated_tcl_exports_both_reports_and_opens_checkpoint_once(self):
        # Execute the exact wrapper with Vivado commands stubbed, rather than mirroring its branches.
        code = """set argv {input.dcp total output.rpt impl_1 1}
proc set_param {args} {}
proc open_checkpoint {args} {puts "OPEN $args"}
proc report_utilization {args} {puts "REPORT $args"}
proc close_design {} {}
""" + driver.EXTRACT_TCL
        result = subprocess.run(["tclsh"], input=code, text=True, capture_output=True, check=True)
        self.assertEqual(1, result.stdout.count("OPEN "))
        self.assertEqual(2, result.stdout.count("REPORT "))
        self.assertIn("-hierarchical", result.stdout)

    def test_failed_export_does_not_reuse_old_report_and_tries_next_checkpoint(self):
        impl = util.implementation_dir(self.root)
        impl.mkdir(parents=True)
        for stage in ("routed", "opt"):
            (impl / f"level0_wrapper_{stage}.dcp").touch()
        out = self.root / "results"
        flat_report(out / "reports/C1/total_0_routed/total.rpt")
        with patch.object(driver, "run_vivado", return_value=0) as runner, redirect_stdout(io.StringIO()):
            analysis, notes = driver.extract_report(self.root, "C1", "total", out, "vivado", [])
        self.assertIsNone(analysis)
        self.assertEqual(2, runner.call_count)
        self.assertEqual(3, len(notes))


if __name__ == "__main__":
    unittest.main()
