"""Performance schema tests independent of hardware access."""
import json
from pathlib import Path
import tempfile
import unittest

from hbm_performance_profile import load_profile


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self.profile = {
            'schema_version': 1, 'name': 'schema-test',
            'status': 'documentation-based', 'dram_frequency_hz': 900000000,
            'hbm_axi_frequency_hz': 450000000,
            'port_read_bytes_per_second': 14400000000,
            'port_write_bytes_per_second': 14400000000,
            'aggregate_read_bytes_per_second': 460800000000,
            'aggregate_write_bytes_per_second': 460800000000,
            'aggregate_shared_bytes_per_second': 460800000000,
            'burst_bytes': 64, 'aggregate_burst_bytes': 1024, 'read_residual_ps': 0,
            'latency_reference': 'Test fixture, no claimed latency calibration',
            'provenance': 'PG276 interface bounds; schema validation only',
        }

    def load(self):
        with tempfile.TemporaryDirectory(prefix='hbm-profile-') as directory:
            path = Path(directory) / 'profile.json'
            path.write_text(json.dumps(self.profile))
            return load_profile(path)

    def test_valid_and_hash(self):
        first = self.load()
        self.assertEqual(first['dram_frequency_hz'], 900000000)
        self.assertEqual(len(first['source_sha256']), 64)
        self.profile['read_residual_ps'] = 1
        self.assertNotEqual(first['source_sha256'], self.load()['source_sha256'])

    def test_adopted_workload_profile_parameters(self):
        root = Path(__file__).resolve().parent
        adopted = load_profile(root / 'profiles/u55c-temp-100mhz-workload-v1.json')
        frozen = load_profile(root.parents[1] / 'agent-tasks/u55c-hbm-performance-calibration/profiles/read-plus400ns.json')
        self.assertEqual(adopted['status'], 'hardware-calibrated')
        for key, value in frozen.items():
            if type(value) is int:
                self.assertEqual(adopted[key], value, key)

    def test_explicit_diagnostic_status(self):
        self.profile['status'] = 'diagnostic-only'
        self.assertEqual(self.load()['status'], 'diagnostic-only')
        self.profile['status'] = 'unverified-other'
        with self.assertRaises(ValueError):
            self.load()

    def test_invalid_numeric_inputs(self):
        for field in ('dram_frequency_hz', 'burst_bytes', 'port_read_bytes_per_second'):
            original = self.profile[field]
            for value in (0, -1, True, '32', 1.5, 1 << 63):
                with self.subTest(field=field, value=value):
                    self.profile[field] = value
                    with self.assertRaises(ValueError): self.load()
            self.profile[field] = original

    def test_bounds(self):
        for field, value in (
            ('dram_frequency_hz', 800000000), ('hbm_axi_frequency_hz', 500000000),
            ('burst_bytes', 33), ('burst_bytes', 8192), ('read_residual_ps', -1),
            ('port_read_bytes_per_second', 14400000001),
            ('aggregate_write_bytes_per_second', 460800000001),
            ('aggregate_shared_bytes_per_second', 460800000001),
        ):
            with self.subTest(field=field, value=value):
                original = self.profile[field]
                self.profile[field] = value
                with self.assertRaises(ValueError): self.load()
                self.profile[field] = original

    def test_provenance_and_unknown_fields(self):
        for field in ('name', 'status', 'latency_reference', 'provenance'):
            original = self.profile[field]
            self.profile[field] = ''
            with self.assertRaises(ValueError): self.load()
            self.profile[field] = original
        self.profile['typo'] = 1
        with self.assertRaises(ValueError): self.load()


if __name__ == '__main__':
    unittest.main()
