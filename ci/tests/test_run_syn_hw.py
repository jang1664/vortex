#!/usr/bin/env python3
"""Exercise synthesis launcher paths without invoking FPGA tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PROFILES = (
    'tcu_th32_c1_rev3',
    'th32_c1_tcu_naive_m32_tcol32',
    'th32_c1_naive_m32_tcol32',
    'th32_c1_improve_m32_tcol32',
)


class RunSynHwTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='syn launcher ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'source tree'
        (self.repo / 'ci').mkdir(parents=True)
        (self.repo / 'configs').mkdir()
        self.script = self.repo / 'ci/run_syn_hw.sh'
        shutil.copy2(REPO / 'ci/run_syn_hw.sh', self.script)
        self.source_make = self.repo / 'hw/syn/xilinx/xrt/Makefile'
        self.source_make.parent.mkdir(parents=True)
        self.source_make.write_text('# source Makefile fixture\n')
        for profile in PROFILES:
            shutil.copy2(REPO / 'configs' / (profile + '.sh'), self.repo / 'configs')
        self.build = self.make_build('build')
        self.observation = self.base / 'make.json'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        stub = self.bin / 'make'
        stub.write_text('''#!/usr/bin/env python3
import json, os
from pathlib import Path
Path(os.environ['MAKE_OBSERVATION']).write_text(json.dumps({
    'cwd': os.getcwd(), 'env': dict(os.environ)}))
print('stub make: FPGA tools were not invoked')
raise SystemExit(int(os.environ.get('STUB_MAKE_EXIT', '0')))
''')
        stub.chmod(0o755)
        self.env = os.environ.copy()
        for name in ('BUILD_DIR', 'PERF', 'DEBUG', 'CONGESTION_FAIL_FAST',
                     'GEMM_MXU_SLR_FLOORPLAN', 'PLATFORM', 'CLOCK_FREQ_HZ'):
            self.env.pop(name, None)
        self.env.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        MAKE_OBSERVATION=str(self.observation))

    def make_build(self, name):
        build = self.repo / name
        (build / 'ci').mkdir(parents=True)
        (build / 'ci/run_syn_hw.sh').symlink_to(self.script)
        (build / 'config.mk').write_text(f'VORTEX_HOME ?= {self.repo}\n')
        synth = build / 'hw/syn/xilinx/xrt'
        synth.mkdir(parents=True)
        shutil.copy2(self.source_make, synth / 'Makefile')
        return build

    def launch(self, entry=None, cwd=None, config=PROFILES[2], extra=(), env=None):
        return subprocess.run(
            [str(entry or self.build / 'ci/run_syn_hw.sh'), '--config', config, *extra],
            cwd=cwd or self.build, env=env or self.env, text=True, capture_output=True)

    def assert_build(self, result, build):
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        observed = json.loads(self.observation.read_text())
        self.assertEqual(observed['cwd'], str(build / 'hw/syn/xilinx/xrt'))
        self.assertEqual(observed['env']['TARGET'], 'hw')
        return observed['env']

    def test_configured_symlink_resolves_all_four_profiles(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                env = self.assert_build(self.launch(config='configs/'+profile+'.sh'), self.build)
                self.assertEqual(env['PREFIX'], profile)
                self.assertIn('-DNUM_THREADS=32', env['CONFIGS'])
                gemm = profile != PROFILES[0]
                self.assertEqual('-DGEMM_SLR_PIPELINE' in env['CONFIGS'].split(), gemm)
                self.assertEqual(env.get('GEMM_MXU_SLR_FLOORPLAN'), '1' if gemm else None)

    def test_source_entry_from_source_defaults_to_repo_build(self):
        self.assert_build(self.launch(entry=self.script, cwd=self.repo), self.build)

    def test_source_entry_uses_configured_current_directory(self):
        other = self.make_build('custom build')
        self.assert_build(self.launch(entry=self.script, cwd=other), other)

    def test_build_entry_works_from_unrelated_current_directory(self):
        other = self.make_build('custom build')
        self.assert_build(self.launch(entry=other/'ci/run_syn_hw.sh', cwd=self.base), other)

    def test_build_dir_environment_overrides_entry_tree(self):
        other = self.make_build('env build')
        env = dict(self.env, BUILD_DIR='../env build')
        self.assert_build(self.launch(env=env), other)

    def test_build_dir_argument_overrides_environment(self):
        other = self.make_build('argument build')
        env = dict(self.env, BUILD_DIR=str(self.base/'missing'))
        self.assert_build(self.launch(extra=('--build-dir', '../argument build'), env=env), other)

    def test_relative_config_path_is_resolved_from_caller(self):
        self.assert_build(self.launch(config='../configs/'+PROFILES[2]+'.sh'), self.build)

    def test_nested_config_sources_from_repository_root(self):
        (self.repo/'configs/wrapper.sh').write_text('source configs/'+PROFILES[2]+'.sh\n')
        env = self.assert_build(self.launch(config='wrapper'), self.build)
        self.assertIn('-DGEMM_SLR_PIPELINE', env['CONFIGS'])

    def test_unconfigured_invocation_tree_does_not_fall_back(self):
        bad = self.repo/'unconfigured'
        (bad/'ci').mkdir(parents=True)
        (bad/'ci/run_syn_hw.sh').symlink_to(self.script)
        result = self.launch(entry=bad/'ci/run_syn_hw.sh', cwd=bad)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not configured', result.stderr)
        self.assertFalse(self.observation.exists())

    def test_stale_makefile_fails_before_make(self):
        (self.build/'hw/syn/xilinx/xrt/Makefile').write_text('# stale\n')
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('out of date', result.stderr)
        self.assertFalse(self.observation.exists())

    def test_options_and_log_remain_in_selected_build(self):
        env = self.assert_build(self.launch(extra=('--postfix', 'check', '--perf', '3',
                                                     '--debug', '1', '--no-early-fail')), self.build)
        self.assertEqual(env['PERF'], '3')
        self.assertEqual(env['DEBUG'], '1')
        self.assertEqual(env['CONGESTION_FAIL_FAST'], '0')
        prefix = PROFILES[2]+'_check'
        log = self.build/'hw/syn/xilinx/xrt'/f'{prefix}_{env["PLATFORM"]}_hw'/f'{prefix}.log'
        self.assertIn('stub make', log.read_text())

    def test_make_failure_is_not_hidden_by_tee(self):
        result = self.launch(env=dict(self.env, STUB_MAKE_EXIT='17'))
        self.assertEqual(result.returncode, 17)


if __name__ == '__main__':
    unittest.main()
