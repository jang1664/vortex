from __future__ import annotations

from contextlib import redirect_stdout
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import generation
import model_sessions as sessions
import pipeline
import workflow


class ModelSessionsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.settings = pipeline.PipelineSettings(
            tag="test", workspace=self.root / "repo/analysis_workspace/latency_on_hw",
            state_base=self.root, python=sys.executable)

    def test_generation_defaults_and_overrides_match_make_case(self):
        full = generation.workload_arguments("full", "exact", 16)
        values = dict(zip(full[::2], full[1::2]))
        self.assertEqual("1,4,64", values["--generation-batches"])
        self.assertEqual("1024,2048,4096,8192,16384,32768", values["--prefill-seq-lens"])
        self.assertEqual("exact", values["--decode-measurement"])
        quick = generation.workload_arguments("quick", "sampled", 32, (
            "--batches", "2", "--seq-lens", "512", "--generation-batches", "4",
            "--fpga-bin-by-app", "softmax=C1", "--fpga-bin-by-app", "silu=C1"))
        values = dict(zip(quick[::2], quick[1::2]))
        self.assertEqual("2", values["--prefill-batches"])
        self.assertEqual("4", values["--generation-batches"])
        self.assertEqual("512", values["--prefill-seq-lens"])
        self.assertEqual("512", values["--generation-seq-lens"])
        self.assertEqual(2, quick.count("--fpga-bin-by-app"))

    def test_generation_receipt_tracks_image_options_and_output_corruption(self):
        snapshot = {"candidates": {"C1": {"sha": "image-a"}}}
        with mock.patch("tools.latency_bench.candidate_map.resolve_candidate_map", return_value=snapshot):
            task = pipeline._generate_tasks(replace(self.settings, models=("llama2",)))[0]
        task.outputs[0].path.mkdir(parents=True)
        payload = task.outputs[0].path / "index.yaml"
        payload.write_text("generated: []\n")
        store = pipeline.ReceiptStore(self.settings.state_root)
        store.publish(pipeline.completed_receipt(task, attempt_id="fixture"))
        self.assertEqual(pipeline.Decision.REUSE, pipeline.inspect_task(task, store).decision)
        with mock.patch("tools.latency_bench.candidate_map.resolve_candidate_map",
                        return_value={"candidates": {"C1": {"sha": "image-b"}}}):
            changed = pipeline._generate_tasks(replace(self.settings, models=("llama2",)))[0]
        self.assertEqual(pipeline.Decision.PENDING, pipeline.inspect_task(changed, store).decision)
        payload.write_text("corrupted\n")
        self.assertEqual(pipeline.Decision.PENDING, pipeline.inspect_task(task, store).decision)

    def test_top_level_rejects_slurm_allocation_even_for_dry_run(self):
        with mock.patch.dict(os.environ, {"SLURM_JOB_ID": "123"}), mock.patch("sys.stderr", new=io.StringIO()):
            self.assertEqual(2, workflow.main(["pipeline", "--tag", "test", "--dry-run"]))
        self.assertFalse(self.settings.state_root.exists())

    def test_availability_counts_free_gres_and_rejects_drained_nodes(self):
        output = ("NodeName=a State=MIXED Partitions=fpga CfgTRES=gres/fpga:u55c=2 "
                  "AllocTRES=gres/fpga:u55c=1 CPUEfctv=16 CPUAlloc=4 RealMemory=64000 AllocMem=16000\n"
                  "NodeName=b State=IDLE+DRAIN Partitions=fpga CfgTRES=gres/fpga:u55c=2 "
                  "AllocTRES= CPUEfctv=16 CPUAlloc=0 RealMemory=64000 AllocMem=0\n")
        with mock.patch.object(sessions.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output)):
            self.assertEqual(1, sessions.available_fpga_slots(sessions.SlurmSettings()))
        self.assertEqual(16384, sessions.memory_mb("16G"))

    def test_parallel_unavailable_errors_or_falls_back_explicitly(self):
        models = ("llama2", "llama3")
        options = sessions.SlurmSettings(model_execution="parallel")
        self.assertEqual("parallel", sessions.execution_mode(options, models, 2))
        with self.assertRaisesRegex(ValueError, "found 1"):
            sessions.execution_mode(options, models, 1)
        self.assertEqual("serial", sessions.execution_mode(replace(options, parallel_fallback="serial"), models, 1))

    def test_board_pin_survives_resume_and_rejects_another_board(self):
        identity = {"hostname": "fpga", "xrt_device_index": "0", "xrt_device_bdf": "0000:2a:00.1"}
        sessions.pin_model(self.settings, "llama2", identity)
        sessions.pin_model(self.settings, "llama2", identity)
        with self.assertRaisesRegex(ValueError, "original FPGA"):
            sessions.pin_model(self.settings, "llama2", dict(identity, xrt_device_bdf="0000:3d:00.1"))

    def test_historical_board_evidence_is_checked_before_new_pin(self):
        path = self.settings.result_root("llama2") / "C1/run/fpga_identity.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"hostname": "fpga", "xrt_device_bdf": "old"}))
        with self.assertRaisesRegex(ValueError, "original FPGA"):
            sessions.pin_model(self.settings, "llama2", {"hostname": "fpga", "xrt_device_bdf": "new"})
        self.assertFalse((self.settings.result_root("llama2") / "model_fpga.json").exists())

    def test_board_pin_cannot_be_bypassed_by_changing_state_root(self):
        identity = {"hostname": "fpga", "xrt_device_index": "0", "xrt_device_bdf": "board-a"}
        sessions.pin_model(self.settings, "llama2", identity)
        with self.assertRaisesRegex(ValueError, "original FPGA"):
            sessions.pin_model(replace(self.settings, state_base=self.root / "other-state"),
                               "llama2", dict(identity, xrt_device_bdf="board-b"))

    def test_successful_historical_rows_need_run_identity_evidence(self):
        path = self.settings.result_root("llama2") / "C1/raw_db.csv"
        path.parent.mkdir(parents=True)
        path.write_text("status,run_id\npass,missing-run\n")
        with self.assertRaisesRegex(ValueError, "no fpga_identity.json"):
            sessions.pin_model(self.settings, "llama2", {"hostname": "fpga", "xrt_device_bdf": "board"})

    def test_worker_runs_all_stages_of_each_model_on_one_allocation(self):
        request = self.root / "request.json"
        result = self.root / "summary.json"
        request.write_text(json.dumps({"settings": sessions._settings_payload(self.settings),
                                      "first": "run", "last": "refine", "rerun": None,
                                      "summary_path": str(result)}))
        seen = []
        def execute(settings, **kwargs):
            seen.append((settings.models, kwargs["first"], kwargs["last"], os.environ["SLURM_JOB_ID"]))
            return 0, {"model": settings.models[0]}
        identity = {"hostname": "fpga", "xrt_device_index": "0", "xrt_device_bdf": "board"}
        with mock.patch.dict(os.environ, {"SLURM_JOB_ID": "123"}), \
                mock.patch.object(sessions, "capture_identity", return_value=identity), \
                mock.patch.object(pipeline, "run_pipeline", side_effect=execute):
            self.assertEqual(0, sessions.worker_main([str(request)]))
        self.assertEqual([(("llama2",), "run", "refine", "123"),
                          (("llama3",), "run", "refine", "123")], seen)

    def _session_starter(self, records):
        class Child:
            returncode = 0
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def poll(self): return self.returncode
            def wait(self): return self.returncode
        def start(command, **kwargs):
            request = json.loads(Path(command[-1]).read_text())
            records.append((command, request))
            Path(request["summary_path"]).write_text(json.dumps({"exit_code": 0}))
            return Child()
        return start

    def test_serial_models_use_one_srun_and_parallel_models_use_two(self):
        for mode, count in (("serial", 1), ("parallel", 2)):
            records = []
            with mock.patch.object(sessions, "_hardware_pending", return_value=True), \
                    mock.patch.object(sessions, "available_fpga_slots", return_value=2), \
                    mock.patch.object(pipeline.OwnedProcess, "start", side_effect=self._session_starter(records)), \
                    redirect_stdout(io.StringIO()):
                code, _ = sessions.run_sessions(self.settings, sessions.SlurmSettings(model_execution=mode),
                                                "run", "refine", None, mode)
            self.assertEqual(0, code)
            self.assertEqual(count, len(records))
            for command, request in records:
                self.assertEqual("srun", command[0])
                self.assertIn("--gres=fpga:u55c:1", command)
                self.assertEqual("refine", request["last"])
            self.assertEqual(["llama2", "llama3"], [model for _, r in records for model in r["settings"]["models"]])

    def test_unavailable_parallel_launches_no_sessions_and_fallback_uses_one(self):
        for fallback in ("error", "serial"):
            records = []
            options = sessions.SlurmSettings(model_execution="parallel", parallel_fallback=fallback)
            with mock.patch.object(sessions, "_hardware_pending", return_value=True), \
                    mock.patch.object(sessions, "available_fpga_slots", return_value=1), \
                    mock.patch.object(pipeline.OwnedProcess, "start", side_effect=self._session_starter(records)), \
                    redirect_stdout(io.StringIO()):
                if fallback == "error":
                    with self.assertRaises(ValueError):
                        sessions.run_sessions(self.settings, options, "run", "refine", None, "parallel")
                    self.assertEqual([], records)
                else:
                    code, result = sessions.run_sessions(self.settings, options, "run", "refine", None, "parallel")
                    self.assertEqual(0, code)
                    self.assertEqual("serial", result["mode"])
                    self.assertEqual(1, len(records))

    def test_complete_models_reuse_receipts_without_querying_or_allocating_slurm(self):
        with mock.patch.object(sessions, "_hardware_pending", return_value=False), \
                mock.patch.object(sessions, "available_fpga_slots") as query, \
                mock.patch.object(pipeline.OwnedProcess, "start") as start, \
                mock.patch.object(pipeline, "run_pipeline", return_value=(0, {"reused": True})):
            code, result = sessions.run_sessions(self.settings, sessions.SlurmSettings(), "run", "refine", None, "parallel")
        self.assertEqual(0, code)
        self.assertFalse(result["allocated"])
        query.assert_not_called()
        start.assert_not_called()

    def test_generation_and_plot_run_on_host_around_model_sessions(self):
        seen = []
        def host(_settings, **kwargs):
            sessions.reject_allocation()
            seen.append((kwargs["first"], kwargs["last"]))
            return 0, {}
        with mock.patch.dict(os.environ, {"SLURM_JOB_ID": "", "SLURM_STEP_ID": ""}), \
                mock.patch.object(pipeline, "run_pipeline", side_effect=host), \
                mock.patch.object(sessions, "run_sessions", return_value=(0, {})) as hardware:
            code, _ = sessions.coordinate(self.settings, sessions.SlurmSettings(),
                                            first="generate", last="plot", rerun=None, inspect_only=False)
        self.assertEqual(0, code)
        self.assertEqual([("generate", "generate"), ("compose", "plot")], seen)
        self.assertEqual(("run", "refine", None, "serial"), hardware.call_args.args[2:])

    def test_parallel_capacity_failure_happens_before_generation(self):
        with mock.patch.object(sessions, "_hardware_pending", return_value=True), \
                mock.patch.object(sessions, "available_fpga_slots", return_value=1), \
                mock.patch.object(pipeline, "run_pipeline") as stage:
            with self.assertRaisesRegex(ValueError, "found 1"):
                sessions.coordinate(self.settings, sessions.SlurmSettings(model_execution="parallel"),
                                    first="generate", last="plot", rerun=None, inspect_only=False)
        stage.assert_not_called()

    def test_cli_forwards_generation_and_allocation_controls(self):
        output = io.StringIO()
        with redirect_stdout(output), mock.patch.object(sessions, "coordinate", return_value=(0, {})) as run:
            code = workflow.main([
                "pipeline", "--tag", "test", "--workspace", str(self.settings.workspace),
                "--decode-measurement", "exact", "--decode-sample-interval", "8",
                "--batch-list", "2", "--prefill-seq-lens", "512",
                "--generation-out-tokens", "4", "--generation-max-seq-len", "32768",
                "--output-format", "yaml", "--fpga-bin-by-kernel", "softmax=C1",
                "--model-execution", "parallel", "--parallel-fallback", "serial",
                "--slurm-cpus", "8", "--slurm-mem", "32G", "--allocation-wait", "5",
            ])
        self.assertEqual(0, code)
        settings, options = run.call_args.args
        self.assertEqual("exact", settings.decode_measurement)
        self.assertEqual(8, settings.decode_sample_interval)
        self.assertEqual(4, settings.out_tokens)
        self.assertEqual("yaml", settings.output_format)
        self.assertIn("--batches", settings.generation_options)
        self.assertIn("--fpga-bin-by-kind", settings.generation_options)
        self.assertEqual(("parallel", "serial", 8, "32G", 5),
                         (options.model_execution, options.parallel_fallback, options.cpus,
                          options.memory, options.allocation_wait))

    def test_parallel_peer_failure_cancels_running_session(self):
        children = []
        class Child:
            def __init__(self, failure): self.failure, self.returncode = failure, None
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def poll(self):
                if self.failure: self.returncode = 7
                return self.returncode
            def terminate(self): self.returncode = 143
            def wait(self): return self.returncode
        def start(_command, **_kwargs):
            child = Child(bool(children))
            children.append(child)
            return child
        with mock.patch.object(sessions, "_hardware_pending", return_value=True), \
                mock.patch.object(sessions, "available_fpga_slots", return_value=2), \
                mock.patch.object(pipeline.OwnedProcess, "start", side_effect=start), \
                redirect_stdout(io.StringIO()):
            code, result = sessions.run_sessions(self.settings, sessions.SlurmSettings(model_execution="parallel"),
                                                "run", "refine", None, "parallel")
        self.assertEqual(1, code)
        self.assertEqual(143, children[0].returncode)
        self.assertEqual([143, 7], [r["exit_code"] for r in result["sessions"]])


if __name__ == "__main__":
    unittest.main()
