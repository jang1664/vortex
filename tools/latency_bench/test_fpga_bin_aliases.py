from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.fpga_bins import (
    FPGA_BIN_ALIAS_MAP_ENV,
    FpgaBinAlias,
    load_fpga_bin_aliases,
    resolve_fpga_bin,
    resolve_fpga_bin_artifacts,
    resolve_fpga_bin_config,
)


class FpgaBinAliasTest(unittest.TestCase):
    def _write_alias_map(self, path: Path, bin_dir: Path) -> None:
        config_dir = path.parent / "configs"
        config_dir.mkdir()
        (config_dir / "test_alias.sh").write_text("CONFIGS='-DPLATFORM_MEMORY_REMAP -DBANK_INTERLEAVE'\nexport CONFIGS\n")
        path.write_text(
            f"""
aliases:
  test_alias:
    path: {bin_dir}
    configs: configs/test_alias.sh
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
                    configs=str(alias_map.parent / "configs" / "test_alias.sh"),
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
            self.assertEqual((alias_map.parent / "configs" / "test_alias.sh").resolve(), config.configs)

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

                config = resolve_fpga_bin_config("test_alias")

                self.assertEqual(bin_dir.resolve(), config.path)
            finally:
                if old_value is None:
                    os.environ.pop(FPGA_BIN_ALIAS_MAP_ENV, None)
                else:
                    os.environ[FPGA_BIN_ALIAS_MAP_ENV] = old_value

    def test_regular_path_still_works(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()

            self.assertEqual(bin_dir.resolve(), resolve_fpga_bin(str(bin_dir)))

    def test_resolves_checked_alias_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "image" / "bin"
            bin_dir.mkdir(parents=True)
            (bin_dir / "vortex_afu.xclbin").write_bytes(b"xclbin")
            (bin_dir.parent / "manifest.json").write_text("{}\n")
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, bin_dir)

            artifacts = resolve_fpga_bin_artifacts(
                "test_alias", alias_map_path=alias_map, require_alias=True
            )

            self.assertEqual("test_alias", artifacts.alias)
            self.assertEqual(bin_dir.resolve(), artifacts.bin_dir)
            self.assertEqual((bin_dir.parent / "manifest.json").resolve(), artifacts.manifest)
            self.assertEqual((bin_dir / "vortex_afu.xclbin").resolve(), artifacts.xclbin)

    def test_checked_alias_artifacts_fail_closed_for_missing_image(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            missing_bin_dir = tmp_path / "missing" / "bin"
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, missing_bin_dir)

            with self.assertRaisesRegex(
                FileNotFoundError,
                "alias 'test_alias' image directory is unavailable",
            ):
                resolve_fpga_bin_artifacts(
                    "test_alias", alias_map_path=alias_map, require_alias=True
                )

    def test_checked_alias_artifacts_reject_non_alias_when_required(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "image" / "bin"
            bin_dir.mkdir(parents=True)
            alias_map = tmp_path / "fpga_bin_alias_map.yaml"
            self._write_alias_map(alias_map, bin_dir)

            with self.assertRaisesRegex(ValueError, "is not an alias"):
                resolve_fpga_bin_artifacts(
                    bin_dir, alias_map_path=alias_map, require_alias=True
                )

    def test_built_in_c4_alias_enables_bank_interleave(self) -> None:
        config = resolve_fpga_bin_config("C4")

        expected = (
            Path(__file__).resolve().parents[2]
            / "configs"
            / "improve_th32_tcol32_hwexp_dcache.sh"
        ).resolve()
        self.assertEqual(expected, config.configs)
        self.assertIn("-DBANK_INTERLEAVE", expected.read_text(encoding="utf-8"))

    def test_ci_resolver_script_rejects_removed_xrt_mem_map_option(self) -> None:
        proc = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve().parents[2] / "ci" / "resolve_fpga_bin_alias.py"),
                "--xrt-mem-map",
                "legacy",
                "naive",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        self.assertNotEqual(0, proc.returncode)
        self.assertIn("unrecognized arguments", proc.stderr)

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
                    "test_alias",
                ],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )

            self.assertEqual(
                [str(bin_dir.resolve()), str((alias_map.parent / "configs" / "test_alias.sh").resolve())],
                proc.stdout.splitlines(),
            )


if __name__ == "__main__":
    unittest.main()
