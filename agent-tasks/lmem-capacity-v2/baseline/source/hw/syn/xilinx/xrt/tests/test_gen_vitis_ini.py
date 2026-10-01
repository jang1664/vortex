#!/usr/bin/env python3

import importlib.util
import os
import re
import shlex
import subprocess
import tempfile
import types
import unittest
from pathlib import Path


XRT_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = XRT_DIR.parents[3]
BUILD_XRT_DIR = Path(os.environ.get(
    "XRT_TEST_BUILD_DIR", REPO_ROOT / "build" / "hw/syn/xilinx/xrt"
))

# (threads, MXU dimension, physical TMEM count, HBM/DMA count).
# 32B TMEM words are paired behind one 64B HBM/DMA channel.
TIMING_PROFILES = [(16, 16, 8, 4), (16, 16, 16, 8)] + [
    (threads, 32, count, count) for threads in (16, 32) for count in (4, 8)
]


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
        "gemm_slr_floorplan": False,
        "ultrathreads": False,
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

    def test_slr_checks_survive_congestion_opt_out(self):
        lines = self.vivado_lines(
            disable_congestion_fail_fast=True, gemm_slr_floorplan=True
        )
        self.assertTrue(any("PLACE_DESIGN.TCL.POST" in line for line in lines))

    def test_post_opt_refresh_only_for_hardware_slr_floorplan(self):
        hook = "prop=run.impl_1.STEPS.OPT_DESIGN.TCL.POST=/tmp/xrt-hooks/post_opt_hook.tcl"
        for target in ("hw", "hw_emu"):
            for enabled in (False, True):
                for congestion_disabled in (False, True):
                    lines = self.vivado_lines(
                        target=target, gemm_slr_floorplan=enabled,
                        disable_congestion_fail_fast=congestion_disabled,
                    )
                    self.assertEqual(hook in lines, target == "hw" and enabled)

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

    def test_hw_adds_place_and_route_directives(self):
        lines = self.vivado_lines(
            place_directive="Explore",
            route_directive="AlternateCLBRouting",
        )
        self.assertIn(
            "prop=run.impl_1.STEPS.PLACE_DESIGN.ARGS.DIRECTIVE="
            "Explore",
            lines,
        )
        self.assertIn(
            "prop=run.impl_1.STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE="
            "AlternateCLBRouting",
            lines,
        )

    def test_implementation_directives_are_not_added_for_hw_emu(self):
        lines = self.vivado_lines(
            target="hw_emu",
            place_directive="Explore",
            route_directive="AlternateCLBRouting",
        )
        self.assertFalse(any("PLACE_DESIGN.ARGS.DIRECTIVE" in line for line in lines))
        self.assertFalse(any("ROUTE_DESIGN.ARGS.DIRECTIVE" in line for line in lines))

    def test_hbm4_tmem8_spread_experiment_configs(self):
        """Memory experiments differ only in mapping and reach the real ini generator."""
        platform = "xilinx_u55c_gen3x16_xdma_3_202210_1"
        configs_without_mapping = []
        with tempfile.TemporaryDirectory() as temp_dir:
            for experiment, use_uram in (("uram", 1), ("bram", 0), ("all_bram", 0)):
                config = REPO_ROOT / "configs" / (
                    f"improve_th32_tcol32_m32_bigmem_hbm4_tmem8_{experiment}.sh"
                )
                sourced = subprocess.run(
                    ["bash", "-eu", "-c", 'source "$1"; '
                     'printf "%s\\n" "$CONFIGS" "$GEMM_SLR_FLOORPLAN" '
                     '"$PLACE_DESIGN_DIRECTIVE" "$ROUTE_DESIGN_DIRECTIVE" '
                     '"$IMPL_ULTRATHREADS" "$FAST_MODE" "$CONGESTION_FAIL_FAST"',
                     "config-fixture", str(config)],
                    cwd=temp_dir, text=True, capture_output=True, check=True,
                )
                configs, *settings = sourced.stdout.strip().splitlines()
                self.assertEqual(settings, ["1", "SSI_SpreadSLLs", "AlternateCLBRouting",
                                            "0", "0", "0"])
                defines = shlex.split(configs)
                self.assertEqual([d for d in defines if d.startswith("-DTMEM_USE_URAM")],
                                 [f"-DTMEM_USE_URAM={use_uram}"])
                for name in ("GEMM_ACC_USE_URAM", "LMEM_USE_URAM"):
                    self.assertEqual([d for d in defines if d.startswith(f"-D{name}")],
                                     [f"-D{name}=0"] if experiment == "all_bram" else [])
                for define in ("-DGEMM_SLR_PIPELINE", "-DGEMM_TIMING_CUTS=1",
                               "-DNUM_THREADS=32", "-DNUM_TMEM_BANKS=8",
                               "-DNUM_HBM_PORTS=4", "-DNUM_DMA_CHANNELS=4",
                               "-DTMEM_BANK_SIZE=65536", "-DMXU_WLOAD_NUM=4"):
                    self.assertIn(define, defines)
                configs_without_mapping.append(
                    [d for d in defines if not d.startswith(("-DTMEM_USE_URAM=",
                        "-DGEMM_ACC_USE_URAM=", "-DLMEM_USE_URAM="))])
                prefix = Path(temp_dir) / experiment
                ini = Path(f"{prefix}_{platform}_hw/xrt_backup/vitis.gen.ini")
                generated = subprocess.run(
                    ["make", "-f", str(XRT_DIR / "Makefile"), str(ini),
                     f"VORTEX_HOME={REPO_ROOT}", f"PREFIX={prefix}",
                     f"PLATFORM={platform}", "DEVICE_PART=xcu55c-fsvh2892-2L-e",
                     "DEV_ARCH=", "CPU_TYPE=", f"CONFIGS={configs}",
                     "CLOCK_FREQ_HZ=100", "GEMM_SLR_FLOORPLAN=1",
                     "PLACE_DESIGN_DIRECTIVE=SSI_SpreadSLLs",
                     "ROUTE_DESIGN_DIRECTIVE=AlternateCLBRouting",
                     "IMPL_ULTRATHREADS=0", "FAST_MODE=0", "CONGESTION_FAIL_FAST=0"],
                    cwd=BUILD_XRT_DIR, text=True, capture_output=True,
                )
                self.assertEqual(generated.returncode, 0, generated.stdout + generated.stderr)
                lines = ini.read_text().splitlines()
                for line in ("kernel_frequency=0:100",
                             "prop=run.impl_1.STEPS.PLACE_DESIGN.ARGS.DIRECTIVE=SSI_SpreadSLLs",
                             "prop=run.impl_1.STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE=AlternateCLBRouting"):
                    self.assertIn(line, lines)
                for hook in ("INIT_DESIGN.TCL.POST", "OPT_DESIGN.TCL.POST", "PLACE_DESIGN.TCL.POST"):
                    self.assertTrue(any(hook in line for line in lines), hook)
                self.assertEqual([line for line in lines if line.startswith("sp=")],
                                 [f"sp=vortex_afu_1.m_axi_mem_{p}:HBM[{p * 8}:{p * 8 + 7}]"
                                  for p in range(4)])
                self.assertFalse(any("-subdirective" in line or "-ultrathreads" in line
                                     for line in lines))
                stamp = (ini.parent / ".link_config.stamp").read_text()
                self.assertIn("PLACE_DESIGN_DIRECTIVE=SSI_SpreadSLLs", stamp)
        for defines in configs_without_mapping[1:]:
            self.assertEqual(configs_without_mapping[0], defines)

    def test_floorplan_width_formula_matches_rtl(self):
        # The hook intentionally mirrors fixed FP16 definitions, not a
        # second configurable format. Fail this test if that contract changes.
        config = (REPO_ROOT / "hw/rtl/VX_config.vh").read_text()
        for name in ("IFP_WIDTH", "SCALE_WIDTH"):
            self.assertRegex(config, rf"(?m)^`define {name}\s+16\s")
        self.assertRegex(config, r"(?m)^`define MXU_ROW\s+32\s")
        self.assertRegex(config, r"(?m)^`define MEM_BLOCK_SIZE\s+64\s")
        self.assertRegex(config, r"`define GEMM_INPUT_DATA_SIZE\s+\(\(`IFP_WIDTH/8\)\*`MXU_ROW\)")
        node = (REPO_ROOT / "hw/rtl/core/gemm/VX_gemm_node.sv").read_text()
        self.assertRegex(node, r"TMEM_PHYSICAL_DATA_SIZE\s*=\s*`GEMM_INPUT_DATA_SIZE;")
        self.assertRegex(node, r"\.HBM_DMA_DATA_SIZE\s*\(\s*`MEM_BLOCK_SIZE\s*\)")

    def test_naive_profile_exports_backend_and_geometry(self):
        profile = REPO_ROOT / "configs/naive_th16_tcol16_m16_L16_bigmem_all_bram.sh"
        sourced = subprocess.run(
            ["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"', "fixture", str(profile)],
            check=True, text=True, capture_output=True,
        )
        fields = ("BACKEND", "MXU_ROW", "MXU_COL", "MXU_COL_TILE",
                  "LMEM_PORTS", "LMEM_BANKS", "LMEM_LOG_SIZE", "LSU_BLOCKS")
        recipe = "show_naive:\n\t@printf '%s\\n' " + " ".join(
            f'"$$VORTEX_GEMM_{field}"' for field in fields
        ) + "\n"
        command = ["make", "--no-print-directory", "-f", str(XRT_DIR / "Makefile"),
                   "-f", "-", "show_naive", f"VORTEX_HOME={REPO_ROOT}",
                   "PLATFORM=fixture", "DEVICE_PART=xcu55c-fsvh2892-2L-e",
                   "DEV_ARCH=", "CPU_TYPE=", "GEMM_SLR_FLOORPLAN=1", "FAST_MODE=0"]
        result = subprocess.run(command + [f"CONFIGS={sourced.stdout}"], input=recipe,
                                cwd=BUILD_XRT_DIR, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["naive", "16", "16", "16", "16", "16", "20", "1"])
        env = os.environ.copy()
        env.update({f"VORTEX_GEMM_{field}": value
                    for field, value in zip(fields, result.stdout.splitlines())})
        checked = subprocess.run(
            ["tclsh"], input='set ::vortex_slr_definitions_only 1\nsource floorplan.tcl\n'
            'if {[catch {::vortex::slr::geometry} g]} {puts stderr $g; exit 1}\n',
            cwd=XRT_DIR, env=env, text=True, capture_output=True,
        )
        self.assertEqual(checked.returncode, 0, checked.stderr)
        invalid = subprocess.run(
            command + ["CONFIGS=" + sourced.stdout.replace("-DGEMM_SLR_PIPELINE", "")],
            input=recipe, cwd=BUILD_XRT_DIR, text=True, capture_output=True,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("requires -DGEMM_SLR_PIPELINE", invalid.stderr)

    def test_makefile_exports_selected_slr_geometry(self):
        def geometry(configs):
            result = subprocess.run(
                ["make", "--no-print-directory", "-f", str(XRT_DIR / "Makefile"),
                 "-f", "-", "show_slr_geometry", f"VORTEX_HOME={REPO_ROOT}",
                 "PLATFORM=fixture", "DEVICE_PART=xcu55c-fsvh2892-2L-e",
                 "DEV_ARCH=", "CPU_TYPE=", "GEMM_SLR_FLOORPLAN=1", "FAST_MODE=0",
                 f"CONFIGS={configs}"],
                input="show_slr_geometry:\n\t@printf '%s|%s|%s|%s|%s|%s\\n' "
                      '"$$VORTEX_GEMM_TMEM_BANKS" "$$VORTEX_GEMM_DMA_CHANNELS" '
                      '"$$VORTEX_GEMM_HBM_PORTS" "$$VORTEX_GEMM_MXU_COL" '
                      '"$$VORTEX_GEMM_MXU_ROW" "$$VORTEX_GEMM_HBM_DATA_BYTES"\n',
                cwd=BUILD_XRT_DIR, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

        for threads, mxu, count, channels in TIMING_PROFILES:
            config = REPO_ROOT / "configs" / f"improve_th{threads}_tcol{mxu}_m{mxu}_t{count}_bigmem.sh"
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; printf "%s\\n%s\\n" "$CONFIGS" "$GEMM_SLR_FLOORPLAN"',
                 "config-fixture", str(config)], text=True, capture_output=True, check=True,
            )
            configs, floorplan = result.stdout.strip().splitlines()
            defines = shlex.split(configs)
            self.assertEqual(floorplan, "1")
            expected = {
                "NUM_THREADS": threads, "NUM_TMEM_BANKS": count,
                "NUM_DMA_CHANNELS": channels, "NUM_HBM_PORTS": channels,
                "TMEM_BANK_SIZE": 524288 // count, "MXU_WLOAD_NUM": 4,
                "MXU_ROW": mxu, "MXU_COL": mxu, "MXU_COL_TILE": mxu,
                "GEMM_TIMING_CUTS": 1,
            }
            for name, value in expected.items():
                self.assertEqual([x for x in defines if re.match(rf"-D{name}(?:=|$)", x)],
                                 [f"-D{name}={value}"])
            self.assertIn("-DGEMM_SLR_PIPELINE", defines)
            exported = geometry(configs)
            self.assertEqual(exported, f"{count}|{channels}|{channels}|{mxu}|{mxu}|64")
            # Execute the actual Tcl validator, not only the ini generator.
            # Tcl on stdin can return zero after an error: catch and exit.
            env = os.environ.copy()
            for field, value in zip(
                ("TMEM_BANKS", "DMA_CHANNELS", "HBM_PORTS", "MXU_COL", "MXU_ROW", "HBM_DATA_BYTES"),
                exported.split("|"),
            ):
                env[f"VORTEX_GEMM_{field}"] = value
            checked = subprocess.run(
                ["tclsh"], input='set ::vortex_slr_definitions_only 1\n'
                'source {floorplan.tcl}\n'
                'if {[catch {::vortex::slr::geometry} g]} {puts stderr $g; exit 1}\n'
                'puts "ROUTE=[dict get $g ROUTE] TMEM_BYTES=[dict get $g TMEM_DATA_BYTES]"\n',
                cwd=XRT_DIR, env=env, text=True, capture_output=True,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn(f"ROUTE={'pair' if mxu == 16 else 'direct'} TMEM_BYTES={2 * mxu}",
                          checked.stdout)
            self.assertEqual(count * (2 * mxu), channels * 64)

        legacy = "-DGEMM_SLR_PIPELINE -DNUM_TMEM_BANKS=16 -DNUM_DMA_CHANNELS=8 -DMXU_COL=16"
        self.assertEqual(geometry(legacy), "16|8|8|16|32|64")
        # Malformed explicit values must reach the strict Tcl validator,
        # rather than silently selecting the absent-define default.
        self.assertEqual(geometry(legacy + " -DNUM_HBM_PORTS="), "16|8||16|32|64")
        self.assertEqual(geometry(legacy + " -DNUM_HBM_PORTS=4 -DNUM_HBM_PORTS=8"),
                         "16|8|invalid-duplicate-NUM_HBM_PORTS|16|32|64")
        self.assertEqual(geometry(legacy + " -DNUM_HBM_PORTS= -DNUM_HBM_PORTS=8"),
                         "16|8|invalid-duplicate-NUM_HBM_PORTS|16|32|64")
        self.assertEqual(geometry(legacy + " -DNUM_HBM_PORTS"), "16|8|-DNUM_HBM_PORTS|16|32|64")
        for define, default, offset in (("MXU_ROW", "32", 4), ("MEM_BLOCK_SIZE", "64", 5)):
            self.assertEqual(geometry(legacy).split("|")[offset], default)
            self.assertEqual(geometry(legacy + f" -D{define}=").split("|")[offset], "")
            self.assertEqual(geometry(legacy + f" -D{define}=16 -D{define}=32").split("|")[offset],
                             f"invalid-duplicate-{define}")

    def test_u55c_connectivity_matches_timing_profiles(self):
        platform = "xilinx_u55c_gen3x16_xdma_3_202210_1"
        with tempfile.TemporaryDirectory() as temp_dir:
            for threads, mxu, count, channels in TIMING_PROFILES:
                config = REPO_ROOT / "configs" / f"improve_th{threads}_tcol{mxu}_m{mxu}_t{count}_bigmem.sh"
                sourced = subprocess.run(
                    ["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"',
                     "config-fixture", str(config)], text=True, capture_output=True, check=True,
                )
                prefix = Path(temp_dir) / f"th{threads}_m{mxu}_t{count}"
                generated_ini = Path(f"{prefix}_{platform}_hw/xrt_backup/vitis.gen.ini")
                command = [
                    "make", "-f", str(XRT_DIR / "Makefile"), str(generated_ini),
                    f"VORTEX_HOME={REPO_ROOT}", f"PREFIX={prefix}",
                    f"PLATFORM={platform}", "DEVICE_PART=xcu55c-fsvh2892-2L-e",
                    "DEV_ARCH=", "CPU_TYPE=", f"CONFIGS={sourced.stdout}",
                    "GEMM_SLR_FLOORPLAN=1", "CONGESTION_FAIL_FAST=0", "FAST_MODE=0",
                    "PLACE_DESIGN_DIRECTIVE=Explore", "ROUTE_DESIGN_DIRECTIVE=AlternateCLBRouting",
                    "IMPL_ULTRATHREADS=0",
                ]
                result = subprocess.run(command, cwd=BUILD_XRT_DIR, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                lines = generated_ini.read_text().splitlines()
                actual = [line for line in lines if line.startswith("sp=")]
                span = 32 // channels
                expected = [f"sp=vortex_afu_1.m_axi_mem_{port}:HBM[{port * span}:{(port + 1) * span - 1}]"
                            for port in range(channels)]
                self.assertEqual(actual, expected)
                for hook in ("INIT_DESIGN.TCL.POST", "OPT_DESIGN.TCL.POST", "PLACE_DESIGN.TCL.POST"):
                    self.assertTrue(any(hook in line for line in lines), hook)
                self.assertFalse(any("-subdirective" in line for line in lines))
                self.assertFalse(any("-ultrathreads" in line for line in lines))
                self.assertEqual((generated_ini.parent / "platforms.mk").read_bytes(),
                                 (XRT_DIR / "platforms.mk").read_bytes())
            # The last profile is TH32/t8. Verify absent-only default and
            # malformed/unsupported explicit values on the real U55C branch.
            config_index = next(i for i, value in enumerate(command) if value.startswith("CONFIGS="))
            legacy = sourced.stdout.replace(" -DNUM_HBM_PORTS=8", "")
            command[config_index] = f"CONFIGS={legacy}"
            result = subprocess.run(command, cwd=BUILD_XRT_DIR, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual([line for line in generated_ini.read_text().splitlines() if line.startswith("sp=")],
                             expected)
            for invalid in (" -DNUM_HBM_PORTS=3", " -DNUM_HBM_PORTS=", " -DNUM_HBM_PORTS",
                            " -DNUM_HBM_PORTS=4 -DNUM_HBM_PORTS=8",
                            " -DNUM_HBM_PORTS= -DNUM_HBM_PORTS=8"):
                command[config_index] = f"CONFIGS={legacy}{invalid}"
                result = subprocess.run(command, cwd=BUILD_XRT_DIR, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("U55C connectivity requires NUM_HBM_PORTS=4 or 8", result.stderr)

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
                    str(XRT_DIR / "Makefile"),
                    str(target),
                    f"VORTEX_HOME={REPO_ROOT}",
                    f"PREFIX={prefix}",
                    "PLATFORM=fixture",
                    "DEVICE_PART=xcu55c-fsvh2892-2L-e",
                    "DEV_ARCH=",
                    "CPU_TYPE=",
                    "CONFIGS=",
                    "GEMM_SLR_FLOORPLAN=0",
                    # The caller sources a real config; isolate this fixture's
                    # default fingerprint from its exported QoR directives.
                    "FAST_MODE=0",
                    "PLACE_DESIGN_DIRECTIVE=",
                    "ROUTE_DESIGN_DIRECTIVE=",
                    "IMPL_ULTRATHREADS=0",
                ]
                if setting is not None:
                    command.append(f"CONGESTION_FAIL_FAST={setting}")
                command.extend(f"{name}={value}" for name, value in overrides.items())
                # Exercise the Makefile's absent-setting default even when the
                # sourced exploration config exports CONGESTION_FAIL_FAST=0.
                fixture_env = os.environ.copy()
                fixture_env.pop("CONGESTION_FAIL_FAST", None)
                return subprocess.run(
                    command,
                    cwd=BUILD_XRT_DIR,
                    env=fixture_env,
                    text=True,
                    capture_output=True,
                )

            enabled = run_make()
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            self.assertIn("PLACE_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertEqual(
                "FAST_MODE=0 VPP_OPTIMIZE=3 CONGESTION_FAIL_FAST=1 "
                "GEMM_SLR_FLOORPLAN=0 PLACE_DESIGN_DIRECTIVE= "
                "ROUTE_DESIGN_DIRECTIVE= IMPL_ULTRATHREADS=0\n",
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
                "FAST_MODE=0 VPP_OPTIMIZE=3 CONGESTION_FAIL_FAST=0 "
                "GEMM_SLR_FLOORPLAN=0 PLACE_DESIGN_DIRECTIVE= "
                "ROUTE_DESIGN_DIRECTIVE= IMPL_ULTRATHREADS=0\n",
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
                "FAST_MODE=0 VPP_OPTIMIZE=3 CONGESTION_FAIL_FAST=1 "
                "GEMM_SLR_FLOORPLAN=0 PLACE_DESIGN_DIRECTIVE= "
                "ROUTE_DESIGN_DIRECTIVE= IMPL_ULTRATHREADS=0\n",
                link_stamp.read_text(),
            )

            qor = run_make(
                0,
                PLACE_DESIGN_DIRECTIVE="Explore",
                ROUTE_DESIGN_DIRECTIVE="AlternateCLBRouting",
                IMPL_ULTRATHREADS=0,
            )
            self.assertEqual(qor.returncode, 0, qor.stderr)
            qor_ini = generated_ini.read_text()
            self.assertIn(
                "STEPS.PLACE_DESIGN.ARGS.DIRECTIVE=Explore",
                qor_ini,
            )
            self.assertIn(
                "STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE=AlternateCLBRouting",
                qor_ini,
            )
            self.assertNotIn("-ultrathreads", qor_ini)
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
                "FAST_MODE=1 VPP_OPTIMIZE=0 CONGESTION_FAIL_FAST=1 "
                "GEMM_SLR_FLOORPLAN=0 PLACE_DESIGN_DIRECTIVE= "
                "ROUTE_DESIGN_DIRECTIVE= IMPL_ULTRATHREADS=1\n",
                link_stamp.read_text(),
            )
            self.assertEqual(xo_mtime, xo.stat().st_mtime_ns)

            invalid = run_make(2)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("CONGESTION_FAIL_FAST must be 0 or 1", invalid.stderr)

            invalid_fast = run_make(FAST_MODE=2)
            self.assertNotEqual(invalid_fast.returncode, 0)
            self.assertIn("FAST_MODE must be 0 or 1", invalid_fast.stderr)

            missing_pipeline = run_make(GEMM_SLR_FLOORPLAN=1)
            self.assertNotEqual(missing_pipeline.returncode, 0)
            self.assertIn("requires -DGEMM_SLR_PIPELINE", missing_pipeline.stderr)

            slr = run_make(0, GEMM_SLR_FLOORPLAN=1, CONFIGS="-DGEMM_SLR_PIPELINE")
            self.assertEqual(slr.returncode, 0, slr.stderr)
            self.assertIn("PLACE_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertIn("OPT_DESIGN.TCL.POST", generated_ini.read_text())
            self.assertEqual(
                (generated_ini.parent / "post_opt_hook.tcl").read_text(),
                (XRT_DIR / "post_opt_hook.tcl").read_text(),
            )
            self.assertIn("GEMM_SLR_FLOORPLAN=1", link_stamp.read_text())

            invalid_route = run_make(ROUTE_DESIGN_DIRECTIVE="NotADirective")
            self.assertNotEqual(invalid_route.returncode, 0)
            self.assertIn("unsupported ROUTE_DESIGN_DIRECTIVE", invalid_route.stderr)

            invalid_place = run_make(PLACE_DESIGN_DIRECTIVE="NotADirective")
            self.assertNotEqual(invalid_place.returncode, 0)
            self.assertIn("unsupported PLACE_DESIGN_DIRECTIVE", invalid_place.stderr)

            invalid_ultrathreads = run_make(
                IMPL_ULTRATHREADS=1,
                PLACE_DESIGN_DIRECTIVE="Explore",
            )
            self.assertNotEqual(invalid_ultrathreads.returncode, 0)
            self.assertIn(
                "IMPL_ULTRATHREADS=1 cannot be combined",
                invalid_ultrathreads.stderr,
            )


if __name__ == "__main__":
    unittest.main()
