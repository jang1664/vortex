"""Filesystem regression tests; all mutations are confined to temporary archives."""
import argparse
import contextlib
import errno
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from tools import vortex_binmgr as mgr


class BinManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'archive'
        self.platform = '/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/platforms.xpfm'
        self.platform = self.platform.replace('platforms.xpfm', 'xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm')
        self.src = self.build(self.base / 'build_fpint')

    def build(self, path, *, cores='', config='-DNUM_CORES=1', platform=None):
        path.mkdir(parents=True)
        (path / '.config.stamp').write_text(
            f'TARGET=hw PLATFORM={platform or self.platform} CLOCK_FREQ_HZ=100 NUM_CORES={cores} CONFIGS={config} DEBUG=\n')
        (path / 'bin').mkdir()
        (path / 'bin/vortex_afu.xclbin').write_bytes(b'binary\x00contents')
        return path

    def args(self, *paths, apply=True, root=None):
        return argparse.Namespace(root=root or self.root, dir=list(paths), apply=apply, force=False, hash_len=10)

    def run_tool(self, *paths, **kwargs):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = mgr.run(self.args(*paths, **kwargs))
        return rc, out.getvalue(), err.getvalue()

    def entries(self, *paths):
        entries = mgr.plan_entries(list(paths or [self.src]), 10)
        actions = mgr.plan_actions(self.root, entries)
        return entries, actions

    def assert_original(self):
        self.assertFalse(self.src.is_symlink())
        self.assertEqual((self.src / 'bin/vortex_afu.xclbin').read_bytes(), b'binary\x00contents')

    def test_platform_forms(self):
        for value in ('xilinx_u55c_gen3x16', 'xilinx_u55c_gen3x16.xpfm',
                      'platforms/xilinx_u55c_gen3x16.xpfm', './platforms/xilinx_u55c_gen3x16.xpfm', self.platform):
            self.assertEqual(mgr.short_platform(value), 'u55c')
        for value in ('../bad.xpfm', '/opt/../bad.xpfm', 'bad\\name', 'bad\nname', '', '.'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                mgr.short_platform(value)

    def test_empty_core_fallback_and_direct_child(self):
        entries, _ = self.entries()
        self.assertEqual(entries[0]['params_norm']['NUM_CORES'], '1')
        self.assertEqual(entries[0]['canonical_path'].parent, self.root / 'fpint')
        self.assertTrue(entries[0]['name_base'].startswith('xrt_hw_u55c_c1_f100_fpint_'))
        self.assertEqual(entries[0]['validation_errors'], [])

    def test_conflicting_cores_rejected(self):
        other = self.build(self.base / 'conflict', cores='2')
        with self.assertRaisesRegex(ValueError, 'conflicting NUM_CORES'):
            self.entries(other)

    def test_sources_core_fallback(self):
        other = self.build(self.base / 'sources', config='-DEXT_TCU_ENABLE')
        (other / 'sources.txt').write_text('+define+NUM_CORES=4\n')
        self.assertEqual(mgr.plan_entries([other], 10)[0]['params_norm']['NUM_CORES'], '4')

    def test_link_summary_actual_entry_format(self):
        path = self.base / 'summary'
        entry = {'buildStep': {'args': ['--target', 'hw_emu', '--platform', self.platform, '--kernel_frequency', '0:100']}}
        path.write_text('<ENTRY>\n{}\n</ENTRY>\n<ENTRY>\n' + json.dumps(entry) + '\n</ENTRY>')
        self.assertEqual(mgr.parse_platform_from_link_summary(path), self.platform)
        self.assertEqual(mgr.parse_target_from_link_summary(path), 'hw_emu')
        self.assertEqual(mgr.parse_kernel_freq_from_link_summary(path), '100')
        entry['buildStep'] = {'commandLine': f'v++ --platform "{self.platform}" --target=hw'}
        path.write_text('<ENTRY>' + json.dumps(entry) + '</ENTRY>')
        self.assertEqual(mgr.parse_platform_from_link_summary(path), self.platform)
        entry = {'content': 'kernel_frequency=0:100\n'}
        path.write_text('<ENTRY>' + json.dumps(entry) + '</ENTRY>')
        self.assertEqual(mgr.parse_kernel_freq_from_link_summary(path), '100')
        path.write_text(f'v++ --platform "{self.platform}" --target hw')
        self.assertEqual(mgr.parse_platform_from_link_summary(path), self.platform)

    def test_invalid_hash_cli(self):
        for value in ('0', '65'):
            proc = subprocess.run([sys.executable, str(Path(mgr.__file__)), '--hash-len', value], capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('between 1 and 64', proc.stderr)

    def test_dry_run_no_mutation(self):
        before = mgr.tree_inventory(self.base)
        rc, out, _ = self.run_tool(self.src, apply=False)
        self.assertEqual(rc, 0)
        self.assertIn('xrt_hw_u55c_c1_f100_fpint_', out)
        self.assertEqual(before, mgr.tree_inventory(self.base))

    def test_missing_core_apply_rejected_before_any_move(self):
        other = self.build(self.base / 'unknown', config='-DEXT_TCU_ENABLE')
        rc, out, _ = self.run_tool(other, apply=False)
        self.assertEqual(rc, 1)
        self.assertIn('NUM_CORES', out)
        with self.assertRaisesRegex(RuntimeError, 'preflight failed'):
            self.run_tool(self.src, other)
        self.assert_original()
        self.assertTrue(other.is_dir())

    def test_unsafe_target_rejected(self):
        p = self.src / '.config.stamp'
        p.write_text(p.read_text().replace('TARGET=hw', 'TARGET=../../escape'))
        with self.assertRaises(ValueError):
            self.run_tool(self.src)
        self.assert_original()

    def test_apply_output_manifest_and_index(self):
        rc, out, _ = self.run_tool(self.src)
        self.assertEqual(rc, 0)
        dst = self.src.resolve()
        self.assertEqual(dst.parent, self.root / 'fpint')
        for marker in ('MOVED:', 'SYMLINK:', 'MANIFEST:', 'INDEX UPDATED:', 'DONE: moved=1 unchanged=0 failed=0'):
            self.assertIn(marker, out)
        self.assertIn(str(dst), out)
        manifest = json.loads((dst / 'manifest.json').read_text())
        self.assertEqual(manifest['origin']['original_dir'], 'build_fpint')
        index = json.loads((dst.parent / 'hashes.json').read_text())
        self.assertEqual(index['entries'][0]['path'], str(dst))
        self.assertEqual((dst.parent / 'by-hash' / manifest['id']['short']).resolve(), dst)
        self.assertEqual((dst.parent / 'latest').resolve(), dst)
        self.assertFalse(list(dst.parent.glob('.vortex_binmgr_journal_*')))

    def test_repeated_aliases_and_suffix_stable(self):
        entries, _ = self.entries()
        occupied = entries[0]['canonical_path']
        occupied.mkdir(parents=True)
        alias = self.base / 'alias'
        alias.symlink_to(self.src)
        self.run_tool(self.src, alias, self.src)
        dst = self.src.resolve()
        self.assertTrue(dst.name.endswith('_1'))
        self.assertEqual(alias.resolve(), dst)
        before = json.loads((dst / 'manifest.json').read_text())
        rc, out, _ = self.run_tool(self.src, alias)
        self.assertEqual(rc, 0)
        self.assertIn('UNCHANGED:', out)
        self.assertIn('moved=0 unchanged=1', out)
        self.assertEqual(self.src.resolve(), dst)
        self.assertEqual(before, json.loads((dst / 'manifest.json').read_text()))

    def test_existing_manifest_identity_and_metadata_preserved(self):
        self.run_tool(self.src)
        dst = self.src.resolve()
        manifest = json.loads((dst / 'manifest.json').read_text())
        manifest['id'] = {'alg': 'sha256', 'full': 'a' * 64, 'short': 'a' * 10}
        manifest['notes'] = 'keep me'
        old_params = manifest['params'].copy()
        (dst / 'manifest.json').write_text(json.dumps(manifest))
        self.run_tool(self.src)
        new = self.src.resolve()
        after = json.loads((new / 'manifest.json').read_text())
        self.assertEqual(after['id'], manifest['id'])
        self.assertEqual(after['params'], old_params)
        self.assertEqual(after['notes'], 'keep me')
        self.assertEqual(dst.resolve(), new)
        self.assertEqual(os.readlink(self.src), os.path.relpath(new, self.src.parent))

    def test_index_does_not_recompute_peer_identity_or_name(self):
        self.run_tool(self.src)
        dst = self.src.resolve()
        legacy = dst.parent / 'legacy_name_c_f100'
        dst.rename(legacy)
        manifest = json.loads((legacy / 'manifest.json').read_text())
        (legacy / '.config.stamp').write_text('unreadable-by-parser')
        mgr.update_root_index(legacy.parent, 10)
        entry = json.loads((legacy.parent / 'hashes.json').read_text())['entries'][0]
        self.assertEqual(entry['name'], legacy.name)
        self.assertEqual(entry['build_id'], manifest['id']['short'])

    def test_root_scan_includes_both_leaves_not_nested_builds(self):
        baseline = self.build(self.root / 'baseline' / 'plain')
        fpint = self.build(self.root / 'fpint' / 'special_fpint')
        nested = self.build(fpint / '_x' / 'nested')
        self.assertEqual(set(mgr.scan_dirs(self.root)), {baseline, fpint})
        self.assertNotIn(nested, mgr.scan_dirs(self.root))

    def test_leaf_symlink_rejected(self):
        self.root.mkdir()
        (self.root / 'fpint').symlink_to(self.base)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            self.run_tool(self.src)
        self.assert_original()

    def test_managed_metadata_symlink_rejected(self):
        external = self.base / 'external'
        external.write_text('unchanged')
        self.root.mkdir()
        (self.root / 'fpint').mkdir()
        (self.root / 'fpint/hashes.json').symlink_to(external)
        with self.assertRaisesRegex(RuntimeError, 'metadata location'):
            self.run_tool(self.src)
        self.assert_original()
        self.assertEqual(external.read_text(), 'unchanged')

    def test_overlap_rejected(self):
        nested = self.build(self.src / 'nested')
        with self.assertRaisesRegex(RuntimeError, 'overlapping input'):
            self.run_tool(self.src, nested)
        self.assert_original()

    def test_lock_prevents_concurrent_apply(self):
        with mgr.archive_locks(self.root):
            with self.assertRaisesRegex(RuntimeError, 'another --apply'):
                self.run_tool(self.src)
        self.assert_original()

    def fail_once(self, function, predicate):
        original = getattr(mgr, function)
        fired = False
        def call(*args, **kwargs):
            nonlocal fired
            if not fired and predicate(*args, **kwargs):
                fired = True
                raise OSError('injected failure')
            return original(*args, **kwargs)
        return mock.patch.object(mgr, function, side_effect=call)

    def test_manifest_failure_rolls_back(self):
        with self.fail_once('atomic_json', lambda p, d: p.name == 'manifest.json'):
            with self.assertRaisesRegex(RuntimeError, 'phase=published'):
                self.run_tool(self.src)
        self.assert_original()
        self.assertFalse((self.src / 'manifest.json').exists())

    def test_alias_failure_rolls_back(self):
        alias = self.base / 'alias'
        alias.symlink_to(str(self.src))
        old = os.readlink(alias)
        with self.fail_once('atomic_link', lambda p, d: p == alias):
            with self.assertRaises(RuntimeError):
                self.run_tool(self.src, alias)
        self.assert_original()
        self.assertEqual(os.readlink(alias), old)

    def test_index_failure_retry_preserves_committed_move(self):
        with mock.patch.object(mgr, 'update_root_index', side_effect=OSError('index failure')):
            with self.assertRaisesRegex(RuntimeError, 'index finalization'):
                self.run_tool(self.src)
        dst = self.src.resolve()
        self.assertTrue((dst / 'manifest.json').is_file())
        self.assertTrue(list(dst.parent.glob('.vortex_binmgr_journal_*')))
        rc, out, _ = self.run_tool(self.src)
        self.assertEqual(rc, 0)
        self.assertIn('RECOVERING:', out)
        self.assertEqual(self.src.resolve(), dst)
        self.assertFalse(list(dst.parent.glob('.vortex_binmgr_journal_*')))

    @contextlib.contextmanager
    def cross_device(self):
        original = mgr.rename_noreplace
        def rename(path, target):
            if path == self.src and Path(target).parent == self.root / 'fpint':
                raise OSError(errno.EXDEV, 'simulated different filesystem')
            return original(path, target)
        with mock.patch.object(mgr, 'rename_noreplace', rename):
            yield

    def test_cross_filesystem_verified_move(self):
        (self.src / 'relative-link').symlink_to('bin/vortex_afu.xclbin')
        with self.cross_device():
            self.run_tool(self.src)
        self.assertTrue(self.src.is_symlink())
        self.assertEqual(os.readlink(self.src / 'relative-link'), 'bin/vortex_afu.xclbin')
        self.assertEqual((self.src / 'relative-link').read_bytes(), b'binary\x00contents')
        self.assertFalse(list(self.base.glob('.vortex_binmgr_backup_*')))

    def test_copy_failure_keeps_original(self):
        with self.cross_device(), mock.patch.object(mgr.shutil, 'copytree', side_effect=OSError('copy failure')):
            with self.assertRaises(RuntimeError):
                self.run_tool(self.src)
        self.assert_original()

    def test_copy_corruption_keeps_original(self):
        original = mgr.shutil.copytree
        def corrupt(src, dst, *args, **kwargs):
            result = original(src, dst, *args, **kwargs)
            if Path(src) == self.src:
                (Path(dst) / 'bin/vortex_afu.xclbin').write_bytes(b'corrupted')
            return result
        with self.cross_device(), mock.patch.object(mgr.shutil, 'copytree', side_effect=corrupt):
            with self.assertRaisesRegex(RuntimeError, 'verification failed'):
                self.run_tool(self.src)
        self.assert_original()
        self.assertTrue(list((self.root / 'fpint').glob('.vortex_binmgr_copy_*')))

    def test_rename_failure_keeps_original(self):
        original = mgr.rename_noreplace
        def rename(path, target):
            if path == self.src:
                raise PermissionError('rename denied')
            return original(path, target)
        with mock.patch.object(mgr, 'rename_noreplace', rename):
            with self.assertRaises(RuntimeError):
                self.run_tool(self.src)
        self.assert_original()

    def test_partial_batch_reports_first_completed_build(self):
        second = self.build(self.base / 'second_fpint', cores='2', config='-DNUM_CORES=2')
        original = mgr.rename_noreplace
        def rename(path, target):
            if path == second:
                raise PermissionError('second failed')
            return original(path, target)
        err = io.StringIO()
        with mock.patch.object(mgr, 'rename_noreplace', rename), contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                mgr.run(self.args(self.src, second))
        self.assertTrue(self.src.is_symlink())
        self.assertFalse(second.is_symlink())
        self.assertIn('moved=1 unchanged=0 failed=1', err.getvalue())
        self.run_tool(self.src, second)

    def test_crash_at_each_journal_boundary(self):
        original = mgr.journal_write
        for state in ('prepared', 'moving', 'published', 'committed'):
            with self.subTest(state=state):
                root = self.base / ('archive_' + state)
                src = self.build(self.base / ('job_fpint_' + state))
                def crash(path, record, phase):
                    original(path, record, phase)
                    if phase == state:
                        raise SystemExit('simulated abrupt exit')
                with mock.patch.object(mgr, 'journal_write', side_effect=crash):
                    with self.assertRaises(SystemExit):
                        self.run_tool(src, root=root)
                rc, out, _ = self.run_tool(src, root=root)
                self.assertEqual(rc, 0)
                self.assertIn('RECOVERING:', out)
                self.assertTrue(src.is_symlink())
                self.assertFalse(list((root / 'fpint').glob('.vortex_binmgr_journal_*')))

    def test_cross_filesystem_crash_at_copy_boundaries(self):
        original = mgr.journal_write
        for state in ('copying', 'copy_verified', 'source_staged'):
            with self.subTest(state=state):
                def crash(path, record, phase):
                    original(path, record, phase)
                    if phase == state:
                        raise SystemExit('simulated abrupt exit')
                with self.cross_device(), mock.patch.object(mgr, 'journal_write', side_effect=crash):
                    with self.assertRaises(SystemExit):
                        self.run_tool(self.src)
                with mgr.archive_locks(self.root) as leaves:
                    mgr.recover_journals(leaves, 10)
                self.assert_original()

    def test_external_change_blocks_recovery(self):
        original = mgr.journal_write
        def crash(path, record, phase):
            original(path, record, phase)
            if phase == 'published':
                raise SystemExit('crash')
        with mock.patch.object(mgr, 'journal_write', side_effect=crash):
            with self.assertRaises(SystemExit):
                self.run_tool(self.src)
        journal = next((self.root / 'fpint').glob('.vortex_binmgr_journal_*'))
        dst = Path(json.loads(journal.read_text())['dst'])
        saved = self.base / 'external-saved'
        dst.rename(saved)
        dst.mkdir()
        with self.assertRaisesRegex(RuntimeError, 'changed externally'):
            self.run_tool(self.src)
        self.assertTrue(saved.is_dir())
        self.assertTrue(dst.is_dir())
        self.assertTrue(journal.is_file())

    def test_destination_appearing_after_preflight_is_not_overwritten(self):
        original = mgr.rename_noreplace
        appeared = []
        def rename(src, dst):
            if src == self.src:
                dst.mkdir()
                appeared.append(dst)
            return original(src, dst)
        with mock.patch.object(mgr, 'rename_noreplace', side_effect=rename):
            with self.assertRaises(RuntimeError):
                self.run_tool(self.src)
        self.assert_original()
        self.assertTrue(appeared[0].is_dir())

    def test_real_cross_filesystem_move(self):
        if not Path('/dev/shm').is_dir() or Path('/dev/shm').stat().st_dev == self.base.stat().st_dev:
            self.skipTest('No writable second filesystem available')
        try:
            temporary = tempfile.TemporaryDirectory(dir='/dev/shm', prefix='binmgr-test-')
        except PermissionError:
            self.skipTest('Second filesystem not writable')
        with temporary as directory:
            self.run_tool(self.src, root=Path(directory) / 'archive')
            self.assertTrue(self.src.is_symlink())
            self.assertNotEqual(self.src.resolve().stat().st_dev, self.base.stat().st_dev)
            self.assertEqual((self.src / 'bin/vortex_afu.xclbin').read_bytes(), b'binary\x00contents')

    def test_permission_preflight_keeps_original(self):
        access = os.access
        with mock.patch.object(mgr.os, 'access', side_effect=lambda p, mode: False if p == self.src.parent else access(p, mode)):
            with self.assertRaisesRegex(RuntimeError, 'not writable'):
                self.run_tool(self.src)
        self.assert_original()

    def test_invalid_manifest_does_not_move(self):
        (self.src / 'manifest.json').write_text('[]')
        with self.assertRaisesRegex(ValueError, 'invalid manifest'):
            self.run_tool(self.src)
        self.assert_original()

    def test_repair_nested_archive_and_preserve_peer(self):
        self.run_tool(self.src)
        peer = self.src.resolve()
        before = (peer / 'manifest.json').read_bytes()
        nested = self.build(self.root / 'fpint/xrt_hw_/opt/platform/build.xpfm_c_f100_fpint_bad')
        manifest = {'schema_version': 2, 'id': {'alg': 'sha256', 'full': 'c' * 64, 'short': 'c' * 10},
                    'name': nested.name, 'params': {'PLATFORM': self.platform},
                    'flags': {'fpint': True}, 'origin': None, 'notes': 'retained'}
        (nested / 'manifest.json').write_text(json.dumps(manifest))
        alias = self.base / 'original-build-name'
        alias.symlink_to(nested)
        self.run_tool(alias)
        dst = alias.resolve()
        self.assertEqual(dst, self.root / ('fpint/xrt_hw_u55c_c1_f100_fpint_' + 'c' * 10))
        self.assertTrue(nested.is_symlink())
        self.assertEqual(nested.resolve(), dst)
        self.assertEqual(os.readlink(alias), os.path.relpath(dst, alias.parent))
        after = json.loads((dst / 'manifest.json').read_text())
        self.assertEqual(after['id'], manifest['id'])
        self.assertEqual(after['params'], manifest['params'])
        self.assertEqual(after['notes'], 'retained')
        self.assertEqual(before, (peer / 'manifest.json').read_bytes())
        index = json.loads((dst.parent / 'hashes.json').read_text())
        self.assertEqual(len(index['entries']), 2)
        self.run_tool(alias)
        self.assertEqual(alias.resolve(), dst)

    def test_invalid_journal_preserved(self):
        leaf = self.root / 'fpint'
        leaf.mkdir(parents=True)
        journal = leaf / ('.vortex_binmgr_journal_' + 'a' * 32 + '.json')
        journal.write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'invalid recovery journal fields'):
            self.run_tool(self.src)
        self.assert_original()
        self.assertEqual(journal.read_text(), '{}')

    def test_index_keeps_live_legacy_hash_alias_outside_build_scan(self):
        entries, _ = self.entries()
        identity = entries[0]['build_id']
        leaf = self.root / 'fpint'
        old = leaf / 'legacy-without-manifest-or-stamp'
        old.mkdir(parents=True)
        (leaf / 'by-hash').mkdir()
        link = leaf / 'by-hash' / identity
        link.symlink_to(old)
        self.run_tool(self.src)
        self.assertEqual(link.resolve(), old)
        self.assertEqual((leaf / 'by-hash' / (identity + '_1')).resolve(), self.src.resolve())
        self.run_tool(self.src)
        self.assertEqual(link.resolve(), old)
        self.assertEqual((leaf / 'by-hash' / (identity + '_1')).resolve(), self.src.resolve())


if __name__ == '__main__':
    unittest.main()
