#!/usr/bin/env python3
"""Small synthetic checks independent of the captured workload."""
from pathlib import Path
import tempfile
import unittest
from inspect_work_trace import inspect

TRACE = '''REFERENCE_WORK t=0 start=1 done=0 active=0 output=0 issue=000000 retire=000000 busy=000000 queued=000000
REFERENCE_WORK t=10000 start=0 done=0 active=1 output=0 issue=100001 retire=000000 busy=000000 queued=000000
REFERENCE_WORK t=30000 start=0 done=0 active=1 output=0 issue=000001 retire=000001 busy=100001 queued=000000
REFERENCE_WORK t=50000 start=0 done=0 active=1 output=1 issue=000000 retire=100001 busy=100001 queued=000000
REFERENCE_WORK t=60000 start=0 done=1 active=0 output=0 issue=000000 retire=000000 busy=000000 queued=000000
'''

class TraceTests(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'trace.log'
            path.write_text(text)
            return inspect(path)

    def test_overlap_and_simultaneous_retire_issue(self):
        result = self.parse(TRACE)
        self.assertEqual(result['duration_cycles'], 6)
        self.assertEqual(result['dma_and_input_overlap_cycles'], 4)
        self.assertEqual(result['children']['input_read']['issued'], 2)
        self.assertEqual(result['children']['input_read']['max_outstanding'], 1)

    def test_reject_bad_busy(self):
        with self.assertRaises(ValueError):
            self.parse(TRACE.replace('busy=100001', 'busy=000001', 1))

    def test_reject_unknown(self):
        with self.assertRaises(ValueError):
            self.parse(TRACE.replace('issue=100001', 'issue=x00001'))

    def test_reject_missing_done(self):
        with self.assertRaises(ValueError):
            self.parse('\n'.join(TRACE.splitlines()[:-1])+'\n')

    def test_reject_time_reversal(self):
        with self.assertRaises(ValueError):
            self.parse(TRACE.replace('t=50000', 't=20000'))

if __name__ == '__main__':
    unittest.main()
