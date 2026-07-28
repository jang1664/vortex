from __future__ import annotations

import unittest

import yaml

from tools.latency_bench.yaml_io import (
    CSafeDumper,
    CSafeLoader,
    safe_dump,
    safe_load,
)


class YamlIoTest(unittest.TestCase):
    def test_requires_libyaml_safe_implementations(self) -> None:
        self.assertTrue(yaml.__with_libyaml__)
        self.assertIs(yaml.CSafeLoader, CSafeLoader)
        self.assertIs(yaml.CSafeDumper, CSafeDumper)

    def test_round_trip_preserves_nested_suite_values(self) -> None:
        value = {
            "name": "latency_suite",
            "defaults": {"warmup": 1, "enabled": True, "label": "C4"},
            "cases": [
                {
                    "id": "case_1",
                    "args": "-n 128 --message 'unicode value'",
                    "shape": {"m": 1, "n": 128, "ratio": 0.5},
                }
            ],
        }

        encoded = safe_dump(value, sort_keys=False)

        self.assertEqual(value, safe_load(encoded))
        self.assertLess(encoded.index("name:"), encoded.index("defaults:"))

    def test_loader_rejects_unsafe_python_object_tags(self) -> None:
        payload = "!!python/object/apply:builtins.eval ['1 + 1']"

        with self.assertRaises(yaml.constructor.ConstructorError):
            safe_load(payload)


if __name__ == "__main__":
    unittest.main()
