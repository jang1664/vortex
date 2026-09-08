#!/usr/bin/env python3
from pathlib import Path
import tempfile
import unittest
from inspect_work_bus import inspect
from test_work_trace import TRACE

BUS = '''STARTUP_AR t=10000 port=0 id=1 addr=1000 len=1
STARTUP_R t=30000 port=0 id=1 last=0
STARTUP_R t=50000 port=0 id=1 last=1
'''

class BusTests(unittest.TestCase):
    def parse(self, bus):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'trace.log'
            path.write_text(TRACE+bus)
            return inspect(path)

    def test_two_beat_read(self):
        result = self.parse(BUS)
        self.assertEqual(result['invocation_ar_count'], 1)
        self.assertEqual(result['invocation_r_beats_by_port'][0], 2)
        self.assertEqual(result['first_r_latency_ps']['median'], 20000)
        self.assertEqual(result['outstanding_read_union_ps'], 40000)

    def test_early_last(self):
        with self.assertRaises(ValueError):
            self.parse(BUS.replace('last=0', 'last=1'))

    def test_unfinished(self):
        with self.assertRaises(ValueError):
            self.parse('\n'.join(BUS.splitlines()[:-1])+'\n')

    def test_orphan_response(self):
        with self.assertRaises(ValueError):
            self.parse('\n'.join(BUS.splitlines()[1:])+'\n')

    def test_unknown_request(self):
        with self.assertRaises(ValueError):
            self.parse(BUS.replace('addr=1000', 'addr=x000'))

if __name__ == '__main__':
    unittest.main()
