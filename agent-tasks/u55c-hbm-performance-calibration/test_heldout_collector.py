#!/usr/bin/env python3
"""Read-only collector rejection checks using retained evidence and in-memory faults."""
from pathlib import Path
import unittest
from unittest.mock import patch
from collect_heldout import collect

REPO = Path(__file__).resolve().parents[2]
HARDWARE = REPO/'build_hbm_hardware_reference/hardware-repeats-4916'
READ = Path.read_text


class CollectorTests(unittest.TestCase):
    def mutated(self, name, change):
        def read(path, *args, **kwargs):
            text = READ(path, *args, **kwargs)
            return change(text) if path.name == name else text
        with patch.object(Path, 'read_text', read):
            return collect(REPO, HARDWARE)

    def test_valid_evidence(self):
        result = collect(REPO, HARDWARE)
        self.assertEqual(len(result['samples']), 24)
        self.assertEqual(len(result['comparisons']), 3)
        self.assertTrue(all(x['within_10_percent'] for x in result['comparisons']))

    def test_reject_output_failure(self):
        with self.assertRaisesRegex(ValueError, 'Invalid result'):
            self.mutated('heldout_candidate_h1_1.log', lambda s:s.replace('PASSED','FAILED'))

    def test_reject_missing_finish(self):
        with self.assertRaisesRegex(ValueError, 'Invalid simulator termination'):
            self.mutated('heldout_candidate_h1_1_simv.log', lambda s:s.replace('$finish at simulation time','removed'))

    def test_reject_wrong_board_clock(self):
        import json
        def change(text):
            from collect_hardware_smoke import walk
            value = json.loads(text)
            for node in walk(value):
                if node.get('id') == 'DATA_CLK':
                    node['freq_mhz'] = 125
            return json.dumps(value)
        with self.assertRaisesRegex(ValueError, 'Invalid board'):
            self.mutated('gemm16x16x1024_1_board.json', change)

    def test_reject_prelaunch_identity(self):
        with self.assertRaisesRegex(ValueError, 'Prelaunch hash mismatch'):
            self.mutated('heldout_candidate_h1_1_before.sha256', lambda s:'0'*64+s[64:])

    def test_reject_replay_difference(self):
        with self.assertRaisesRegex(ValueError, 'Nondeterministic replay'):
            self.mutated('heldout_candidate_h1_2.log', lambda s:s.replace('cycles=11375','cycles=11376'))

    def test_above_tolerance_is_reported_not_dropped(self):
        def read(path, *args, **kwargs):
            text = READ(path, *args, **kwargs)
            if path.name in ('heldout_candidate_h1_1.log','heldout_candidate_h1_2.log'):
                return text.replace('cycles=11375','cycles=20000')
            return text
        with patch.object(Path, 'read_text', read):
            result = collect(REPO, HARDWARE)
        self.assertFalse(result['comparisons'][0]['within_10_percent'])
        self.assertEqual(len(result['comparisons']), 3)


if __name__ == '__main__':
    unittest.main()
