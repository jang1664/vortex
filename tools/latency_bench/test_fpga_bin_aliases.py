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

    def test_regular_path_still_works(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "fpga_bin"
            bin_dir.mkdir()

            self.assertEqual(bin_dir.resolve(), runner.resolve_fpga_bin(str(bin_dir)))


if __name__ == "__main__":
    unittest.main()
