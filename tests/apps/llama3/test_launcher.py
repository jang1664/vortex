"""CPU-only checks for packaging/allocation boundaries and shell argument handling."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("llama_launcher", Path(__file__).with_name("run.py"))
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="llama launcher ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / "apps/vortex_llama3/run_synthetic_inference.py"
        self.app.parent.mkdir(parents=True)
        self.app.write_text(
            "import json, os, sys\n"
            "print(json.dumps({'args': sys.argv[1:], 'configs': os.environ['CONFIGS'], "
            "'device': os.environ.get('XRT_DEVICE_INDEX')}))\n"
        )
        for name in ("libvortex.so", "libvortex-xrt.so"):
            (self.root / name).touch()
        config = self.root / "config.sh"
        config.write_text('export CONFIGS="-DNUM_THREADS=16 -DMXU_ROW=16"\n')
        resolver = patch.object(launcher, "resolve_fpga_bin_artifacts", return_value=SimpleNamespace(
            config=config, xclbin=self.root / "vortex_afu.xclbin", bin_dir=self.root,
        ))
        resolver.start()
        self.addCleanup(resolver.stop)
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def args(self, *extra):
        return launcher.parser().parse_args([
            "--tvm-home", str(self.root), "--python", sys.executable,
            "--runtime-dir", str(self.root), "--artifact-dir", str(self.root / "artifacts"),
            *extra,
        ])

    def package(self):
        artifact = self.root / "artifacts"
        artifact.mkdir()
        (artifact / "package.json").write_text(json.dumps({
            "shape": {"batch_size": 1, "prompt_length": 32, "cache_capacity": 512},
            "packed_kv_cache": True, "layout_policy": "fused",
        }))

    def test_package_runs_without_slurm_and_preserves_arguments(self):
        _, env, _, commands = launcher.prepare(self.args("--mode", "package"))
        env["XRT_DEVICE_INDEX"] = "wrong-inherited-device"
        result = subprocess.run(commands[0][1], env=env, capture_output=True, text=True, check=True)
        record = json.loads(result.stdout)
        self.assertIn("-DMXU_ROW=16", record["configs"])
        self.assertIsNone(record["device"])
        self.assertIn(str(self.root / "artifacts"), record["args"])

    def test_combined_mode_allocates_only_run(self):
        *_, commands = launcher.prepare(self.args())
        self.assertEqual([stage for stage, _ in commands], ["package", "run"])
        self.assertEqual(commands[0][1][0], "bash")
        self.assertEqual(commands[1][1][0], "srun")
        self.assertEqual(commands[1][1].count("--gres=fpga:u55c:1"), 1)

    def test_existing_allocation_reuses_run_but_rejects_compile(self):
        os.environ["SLURM_JOB_ID"] = "123"
        self.package()
        *_, commands = launcher.prepare(self.args("--mode", "run"))
        self.assertEqual(commands[0][1][0], "bash")
        with self.assertRaisesRegex(ValueError, "outside Slurm"):
            launcher.prepare(self.args())

    def test_run_shape_changes_rejected_but_decode_change_allowed(self):
        self.package()
        launcher.prepare(self.args("--mode", "run", "--decode-steps", "1"))
        with self.assertRaisesRegex(ValueError, "Package shape"):
            launcher.prepare(self.args("--mode", "run", "--prefill-tokens", "16"))

    def test_bad_prompt_or_capacity_rejected_before_execution(self):
        for extra in (("--decode-steps", "481"), ("--prompt-token-ids", "1;2,3"),
                      ("--prompt-token-ids", "128256"), ("--prefill-tokens", "0")):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                launcher.prepare(self.args(*extra))


if __name__ == "__main__":
    unittest.main()
