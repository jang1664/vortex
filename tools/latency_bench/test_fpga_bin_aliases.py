from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench import runner
from tools.latency_bench.fpga_bins import (
    FPGA_BIN_ALIAS_MAP_ENV,
    FpgaBinAlias,
    load_fpga_bin_aliases,
    resolve_fpga_bin_config,
)


class FpgaBinAliasTest(unittest.TestCase):
    def _write_alias_map(self, path: Path, bin_dir: Path) -> None:
        path.write_text(
            f"""
aliases:
  test_alias:
    path: {bin_dir}
    configs_extra:
      - -DXRT_MEM_MAP=remap
      - -DBANK_INTERLEAVE
""".lstrip()
        )

    def test_loads_aliases_from_yaml_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, bin_dir)

            aliases = load_fpga_bin_aliases(alias_map)

            self.assertEqual(
                FpgaBinAlias(
                    path=str(bin_dir),
                    configs_extra=("-DXRT_MEM_MAP=remap", "-DBANK_INTERLEAVE"),
                ),
                aliases["test_alias"],
            )

    def test_resolves_alias_from_yaml_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, bin_dir)

            config = resolve_fpga_bin_config("test_alias", alias_map_path=alias_map)

            self.assertEqual(bin_dir.resolve(), config.path)
            self.assertEqual(("-DXRT_MEM_MAP=remap", "-DBANK_INTERLEAVE"), config.configs_extra)

    def test_env_var_selects_alias_map(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, bin_dir)
            old_value = os.environ.get(FPGA_BIN_ALIAS_MAP_ENV)
            try:
                os.environ[FPGA_BIN_ALIAS_MAP_ENV] = str(alias_map)

                config = runner.resolve_fpga_bin_config("test_alias")

                self.assertEqual(bin_dir.resolve(), config.path)
            finally:
                if old_value is None:
                    os.environ.pop(FPGA_BIN_ALIAS_MAP_ENV, None)
                else:
                    os.environ[FPGA_BIN_ALIAS_MAP_ENV] = old_value

    def test_cli_xrt_mem_map_overrides_yaml_alias_compile_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, bin_dir)

            config = resolve_fpga_bin_config("test_alias", xrt_mem_map="legacy", alias_map_path=alias_map)

            self.assertEqual(bin_dir.resolve(), config.path)
            self.assertIn("-DXRT_MEM_MAP=legacy", config.configs_extra)
            self.assertIn("-DBANK_INTERLEAVE", config.configs_extra)
            self.assertNotIn("-DXRT_MEM_MAP=remap", config.configs_extra)

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

    def test_ci_resolver_script_reads_yaml_alias_map(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "fpga_bin"
            bin_dir.mkdir()
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, bin_dir)

            proc = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).resolve().parents[2] / "ci" / "resolve_fpga_bin_alias.py"),
                    "--alias-map",
                    str(alias_map),
                    "--xrt-mem-map",
                    "legacy",
                    "test_alias",
                ],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )

            self.assertEqual(
                [str(bin_dir.resolve()), "-DXRT_MEM_MAP=legacy -DBANK_INTERLEAVE"],
                proc.stdout.splitlines(),
            )


if __name__ == "__main__":
    unittest.main()
