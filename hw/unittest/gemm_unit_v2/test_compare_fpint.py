"""Host-side tests of the three-way verdict and completeness checks."""

import contextlib
import csv
import io
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from compare_fpint import check, save_json, ulp_distance
from fpint_versions import gemm, qrow_input_scale, QROW_FP32_SCALE_V1


class ComparisonVerdictTest(unittest.TestCase):
    def fixture(self, root, rtl="3c00", reference="3c00", python=0x3c00):
        save_json(root / "cases.json", [dict(id=0, m=1, n=1, tiles=1, initial_psum=0)])
        save_json(root / "rtl_config.json", dict(mxu_k=16, mxu_n=16,
                  qblock=16, extra_bits=19, fp16_output_scale=0))
        (root / "vectors").mkdir()
        np.savez(root / "vectors/0000.npz", python_bits=np.array([[python]], np.uint16))
        with (root / "rtl_reference.csv").open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["case", "m", "n", "rtl_bits", "sv_ref_bits", "rtl_fp32_bits"])
            writer.writerow([0, 0, 0, rtl, reference, "3f800000"])
        (root / "rtl_psums.csv").write_text("case,tile,m,n,fp32_bits\n0,0,0,0,3f800000\n")

    def verdict(self, root):
        with contextlib.redirect_stdout(io.StringIO()):
            return check(root)

    def test_exact_pass_and_one_bit_mismatch_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.assertTrue(self.verdict(root))
            np.savez(root / "vectors/0000.npz", python_bits=np.array([[0x3c01]], np.uint16))
            self.assertFalse(self.verdict(root))
            summary = json.loads((root / "summary.json").read_text())
            self.assertEqual(summary["rtl_python_bit_mismatches"], 1)
            self.assertEqual(summary["python_reference_failures"], 0)

    def test_reference_failure_even_when_rtl_python_agree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, reference="4000")
            self.assertFalse(self.verdict(root))
            summary = json.loads((root / "summary.json").read_text())
            self.assertEqual(summary["rtl_python_bit_mismatches"], 0)
            self.assertEqual(summary["rtl_reference_failures"], 1)
            self.assertEqual(summary["python_reference_failures"], 1)

    def test_zero_absolute_tolerance_and_signed_zero_bits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, rtl="0001", reference="0000", python=1)
            self.assertTrue(self.verdict(root))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, rtl="8000", reference="0000", python=0)
            self.assertFalse(self.verdict(root))
            self.assertEqual(int(ulp_distance(0, 0x8000)), 0)

    def test_nonfinite_output_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, rtl="7c00", reference="0000", python=0x7c00)
            self.assertFalse(self.verdict(root))
            summary = json.loads((root / "summary.json").read_text())
            self.assertEqual(summary["nonfinite_outputs"], 1)

    def test_missing_or_duplicate_coordinates_are_execution_errors(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                path = root / "rtl_reference.csv"
                lines = path.read_text().splitlines()
                path.write_text("\n".join(lines + lines[1:] if duplicate else lines[:1]) + "\n")
                with self.assertRaisesRegex(ValueError, "coordinates"):
                    self.verdict(root)

    def test_missing_tile_trace_is_an_execution_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / "rtl_psums.csv").write_text("case,tile,m,n,fp32_bits\n")
            with self.assertRaisesRegex(ValueError, "partial-sum coordinates"):
                self.verdict(root)


class VersionedVerdictTest(unittest.TestCase):
    verdict = ComparisonVerdictTest.verdict

    def fixture(self, root, **kwargs):
        ComparisonVerdictTest.fixture(self, root, **kwargs)
        for filename in ("cases.json", "rtl_config.json"):
            value = json.loads((root / filename).read_text())
            target = value[0] if isinstance(value, list) else value
            target["version"] = "rtl-c4-v1"
            if filename == "rtl_config.json":
                target.update(block_size=1, selected_width=12)
            save_json(root / filename, value)
        save_json(root / "metadata.json", dict(version="rtl-c4-v1"))
        np.savez(root / "vectors/0000.npz",
                 python_bits=np.array([[0x3c00]], np.uint16),
                 cuda_bits=np.array([[0x3c00]], np.uint16),
                 python_psums=np.array([[[0x3f800000]]], np.uint32),
                 cuda_psums=np.array([[[0x3f800000]]], np.uint32))
        (root / "sv_psums.csv").write_text("case,tile,m,n,fp32_bits\n0,0,0,0,3f800000\n")

    def test_strict_outputs_and_intermediate_bits(self):
        for key in ("python_bits", "cuda_bits", "python_psums", "cuda_psums", "sv_output", "sv_trace"):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                self.assertTrue(self.verdict(root))
                if key == "sv_output":
                    path = root / "rtl_reference.csv"
                    path.write_text(path.read_text().replace("3c00,3c00", "3c00,3c01"))
                elif key == "sv_trace":
                    path = root / "sv_psums.csv"
                    path.write_text(path.read_text().replace("3f800000", "3f800001"))
                else:
                    path = root / "vectors/0000.npz"
                    with np.load(path) as data:
                        values = dict(data)
                    values[key].flat[0] ^= 1
                    np.savez(path, **values)
                self.assertFalse(self.verdict(root))

    def test_version_and_missing_cuda_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            with self.assertRaisesRegex(ValueError, "versions disagree"):
                check(root, "legacy")
            save_json(root / "metadata.json", dict(version="legacy"))
            with self.assertRaisesRegex(ValueError, "mismatch"):
                check(root, "rtl-c4-v1")
            save_json(root / "metadata.json", dict(version="rtl-c4-v1"))
            np.savez(root / "vectors/0000.npz", python_bits=np.array([[0x3c00]], np.uint16))
            with self.assertRaises(KeyError):
                self.verdict(root)

    def test_fp32_scale_version_without_cuda_and_scaling_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            for name in ("cases.json", "rtl_config.json", "metadata.json"):
                data = json.loads((root / name).read_text())
                target = data[0] if isinstance(data, list) else data
                target["version"] = QROW_FP32_SCALE_V1
                save_json(root / name, data)
            path = root / "vectors/0000.npz"
            with np.load(path) as data:
                arrays = {k.replace("cuda", "python_c4"): data[k] for k in data.files}
            np.savez(path, **arrays)
            save_json(root / "scaling_python.json", dict(pairs=1, mismatches=0, excluded_overflow=0))
            save_json(root / "scaling_sv.json", dict(pairs=1, old_mismatches=0, new_mismatches=0))
            self.assertTrue(self.verdict(root))
            save_json(root / "scaling_sv.json", dict(pairs=1, old_mismatches=0, new_mismatches=1))
            self.assertFalse(self.verdict(root))


class VersionedArithmeticTest(unittest.TestCase):
    def inputs(self, k=16):
        return (np.full((1, k), 0x3c00, np.uint16), np.ones((k, 16), np.int8),
                np.full((k//16, 16), 0x3c00, np.uint16), np.zeros((k//16, 16), np.int16))

    def test_qcol_zero_and_subnormal_scale_preserve_rtl_rebias(self):
        a, w, s, z = self.inputs()
        s.fill(0)
        s[0, 1] = 1
        out, trace = gemm(a, w, s, z, qdir=0, version="rtl-c4-v1")
        self.assertEqual(int(out[0, 0]), 0x1000)  # 16 * 2^-15
        self.assertEqual(int(out[0, 1]), 0x1001)
        self.assertEqual(int(trace[0, 0, 0]), 0x3a000000)

    def test_load_and_explicit_zero_add_have_distinct_zero_sign(self):
        a, w, s, z = self.inputs()
        a.fill(0)
        s.fill(0xbc00)
        loaded, _ = gemm(a, w, s, z, qdir=0, version="rtl-c4-v1")
        added, _ = gemm(a, w, s, z, qdir=0, version="rtl-c4-v1",
                        initial_psum=np.zeros((1, 16), np.uint32))
        np.testing.assert_array_equal(loaded, np.full((1, 16), 0x8000, np.uint16))
        np.testing.assert_array_equal(added, np.zeros((1, 16), np.uint16))

    def test_qrow_fp16_input_scaling_and_fp32_tile_accumulation(self):
        a, w, _, _ = self.inputs(64)
        s = np.full((64, 1), 0x3c00, np.uint16)
        z = np.zeros((64, 1), np.int16)
        a.fill(0)
        a[0, [0, 16, 32]] = np.array([512, 2**-16, -512], np.float16).view(np.uint16)
        out, trace = gemm(a, w, s, z, qdir=1, version="rtl-c4-v1")
        self.assertEqual(list(trace[:, 0, 0]), [0x44000000, 0x44000000, 0, 0])
        self.assertTrue(np.all(out == 0))
        # A halfway product at the min-subnormal boundary rounds to zero before
        # the INT4 multiply; scaling after the dot would instead give 2^-24.
        a.fill(0)
        a[0, 0] = 1
        s.fill(0x3800)
        w.fill(2)
        out, _ = gemm(a, w, s, z, qdir=1, version="rtl-c4-v1")
        self.assertTrue(np.all(out == 0))

    def test_fp32_prescaling_all_finite_inputs_at_boundary_scales(self):
        a = np.arange(65536, dtype=np.uint16)
        a = a[(a & 0x7c00) != 0x7c00]
        for scale in (0, 0x8000, 1, 0x8001, 0x3ff, 0x400, 0x3800, 0xbc00, 0x3c01, 0x7bff):
            with self.subTest(scale=scale), np.errstate(over="ignore"):
                s = np.full(a.shape, scale, np.uint16)
                old = qrow_input_scale(a, s, version="rtl-c4-v1")
                new = qrow_input_scale(a, s, version=QROW_FP32_SCALE_V1)
                finite = (old & 0x7c00) != 0x7c00
                np.testing.assert_array_equal(new[finite], old[finite])

    def test_fp32_prescaling_long_matrix_matches_c4(self):
        rng = np.random.default_rng(20260729)
        m, k = 16, 32768
        a = rng.uniform(-2, 2, (m, k)).astype(np.float16).view(np.uint16)
        w = rng.integers(-8, 8, (k, 16), dtype=np.int8)
        s = rng.uniform(2**-14, 2**-11, (k, 1)).astype(np.float16).view(np.uint16)
        z = rng.integers(-4, 4, (k, 1), dtype=np.int16)
        old = gemm(a, w, s, z, qdir=1, version="rtl-c4-v1")
        new = gemm(a, w, s, z, qdir=1, version=QROW_FP32_SCALE_V1)
        for expected, actual in zip(old, new):
            np.testing.assert_array_equal(actual, expected)


if __name__ == "__main__":
    unittest.main()
