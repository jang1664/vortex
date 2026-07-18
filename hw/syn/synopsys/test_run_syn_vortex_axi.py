#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("run_syn_vortex_axi.py")
SPEC = importlib.util.spec_from_file_location("run_syn_vortex_axi", SCRIPT)
SYN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYN)


class ConfigInputTest(unittest.TestCase):
    def _parse(self, *args):
        return SYN._build_parser().parse_args(args)

    def test_c1_through_c4_resolve_and_normalize(self):
        expected = {
            "C1": ("tcu_th16_c2.sh", "NUM_CORES=2"),
            "C2": ("naive_gemm_simd_th16_tcol32_hwexp_dcache.sh", "EXT_TCU_ENABLE"),
            "C3": ("naive_gemm_th16_tcol32_hwexp_dcache.sh", "GEMM_NAIVE"),
            "C4": ("improve_th16_tcol32_hwexp_dcache.sh", "TMEM_BANK_SIZE=32768"),
        }

        run_tags = []
        for alias, (filename, representative_define) in expected.items():
            with self.subTest(alias=alias):
                config_file, run_tag = SYN._resolve_config_input(
                    self._parse("--alias", alias)
                )
                self.assertEqual(filename, config_file.name)
                self.assertEqual(alias, run_tag)
                run_tags.append(run_tag)

                defines = SYN._make_dc_defines(
                    SYN._load_config_defines(config_file)
                )
                self.assertIn(representative_define, defines)
                self.assertIn("NUM_THREADS=16", defines)
                self.assertEqual(1, defines.count("FPU_FPNEW"))
                for incompatible in SYN.INCOMPATIBLE_CONFIG_DEFINES:
                    if incompatible not in {"FPU_FPNEW", "TCU_BHF"}:
                        self.assertNotIn(incompatible, defines)
                if "EXT_TCU_ENABLE" in defines:
                    self.assertEqual(1, defines.count("TCU_BHF"))
                else:
                    self.assertNotIn("TCU_BHF", defines)

        self.assertEqual(4, len(set(run_tags)))

    def test_direct_config_preserves_parameters_and_replaces_fpu(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_file = Path(tmpdir) / "custom config.sh"
            config_file.write_text(
                'CONFIGS="-DNUM_THREADS=32 -DNUM_CORES=4 '
                '-DVIVADO -DFPU_DSP -DFPU_FPNEW"\n'
                "export CONFIGS\n"
            )

            resolved, run_tag = SYN._resolve_config_input(
                self._parse("--config", str(config_file))
            )
            defines = SYN._make_dc_defines(SYN._load_config_defines(resolved))

            self.assertEqual(config_file.resolve(), resolved)
            self.assertEqual("custom_config", run_tag)
            self.assertIn("NUM_THREADS=32", defines)
            self.assertIn("NUM_CORES=4", defines)
            self.assertNotIn("VIVADO", defines)
            self.assertNotIn("FPU_DSP", defines)
            self.assertEqual(1, defines.count("FPU_FPNEW"))

    def test_input_is_required_and_mutually_exclusive(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                self._parse()
            with self.assertRaises(SystemExit):
                self._parse("--alias", "C1", "--config", "configs/base_t8.sh")

    def test_unknown_alias_fails_before_synthesis(self):
        with self.assertRaisesRegex(SystemExit, "Unknown FPGA config alias"):
            SYN._resolve_config_input(self._parse("--alias", "not-an-alias"))

    def test_alias_without_config_fails_before_synthesis(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            alias_map = Path(tmpdir) / "aliases.yaml"
            alias_map.write_text("aliases:\n  no_config:\n    path: /tmp/bin\n")
            args = self._parse(
                "--alias", "no_config", "--alias-map", str(alias_map)
            )
            with self.assertRaisesRegex(SystemExit, "does not define a config file"):
                SYN._resolve_config_input(args)

    def test_invalid_configs_token_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_file = Path(tmpdir) / "invalid.sh"
            config_file.write_text('CONFIGS="-DNUM_THREADS=16 unexpected"\n')
            with self.assertRaisesRegex(SystemExit, "Unsupported tokens"):
                SYN._load_config_defines(config_file)

    def test_dma_sram_specs_cover_supported_slot_depths(self):
        expected = {
            f"cmos28lpp_rf2_hd_{depth}x{width}m1"
            for depth in (4, 8, 16)
            for width in (160, 64)
        }
        dma_specs = {
            spec
            for spec in SYN.SRAM_SPECS
            if spec in expected
        }

        self.assertEqual(expected, dma_specs)
        self.assertEqual(len(SYN.SRAM_SPECS), len(set(SYN.SRAM_SPECS)))


if __name__ == "__main__":
    unittest.main()
