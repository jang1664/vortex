"""Validate explicit, provenance-bearing HBM performance profiles."""
import hashlib
import json
from pathlib import Path


def load_profile(filename):
    path = Path(filename)
    raw = path.read_bytes()
    profile = json.loads(raw)
    required = {
        'schema_version', 'name', 'status', 'dram_frequency_hz',
        'hbm_axi_frequency_hz', 'port_read_bytes_per_second',
        'port_write_bytes_per_second', 'aggregate_read_bytes_per_second',
        'aggregate_write_bytes_per_second', 'aggregate_shared_bytes_per_second',
        'burst_bytes', 'aggregate_burst_bytes', 'read_residual_ps', 'latency_reference', 'provenance',
    }
    if not isinstance(profile, dict) or set(profile) != required:
        raise ValueError('Performance profile must contain exactly the documented schema fields')
    if type(profile['schema_version']) is not int or profile['schema_version'] != 1:
        raise ValueError('Unsupported performance profile schema')
    if profile['status'] not in ('documentation-based', 'hardware-calibrated', 'diagnostic-only'):
        raise ValueError('Profile status must distinguish documented, measured and diagnostic values')
    for key in ('name', 'latency_reference', 'provenance'):
        if not isinstance(profile[key], str) or not profile[key].strip():
            raise ValueError(f'Profile {key} must describe its provenance/meaning')
    integers = required - {'schema_version', 'name', 'status', 'latency_reference', 'provenance'}
    for key in integers:
        value = profile[key]
        minimum = 0 if key == 'read_residual_ps' else 1
        if type(value) is not int or not minimum <= value <= (1 << 63) - 1:
            raise ValueError(f'Profile {key} must be an integer in [{minimum}, 2^63-1]')
    if profile['dram_frequency_hz'] not in (900000000, 1000000000):
        raise ValueError('Supported DRAM frequencies are 900 MHz and legacy 1 GHz')
    if profile['hbm_axi_frequency_hz'] > 450000000:
        raise ValueError('U55C HBM AXI frequency exceeds the PG276 450 MHz limit')
    if not 32 <= profile['burst_bytes'] <= 4096 or profile['burst_bytes'] % 32:
        raise ValueError('Burst credit must be a 32-byte multiple between 32 and 4096 bytes')
    if not profile['burst_bytes'] <= profile['aggregate_burst_bytes'] <= 131072 or profile['aggregate_burst_bytes'] % 32:
        raise ValueError('Aggregate burst credit must be a 32-byte multiple between port credit and 128 KiB')
    port_bound = 32 * profile['hbm_axi_frequency_hz']
    card_bound = 512 * profile['dram_frequency_hz']
    for direction in ('read', 'write'):
        if profile[f'port_{direction}_bytes_per_second'] > port_bound:
            raise ValueError('Port budget exceeds HBM AXI raw capacity')
        if profile[f'aggregate_{direction}_bytes_per_second'] > card_bound:
            raise ValueError('Aggregate budget exceeds physical raw capacity')
    if profile['aggregate_shared_bytes_per_second'] > card_bound:
        raise ValueError('Shared budget exceeds physical raw capacity')
    return {**profile, 'source_sha256': hashlib.sha256(raw).hexdigest()}
