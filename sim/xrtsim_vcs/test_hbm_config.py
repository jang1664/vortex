"""Directed configuration tests; run from a configured build/sim/xrtsim_vcs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent


class ConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="u55c-config-")
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)

    def build(self, config="", success=True, **settings):
        # Do not inherit the parent test profile's clock/platform: tests that
        # mutate a value need a known baseline even under a 250 MHz build.
        settings = {"LOGIC_FREQ_HZ": "100000000", "HBM_AXI_FREQ_HZ": "300000000",
                    "XRT_VCS_PLATFORM": "xilinx_u55c", **settings}
        command = ["make", "--no-print-directory", "-f", str(SOURCE / "Makefile"),
                   "hbm-config", f"DESTDIR={self.output}", f"CONFIGS={config}"]
        command += [f"{key}={value}" for key, value in settings.items()]
        result = subprocess.run(command, capture_output=True, text=True, env=os.environ)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads((self.output / "u55c_model_manifest.json").read_text())
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hardware_connectivity_4_and_8(self):
        for ports in (4, 8):
            manifest = self.build(f"-DNUM_HBM_PORTS={ports} -DNUM_DMA_CHANNELS=4")
            self.assertEqual(manifest["kernel_ports"], ports)
            self.assertEqual(manifest["routes"], [
                {"port": p, "first_pc": p * (32 // ports),
                 "last_pc": (p + 1) * (32 // ports) - 1} for p in range(ports)])

    def test_defaults_and_artifact_consistency(self):
        manifest = self.build()
        self.assertEqual(manifest["kernel_ports"], 8)
        for suffix in ("h", "svh"):
            self.assertIn(manifest["sha256"], (self.output / f"u55c_model_config.{suffix}").read_text())

    def test_invalid_geometry(self):
        for config in ("-DNUM_HBM_PORTS=3", "-DNUM_HBM_PORTS=", "-DNUM_HBM_PORTS",
                       "-DNUM_HBM_PORTS=4 -DNUM_HBM_PORTS=4",
                       "-DMEM_ADDR_WIDTH=32", "-DPLATFORM_MEMORY_DATA_SIZE=32",
                       "-DNUM_CORES=2 -DNUM_CORES=3", "-DNUM_HBM_PORTS=4 -DNUM_DMA_CHANNELS=8",
                       "-DNUM_DMA_CHANNELS=3", "-DNUM_DMA_CHANNELS=8 -DNUM_TMEM_BANKS=4",
                       "-DPLATFORM_MEMORY_NUM_PORTS=4"):
            with self.subTest(config=config):
                self.build(config, success=False)

    def test_profile_platform_duplicates_are_compatible(self):
        manifest = self.build("-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 "
                              "-DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE")
        self.assertEqual(manifest["aperture_bytes"], 1 << 34)

    def test_invalid_clock_and_platform(self):
        for settings in ({"LOGIC_FREQ_HZ": "0"}, {"HBM_AXI_FREQ_HZ": "-1"},
                         {"HBM_AXI_FREQ_HZ": "300MHz"}, {"XRT_VCS_PLATFORM": "xilinx_u250"}):
            self.build(success=False, **settings)

    def test_invalid_connectivity(self):
        valid = [f"vortex_afu_1.m_axi_mem_{p}:HBM[{p*8}:{p*8+7}]" for p in range(4)]
        variants = [[], valid[:-1], valid + [valid[0]],
                    ["vortex_afu_1.m_axi_mem_0:HBM[0:32]", *valid[1:]],
                    ["vortex_afu_1.m_axi_mem_0:HBM[7:0]", *valid[1:]],
                    [valid[0], "vortex_afu_1.m_axi_mem_1:HBM[7:15]", *valid[2:]],
                    [*valid[:-1], "vortex_afu_1.m_axi_mem_4:HBM[24:31]"],
                    ["unrecognized_mapping", *valid[1:]]]
        for specs in variants:
            with self.subTest(specs=specs):
                self.build("-DNUM_HBM_PORTS=4 -DNUM_DMA_CHANNELS=4", success=False,
                           SP_FLAGS=" ".join(specs))

    def test_incremental_invalidation(self):
        first = self.build()
        header = self.output / "u55c_model_config.h"
        before = header.stat().st_mtime_ns
        self.build()
        self.assertEqual(header.stat().st_mtime_ns, before)
        changed = self.build(LOGIC_FREQ_HZ="250000000")
        self.assertNotEqual(first["sha256"], changed["sha256"])
        self.assertNotEqual(header.stat().st_mtime_ns, before)
        # Missing secondary outputs are regenerated even with an unchanged hash.
        (self.output / "u55c_model_config.svh").rename(self.output / "saved.svh")
        self.build(LOGIC_FREQ_HZ="250000000")
        self.assertTrue((self.output / "u55c_model_config.svh").is_file())


if __name__ == "__main__":
    unittest.main()
