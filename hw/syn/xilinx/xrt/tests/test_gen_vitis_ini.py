#!/usr/bin/env python3

import importlib.util
import subprocess
import tempfile
import types
import unittest
from pathlib import Path


XRT_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = XRT_DIR.parents[3]


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
        "ultrathreads": False,
    }
    values.update(overrides)
    return types.SimpleNamespace(**values)


class GenVitisIniTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generator = load_generator()

    def vivado_lines(self, **overrides):
        return self.generator.build_ini(make_args(**overrides))["vivado"]

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

    def test_ultrathreads_adds_place_and_route_options_for_hw(self):
        lines = self.vivado_lines(ultrathreads=True)
        self.assertIn(
            "prop=run.impl_1.{STEPS.PLACE_DESIGN.ARGS.MORE OPTIONS}="
            "{-ultrathreads}",
            lines,
        )
        self.assertIn(
            "prop=run.impl_1.{STEPS.ROUTE_DESIGN.ARGS.MORE OPTIONS}="
            "{-ultrathreads}",
            lines,
        )

    def test_ultrathreads_is_not_added_for_hw_emu(self):
        lines = self.vivado_lines(target="hw_emu", ultrathreads=True)
        self.assertFalse(any("-ultrathreads" in line for line in lines))

    def test_makefile_tracks_and_validates_gate_setting(self):
        with tempfile.TemporaryDirectory() as temp_dir:
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
                    "Makefile",
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
                    cwd=XRT_DIR,
                    text=True,
                    capture_output=True,
                )

            enabled = run_make()
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            self.assertIn("PLACE_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertEqual(
                "FAST_MODE=0 VPP_OPTIMIZE=3 CONGESTION_FAIL_FAST=1\n",
                link_stamp.read_text(),
            )
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
            self.assertEqual(
                "FAST_MODE=0 VPP_OPTIMIZE=3 CONGESTION_FAIL_FAST=0\n",
                link_stamp.read_text(),
            )
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
            self.assertEqual(
                "FAST_MODE=0 VPP_OPTIMIZE=3 CONGESTION_FAIL_FAST=1\n",
                link_stamp.read_text(),
            )
            self.assertEqual(xo_mtime, xo.stat().st_mtime_ns)

            fast = run_make(0, FAST_MODE=1)
            self.assertEqual(fast.returncode, 0, fast.stderr)
            fast_ini = generated_ini.read_text()
            self.assertIn("PLACE_DESIGN.TCL.POST", fast_ini)
            self.assertIn(
                "STEPS.PLACE_DESIGN.ARGS.MORE OPTIONS}={-ultrathreads}",
                fast_ini,
            )
            self.assertIn(
                "STEPS.ROUTE_DESIGN.ARGS.MORE OPTIONS}={-ultrathreads}",
                fast_ini,
            )
            self.assertEqual(
                "FAST_MODE=1 VPP_OPTIMIZE=0 CONGESTION_FAIL_FAST=1\n",
                link_stamp.read_text(),
            )
            self.assertEqual(xo_mtime, xo.stat().st_mtime_ns)

            invalid = run_make(2)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("CONGESTION_FAIL_FAST must be 0 or 1", invalid.stderr)

            invalid_fast = run_make(FAST_MODE=2)
            self.assertNotEqual(invalid_fast.returncode, 0)
            self.assertIn("FAST_MODE must be 0 or 1", invalid_fast.stderr)


if __name__ == "__main__":
    unittest.main()
