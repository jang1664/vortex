import tempfile
import unittest
from pathlib import Path

from tools.gemm_command_overlap_summary import markdown_report, read_trace


TRACE = """
GEMM_CMD_PERF_SUMMARY | {inst=g0, job=0, entry=7, cycles=30, emitted=1, issued=1, completed=1, incomplete=0, max_concurrent=1, compute_pipeline_cycles=8}
GEMM_CMD_TIMELINE | {inst=g0, job=0, uid=0, class=COMPUTE_ARM, emit=2, issue=4, done=14, queue=2, service=10, total=12, overlap_any=3}
GEMM_TILE_OVERLAP | {inst=g0, job=0, tile=0, preload_next_compute=4, preload_tail=0, tile_ready_slack=2, store_next_compute=5, store_next_load=0, store_later_load=0, store_tail=1, final_store_drain=0}
TMEM_DMA_CMD_PERF | {inst=g0, serial=0, tag=0, op=LOAD, accept=1, first_select=2, first_descriptor=4, complete=9, total=8, pending_cycles=1, descriptor_active_cycles=5, paused_cycles=0, chunks=1, chunkable=0, bypass=0}
"""


class GemmCommandOverlapSummaryTest(unittest.TestCase):
    def test_parse_validate_and_render(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "m256.log"
            path.write_text(TRACE, encoding="utf-8")
            trace = read_trace(path, "M=256")
        self.assertEqual(trace.commands[0]["service"], 10)
        self.assertEqual(trace.dma[0]["descriptor_active_cycles"], 5)
        report = markdown_report([trace])
        self.assertIn("M=256", report)
        self.assertIn("Store ∩ next compute", report)

    def test_rejects_incomplete_lifecycle(self):
        bad = TRACE.replace("incomplete=0", "incomplete=1")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.log"
            path.write_text(bad, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "lifecycle accounting mismatch"):
                read_trace(path, "bad")


if __name__ == "__main__":
    unittest.main()
