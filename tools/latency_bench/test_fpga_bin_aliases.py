from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.latency_bench import runner


class FpgaBinAliasTest(unittest.TestCase):
    def test_resolves_registered_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()
            old_aliases = dict(runner.FPGA_BIN_ALIASES)
            try:
                runner.FPGA_BIN_ALIASES.clear()
                runner.FPGA_BIN_ALIASES["test_alias"] = str(bin_dir)

                self.assertEqual(bin_dir.resolve(), runner.resolve_fpga_bin("test_alias"))
            finally:
                runner.FPGA_BIN_ALIASES.clear()
                runner.FPGA_BIN_ALIASES.update(old_aliases)

    def test_alias_can_carry_compile_configs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()
            old_aliases = dict(runner.FPGA_BIN_ALIASES)
            try:
                runner.FPGA_BIN_ALIASES.clear()
                runner.FPGA_BIN_ALIASES["test_alias"] = runner.FpgaBinAlias(
                    path=str(bin_dir),
                    configs_extra=("-DXRT_MEM_MAP=legacy",),
                )

                config = runner.resolve_fpga_bin_config("test_alias")

                self.assertEqual(bin_dir.resolve(), config.path)
                self.assertEqual(("-DXRT_MEM_MAP=legacy",), config.configs_extra)
            finally:
                runner.FPGA_BIN_ALIASES.clear()
                runner.FPGA_BIN_ALIASES.update(old_aliases)

    def test_cli_xrt_mem_map_overrides_alias_compile_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()
            old_aliases = dict(runner.FPGA_BIN_ALIASES)
            try:
                runner.FPGA_BIN_ALIASES.clear()
                runner.FPGA_BIN_ALIASES["remap_alias"] = runner.FpgaBinAlias(
                    path=str(bin_dir),
                    configs_extra=("-DXRT_MEM_MAP=remap", "-DBANK_INTERLEAVE"),
                )

                config = runner.resolve_fpga_bin_config("remap_alias", xrt_mem_map="legacy")

                self.assertEqual(bin_dir.resolve(), config.path)
                self.assertIn("-DXRT_MEM_MAP=legacy", config.configs_extra)
                self.assertIn("-DBANK_INTERLEAVE", config.configs_extra)
                self.assertNotIn("-DXRT_MEM_MAP=remap", config.configs_extra)
            finally:
                runner.FPGA_BIN_ALIASES.clear()
                runner.FPGA_BIN_ALIASES.update(old_aliases)

    def test_regular_path_still_works(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()

            self.assertEqual(bin_dir.resolve(), runner.resolve_fpga_bin(str(bin_dir)))

    def test_built_in_improve_alias_enables_bank_interleave(self) -> None:
        config = runner.resolve_fpga_bin_config("improve_tcol1")

        self.assertIn("-DBANK_INTERLEAVE", config.configs_extra)
        self.assertIn("-DXRT_MEM_MAP=remap", config.configs_extra)

    def test_built_in_legacy_alias_does_not_enable_bank_interleave(self) -> None:
        config = runner.resolve_fpga_bin_config("naive")

        self.assertNotIn("-DBANK_INTERLEAVE", config.configs_extra)
        self.assertIn("-DXRT_MEM_MAP=legacy", config.configs_extra)


if __name__ == "__main__":
    unittest.main()
