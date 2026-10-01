#!/usr/bin/env python3

import importlib.util
import os
import subprocess
import tempfile
import types
import unittest
from pathlib import Path


XRT_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = XRT_DIR.parents[3]
BUILD_ROOT = Path(os.environ.get("VORTEX_TEST_BUILD_DIR", REPO_ROOT / "build"))


def load_generator():
    spec = importlib.util.spec_from_file_location(
        "gen_vitis_ini", XRT_DIR / "gen_vitis_ini.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_args(**overrides):
    values = {
        "target": "hw",
        "hook_dir": "/tmp/xrt-hooks",
        "clock_freq": "100",
        "sp": [],
        "simulator": "xsim",
        "vcs_install_dir": None,
        "vcs_simlib_dir": None,
        "vcs_gcc_dir": None,
        "debug": None,
        "profile": False,
        "disable_congestion_fail_fast": False,
        "mxu_slr_floorplan": False,
        "place_directive": None,
        "route_directive": None,
    }
    values.update(overrides)
    return types.SimpleNamespace(**values)


class GenVitisIniTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generator = load_generator()

    def vivado_lines(self, **overrides):
        return self.generator.build_ini(make_args(**overrides))["vivado"]

    def test_clock_workaround_is_hardware_only(self):
        hook = "prop=run.impl_1.STEPS.INIT_DESIGN.TCL.PRE=/tmp/xrt-hooks/pre_init_hook.tcl"
        for slr in (False, True):
            for disabled in (False, True):
                with self.subTest(slr=slr, disabled=disabled):
                    options = dict(mxu_slr_floorplan=slr,
                                   disable_congestion_fail_fast=disabled)
                    self.assertEqual(self.vivado_lines(**options).count(hook), 1)
                    self.assertNotIn(hook, self.vivado_lines(target="hw_emu", **options))
        self.assertFalse(any("INIT_DESIGN.TCL.PRE" in line
                             for line in self.vivado_lines(hook_dir=None)))

    def test_hw_registers_post_place_hook_by_default(self):
        lines = self.vivado_lines()
        self.assertIn(
            "prop=run.impl_1.STEPS.PLACE_DESIGN.TCL.POST="
            "/tmp/xrt-hooks/post_place_hook.tcl",
            lines,
        )

    def test_hw_opt_out_removes_only_post_place_hook(self):
        enabled = self.vivado_lines()
        disabled = self.vivado_lines(disable_congestion_fail_fast=True)

        post_place = (
            "prop=run.impl_1.STEPS.PLACE_DESIGN.TCL.POST="
            "/tmp/xrt-hooks/post_place_hook.tcl"
        )
        self.assertNotIn(post_place, disabled)
        self.assertEqual([line for line in enabled if line != post_place], disabled)

    def test_hw_emu_never_registers_post_place_hook(self):
        for disabled in (False, True):
            lines = self.vivado_lines(
                target="hw_emu", disable_congestion_fail_fast=disabled
            )
            self.assertFalse(any("PLACE_DESIGN.TCL.POST" in line for line in lines))

    def test_mxu_checks_survive_disabled_congestion_gate(self):
        lines = self.vivado_lines(mxu_slr_floorplan=True,
                                 disable_congestion_fail_fast=True)
        self.assertTrue(any("STEPS.OPT_DESIGN.TCL.POST" in line for line in lines))
        self.assertTrue(any("PLACE_DESIGN.TCL.POST" in line for line in lines))

    def test_mxu_checks_are_hardware_only(self):
        lines = self.vivado_lines(target="hw_emu", mxu_slr_floorplan=True)
        self.assertFalse(any("STEPS.OPT_DESIGN.TCL.POST" in line for line in lines))
        self.assertFalse(any("PLACE_DESIGN.TCL.POST" in line for line in lines))

    def test_place_and_route_directives_are_hardware_only(self):
        for target in ("hw", "hw_emu"):
            with self.subTest(target=target):
                lines = self.vivado_lines(target=target, place_directive="SSI_SpreadSLLs",
                                          route_directive="AlternateCLBRouting")
                for step, directive in (("PLACE_DESIGN", "SSI_SpreadSLLs"),
                                        ("ROUTE_DESIGN", "AlternateCLBRouting")):
                    property_line = f"prop=run.impl_1.STEPS.{step}.ARGS.DIRECTIVE={directive}"
                    self.assertEqual(property_line in lines, target == "hw")
        self.assertFalse(any("ARGS.DIRECTIVE" in line for line in self.vivado_lines()))

    def test_active_configs_export_directives(self):
        for name in ("tcu_th32_c1_rev3", "th32_c1_tcu_naive_m32_tcol32",
                     "th32_c1_naive_m32_tcol32", "th32_c1_improve_m32_tcol32"):
            with self.subTest(config=name):
                result = subprocess.run(
                    ["bash", "-c", 'source "$1"; python3 -c '
                     "'import os; print(os.environ.get(\"PLACE_DESIGN_DIRECTIVE\", \"\")); "
                     "print(os.environ.get(\"ROUTE_DESIGN_DIRECTIVE\", \"\"))'", "fixture",
                     str(REPO_ROOT / "configs" / (name + ".sh"))],
                    cwd=BUILD_ROOT, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = {
                    "tcu_th32_c1_rev3": ["", ""],
                    "th32_c1_tcu_naive_m32_tcol32": ["SSI_SpreadSLLs", "Default"],
                    "th32_c1_naive_m32_tcol32": ["SSI_SpreadSLLs", "Default"],
                    "th32_c1_improve_m32_tcol32": ["SSI_SpreadLogic_high", "Default"],
                }[name]
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_makefile_tracks_and_validates_gate_setting(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            self.assertTrue((BUILD_ROOT / "config.mk").is_file(),
                            "Configure the build directory before running integration tests")
            # Exercise the real Makefile from the configured build tree. Use
            # Python only for removal of temporary stamp files in this fixture.
            test_makefile = Path(temp_dir) / "Makefile"
            test_makefile.write_text((XRT_DIR / "Makefile").read_text().replace(
                'rm -f $$tmp_file',
                'python3 -c "import os,sys; os.unlink(sys.argv[1])" $$tmp_file'))
            prefix = Path(temp_dir) / "gate"
            build_dir = Path(f"{prefix}_fixture_hw")
            generated_ini = build_dir / "xrt_backup" / "vitis.gen.ini"
            config_stamp = build_dir / ".config.stamp"
            backup_stamp = build_dir / "xrt_backup" / ".stamp"
            link_stamp = build_dir / "xrt_backup" / ".link_config.stamp"

            def run_make(setting=None, target=generated_ini, **overrides):
                command = [
                    "make",
                    "-f",
                    str(test_makefile),
                    str(target),
                    f"VORTEX_HOME={REPO_ROOT}",
                    f"PREFIX={prefix}",
                    "PLATFORM=fixture",
                    "DEVICE_PART=xcu55c-fsvh2892-2L-e",
                    "DEV_ARCH=",
                    "CPU_TYPE=",
                ]
                if setting is not None:
                    command.append(f"CONGESTION_FAIL_FAST={setting}")
                command.extend(f"{name}={value}" for name, value in overrides.items())
                return subprocess.run(
                    command,
                    cwd=BUILD_ROOT / "hw/syn/xilinx/xrt",
                    text=True,
                    capture_output=True,
                )

            enabled = run_make()
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            self.assertIn("PLACE_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertIn("INIT_DESIGN.TCL.PRE", generated_ini.read_text())
            self.assertEqual(
                (build_dir / "xrt_backup" / "pre_init_hook.tcl").read_text(),
                (XRT_DIR / "pre_init_hook.tcl").read_text(),
            )
            self.assertEqual("CONGESTION_FAIL_FAST=1 GEMM_MXU_SLR_FLOORPLAN=0 PLACE_DESIGN_DIRECTIVE= ROUTE_DESIGN_DIRECTIVE=\n", link_stamp.read_text())
            stable_mtimes = tuple(
                path.stat().st_mtime_ns
                for path in (config_stamp, backup_stamp, link_stamp, generated_ini)
            )

            unchanged = run_make()
            self.assertEqual(unchanged.returncode, 0, unchanged.stderr)
            self.assertEqual(
                stable_mtimes,
                tuple(
                    path.stat().st_mtime_ns
                    for path in (config_stamp, backup_stamp, link_stamp, generated_ini)
                ),
            )

            sources = build_dir / "sources.txt"
            xo = build_dir / "bin" / "vortex_afu.xo"
            xo.parent.mkdir(parents=True)
            sources.write_text("fixture\n")
            xo.write_text("fixture\n")
            xo_mtime = xo.stat().st_mtime_ns
            compile_side_mtimes = tuple(
                path.stat().st_mtime_ns for path in (config_stamp, backup_stamp)
            )

            disabled = run_make(0)
            self.assertEqual(disabled.returncode, 0, disabled.stderr)
            disabled_ini = generated_ini.read_text()
            self.assertNotIn("PLACE_DESIGN.TCL.POST", disabled_ini)
            self.assertIn("OPT_DESIGN.TCL.PRE", disabled_ini)
            self.assertIn("ROUTE_DESIGN.TCL.POST", disabled_ini)
            self.assertEqual("CONGESTION_FAIL_FAST=0 GEMM_MXU_SLR_FLOORPLAN=0 PLACE_DESIGN_DIRECTIVE= ROUTE_DESIGN_DIRECTIVE=\n", link_stamp.read_text())
            self.assertEqual(
                compile_side_mtimes,
                tuple(path.stat().st_mtime_ns for path in (config_stamp, backup_stamp)),
            )
            xo_check = run_make(0, xo, VIVADO="false")
            self.assertEqual(xo_check.returncode, 0, xo_check.stderr)
            self.assertEqual(xo_mtime, xo.stat().st_mtime_ns)

            reenabled = run_make()
            self.assertEqual(reenabled.returncode, 0, reenabled.stderr)
            self.assertIn("PLACE_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertEqual("CONGESTION_FAIL_FAST=1 GEMM_MXU_SLR_FLOORPLAN=0 PLACE_DESIGN_DIRECTIVE= ROUTE_DESIGN_DIRECTIVE=\n", link_stamp.read_text())
            self.assertEqual(xo_mtime, xo.stat().st_mtime_ns)

            selected = run_make(PLACE_DESIGN_DIRECTIVE="SSI_SpreadSLLs",
                                ROUTE_DESIGN_DIRECTIVE="AlternateCLBRouting")
            self.assertEqual(selected.returncode, 0, selected.stderr)
            self.assertIn("PLACE_DESIGN.ARGS.DIRECTIVE=SSI_SpreadSLLs", generated_ini.read_text())
            self.assertIn("ROUTE_DESIGN.ARGS.DIRECTIVE=AlternateCLBRouting", generated_ini.read_text())
            self.assertIn("PLACE_DESIGN_DIRECTIVE=SSI_SpreadSLLs", link_stamp.read_text())
            self.assertEqual(compile_side_mtimes, tuple(
                path.stat().st_mtime_ns for path in (config_stamp, backup_stamp)))
            selected_check = run_make(target=xo, VIVADO="false",
                                      PLACE_DESIGN_DIRECTIVE="SSI_SpreadSLLs",
                                      ROUTE_DESIGN_DIRECTIVE="AlternateCLBRouting")
            self.assertEqual(selected_check.returncode, 0, selected_check.stderr)
            self.assertEqual(xo_mtime, xo.stat().st_mtime_ns)
            selected_mtimes = tuple(path.stat().st_mtime_ns for path in (link_stamp, generated_ini))
            unchanged = run_make(PLACE_DESIGN_DIRECTIVE="SSI_SpreadSLLs",
                                 ROUTE_DESIGN_DIRECTIVE="AlternateCLBRouting")
            self.assertEqual(unchanged.returncode, 0, unchanged.stderr)
            self.assertEqual(selected_mtimes, tuple(
                path.stat().st_mtime_ns for path in (link_stamp, generated_ini)))
            changed = run_make(PLACE_DESIGN_DIRECTIVE="Explore", ROUTE_DESIGN_DIRECTIVE="Explore")
            self.assertEqual(changed.returncode, 0, changed.stderr)
            self.assertIn("PLACE_DESIGN.ARGS.DIRECTIVE=Explore", generated_ini.read_text())
            self.assertIn("ROUTE_DESIGN.ARGS.DIRECTIVE=Explore", generated_ini.read_text())
            cleared = run_make()
            self.assertEqual(cleared.returncode, 0, cleared.stderr)
            self.assertNotIn("ARGS.DIRECTIVE", generated_ini.read_text())
            for setting, value in (("PLACE_DESIGN_DIRECTIVE", "NotADirective"),
                                   ("ROUTE_DESIGN_DIRECTIVE", "NotADirective"),
                                   ("PLACE_DESIGN_DIRECTIVE", "Explore Default")):
                invalid_directive = run_make(**{setting: value})
                self.assertNotEqual(invalid_directive.returncode, 0)
                self.assertIn(setting, invalid_directive.stderr)

            invalid = run_make(2)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("CONGESTION_FAIL_FAST must be 0 or 1", invalid.stderr)

            missing_rtl = run_make(GEMM_MXU_SLR_FLOORPLAN=1)
            self.assertNotEqual(missing_rtl.returncode, 0)
            self.assertIn("requires -DGEMM_SLR_PIPELINE", missing_rtl.stderr)
            invalid_slr = run_make(GEMM_MXU_SLR_FLOORPLAN=2)
            self.assertNotEqual(invalid_slr.returncode, 0)
            self.assertIn("GEMM_MXU_SLR_FLOORPLAN must be 0 or 1", invalid_slr.stderr)
            enabled_slr = run_make(0, GEMM_MXU_SLR_FLOORPLAN=1,
                                   CONFIGS="-DGEMM_SLR_PIPELINE")
            self.assertEqual(enabled_slr.returncode, 0, enabled_slr.stderr)
            self.assertIn("STEPS.OPT_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertIn("PLACE_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertIn("GEMM_MXU_SLR_FLOORPLAN=1", link_stamp.read_text())
            self.assertTrue((build_dir / "xrt_backup" / "mxu_slr_floorplan.tcl").is_file())

            slr_off = run_make(0, GEMM_MXU_SLR_FLOORPLAN=0,
                               CONFIGS="-DGEMM_SLR_PIPELINE")
            self.assertEqual(slr_off.returncode, 0, slr_off.stderr)
            self.assertNotIn("STEPS.OPT_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertNotIn("PLACE_DESIGN.TCL.POST", generated_ini.read_text())


if __name__ == "__main__":
    unittest.main()
