from __future__ import annotations

import csv
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import pipeline
import workflow
from tools.latency_bench.raw_db import RAW_DB_COLUMNS
from tools.latency_bench.runner import (
    ExecutionUnit,
    MeasurementCoverage,
    MeasurementEvidence,
    MeasurementReuseState,
    StrictMeasurementPolicy,
)


class PipelineReceiptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _task(self) -> pipeline.TaskSpec:
        source = self.root / "input.json"
        output = self.root / "result.csv"
        source.write_text('{"value": 1}\n')
        output.write_text("case_id,latency\na,1.0\n")
        return pipeline.TaskSpec(
            key="compose:llama2",
            stage="compose",
            inputs={"suite": pipeline.content_identity(source)},
            effective_parameters={"select": "strict"},
            outputs=(pipeline.OutputSpec(output, "file", allow_empty=False),),
            resources=(self.root / "published",),
            command=("compose", "--model", "llama2"),
            metadata={"model": "llama2"},
        )

    def test_matching_receipt_and_output_manifest_are_reused(self) -> None:
        task = self._task()
        store = pipeline.ReceiptStore(self.root / "pipeline_state.tag-a")
        store.publish(pipeline.completed_receipt(task, attempt_id="attempt-1"))

        decisions = pipeline.plan_tasks((task,), store)

        self.assertEqual(1, len(decisions))
        self.assertEqual(pipeline.Decision.REUSE, decisions[0].decision)
        self.assertIn("validated", decisions[0].reason)

    def test_changed_input_identity_invalidates_receipt(self) -> None:
        task = self._task()
        store = pipeline.ReceiptStore(self.root / "state")
        store.publish(pipeline.completed_receipt(task, attempt_id="attempt-1"))
        (self.root / "input.json").write_text('{"value": 2}\n')
        changed = pipeline.TaskSpec(
            key=task.key,
            stage=task.stage,
            inputs={"suite": pipeline.content_identity(self.root / "input.json")},
            effective_parameters=task.effective_parameters,
            outputs=task.outputs,
            resources=task.resources,
        )

        decision = pipeline.inspect_task(changed, store)

        self.assertEqual(pipeline.Decision.PENDING, decision.decision)
        self.assertIn("input", decision.reason)

    def test_missing_wrong_type_empty_and_changed_outputs_do_not_reuse(self) -> None:
        task = self._task()
        store = pipeline.ReceiptStore(self.root / "state")
        store.publish(pipeline.completed_receipt(task, attempt_id="attempt-1"))
        output = task.outputs[0].path

        output.unlink()
        decision = pipeline.inspect_task(task, store)
        self.assertEqual(pipeline.Decision.PENDING, decision.decision)
        self.assertIn("missing", decision.reason)

        output.mkdir()
        decision = pipeline.inspect_task(task, store)
        self.assertEqual(pipeline.Decision.PENDING, decision.decision)
        self.assertIn("expected file", decision.reason)

        output.rmdir()
        output.touch()
        decision = pipeline.inspect_task(task, store)
        self.assertEqual(pipeline.Decision.PENDING, decision.decision)
        self.assertIn("empty", decision.reason)

        output.write_text("case_id,latency\na,2.0\n")
        decision = pipeline.inspect_task(task, store)
        self.assertEqual(pipeline.Decision.PENDING, decision.decision)
        self.assertIn("content", decision.reason)

    def test_corrupt_and_unsupported_receipts_are_not_complete(self) -> None:
        task = self._task()
        store = pipeline.ReceiptStore(self.root / "state")
        receipt_path = store.path_for(task.key)
        receipt_path.parent.mkdir(parents=True)

        receipt_path.write_text("not json")
        corrupt = pipeline.inspect_task(task, store)
        self.assertEqual(pipeline.Decision.PENDING, corrupt.decision)
        self.assertIn("corrupt", corrupt.reason)

        receipt_path.write_text(
            json.dumps(
                {
                    "type": pipeline.RECEIPT_TYPE,
                    "schema_version": pipeline.RECEIPT_SCHEMA_VERSION + 1,
                }
            )
        )
        unsupported = pipeline.inspect_task(task, store)
        self.assertEqual(pipeline.Decision.PENDING, unsupported.decision)
        self.assertIn("unsupported", unsupported.reason)

        payload = pipeline.completed_receipt(task, attempt_id="attempt-1").to_dict()
        payload["effective_parameters"] = {"invalid_number": float("nan")}
        receipt_path.write_text(json.dumps(payload))
        malformed = pipeline.inspect_task(task, store)
        self.assertEqual(pipeline.Decision.PENDING, malformed.decision)
        self.assertIn("corrupt", malformed.reason)

    def test_completion_receipt_rejects_an_invalid_output(self) -> None:
        task = self._task()
        task.outputs[0].path.unlink()

        with self.assertRaisesRegex(pipeline.OutputValidationError, "missing"):
            pipeline.completed_receipt(task, attempt_id="attempt-1")

    def test_receipt_publication_is_atomic_and_round_trips_typed_fields(self) -> None:
        task = self._task()
        store = pipeline.ReceiptStore(self.root / "state")
        receipt = pipeline.completed_receipt(
            task,
            attempt_id="attempt-1",
            started_at="2026-09-17T00:00:00+00:00",
            completed_at="2026-09-17T00:01:00+00:00",
            exit_code=0,
            logs={"stdout": "attempt/stdout.log"},
        )

        store.publish(receipt)

        loaded = store.load(task.key)
        self.assertEqual(receipt, loaded)
        self.assertEqual([], list(store.root.glob(".*.tmp")))

    def test_failed_receipt_replace_preserves_previous_receipt(self) -> None:
        task = self._task()
        store = pipeline.ReceiptStore(self.root / "state")
        original = pipeline.completed_receipt(task, attempt_id="attempt-1")
        store.publish(original)
        replacement = pipeline.completed_receipt(task, attempt_id="attempt-2")

        with mock.patch.object(
            pipeline.os, "replace", side_effect=OSError("injected replace failure")
        ), self.assertRaisesRegex(OSError, "injected replace failure"):
            store.publish(replacement)

        self.assertEqual(original, store.load(task.key))
        self.assertEqual([], list(store.root.glob(".*.tmp")))

    def test_isolated_attempt_cannot_reuse_old_published_output(self) -> None:
        task = self._task()
        store = pipeline.ReceiptStore(self.root / "state")
        attempt = self.root / "attempt"
        attempt.mkdir()

        with self.assertRaisesRegex(pipeline.OutputValidationError, "attempt"):
            pipeline.publish_isolated_attempt(
                task,
                store=store,
                attempt_root=attempt,
                publication_root=self.root,
            )

        self.assertIsNone(store.load(task.key))

    def test_missing_requested_format_blocks_attempt_completion(self) -> None:
        output_root = self.root / "figures"
        png = output_root / "plot.png"
        pdf = output_root / "plot.pdf"
        task = pipeline.TaskSpec(
            key="plot:family",
            stage="plot",
            inputs={"prepared": pipeline.json_identity({"rows": 1})},
            effective_parameters={"formats": ["png", "pdf"]},
            outputs=(pipeline.OutputSpec(png), pipeline.OutputSpec(pdf)),
        )
        attempt = self.root / "attempt"
        attempt.mkdir()
        (attempt / "plot.png").write_text("new png")

        with self.assertRaisesRegex(pipeline.OutputValidationError, "plot.pdf"):
            pipeline.publish_isolated_attempt(
                task,
                store=pipeline.ReceiptStore(self.root / "state"),
                attempt_root=attempt,
                publication_root=output_root,
            )

    def test_interrupted_multifile_publication_never_publishes_receipt(self) -> None:
        output_root = self.root / "published"
        outputs = (output_root / "a.csv", output_root / "b.pdf")
        task = pipeline.TaskSpec(
            key="plot:family",
            stage="plot",
            inputs={"prepared": pipeline.json_identity({"rows": 1})},
            effective_parameters={},
            outputs=tuple(pipeline.OutputSpec(path) for path in outputs),
        )
        attempt = self.root / "attempt"
        attempt.mkdir()
        (attempt / "a.csv").write_text("new a")
        (attempt / "b.pdf").write_text("new b")
        store = pipeline.ReceiptStore(self.root / "state")
        replacements = 0
        real_replace = pipeline.os.replace

        def fail_second(source, destination):
            nonlocal replacements
            replacements += 1
            if replacements == 2:
                raise OSError("injected publication interruption")
            return real_replace(source, destination)

        with self.assertRaisesRegex(OSError, "publication interruption"):
            pipeline.publish_isolated_attempt(
                task,
                store=store,
                attempt_root=attempt,
                publication_root=output_root,
                replace=fail_second,
            )

        self.assertIsNone(store.load(task.key))

    def test_identical_rebuilt_input_content_keeps_plot_receipt_reusable(self) -> None:
        prepared = self.root / "prepared.csv"
        output = self.root / "plot.png"
        prepared.write_text("candidate,value\nC1,1\n")
        output.write_text("image")

        def plot_task() -> pipeline.TaskSpec:
            return pipeline.TaskSpec(
                key="plot:family",
                stage="plot",
                inputs={"prepared": pipeline.content_identity(prepared)},
                effective_parameters={"formats": ["png"]},
                outputs=(pipeline.OutputSpec(output),),
            )

        store = pipeline.ReceiptStore(self.root / "state")
        store.publish(pipeline.completed_receipt(plot_task()))
        prepared.write_text("candidate,value\nC1,1\n")

        self.assertEqual(
            pipeline.Decision.REUSE,
            pipeline.inspect_task(plot_task(), store).decision,
        )

    def test_changed_llama2_input_does_not_invalidate_llama3_receipt(self) -> None:
        store = pipeline.ReceiptStore(self.root / "state")
        tasks = []
        sources = {}
        for model in ("llama2_7b", "llama3_8b"):
            source = self.root / f"{model}.raw.csv"
            output = self.root / model / "composed.csv"
            source.write_text(f"model,value\n{model},1\n")
            output.parent.mkdir()
            output.write_text(f"model,value\n{model},1\n")
            sources[model] = source
            task = pipeline.TaskSpec(
                key=f"compose:{model}",
                stage="compose",
                inputs={"selected_rows": pipeline.content_identity(source)},
                effective_parameters={"select": "latest"},
                outputs=(pipeline.OutputSpec(output),),
            )
            store.publish(pipeline.completed_receipt(task))
            tasks.append(task)

        sources["llama2_7b"].write_text("model,value\nllama2_7b,2\n")
        changed_llama2 = pipeline.TaskSpec(
            key=tasks[0].key,
            stage=tasks[0].stage,
            inputs={
                "selected_rows": pipeline.content_identity(
                    sources["llama2_7b"]
                )
            },
            effective_parameters=tasks[0].effective_parameters,
            outputs=tasks[0].outputs,
        )

        self.assertEqual(
            pipeline.Decision.PENDING,
            pipeline.inspect_task(changed_llama2, store).decision,
        )
        self.assertEqual(
            pipeline.Decision.REUSE,
            pipeline.inspect_task(tasks[1], store).decision,
        )

    def test_missing_requested_csv_blocks_attempt_completion(self) -> None:
        output_root = self.root / "figures"
        task = pipeline.TaskSpec(
            key="plot:kernel-power",
            stage="plot",
            inputs={"raw": pipeline.json_identity({"rows": 1})},
            effective_parameters={"formats": ["png"]},
            outputs=(
                pipeline.OutputSpec(output_root / "plot.png"),
                pipeline.OutputSpec(output_root / "aggregate.csv"),
            ),
        )
        attempt = self.root / "attempt"
        attempt.mkdir()
        (attempt / "plot.png").write_text("new image")

        with self.assertRaisesRegex(pipeline.OutputValidationError, "aggregate.csv"):
            pipeline.publish_isolated_attempt(
                task,
                store=pipeline.ReceiptStore(self.root / "state"),
                attempt_root=attempt,
                publication_root=output_root,
            )


class MeasurementPlanningTest(unittest.TestCase):
    def test_pipeline_planning_uses_strict_coverage_and_preserves_evidence_references(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw_db = root / "raw_db.csv"
            row = {column: "" for column in RAW_DB_COLUMNS}
            row.update({
                "run_id": "historical", "status": "pass", "fpga_bin_label": "C1",
                "xclbin_sha256": "xsha", "app": "gemm", "args": "-n 128",
                "warmup": "1", "iterations": "2", "measure_latency": "1",
                "measure_power": "0", "samples": "3", "min_us": "1",
                "avg_us": "2", "max_us": "3", "p50_us": "2", "p95_us": "3",
            })
            with raw_db.open("w", newline="") as output:
                writer = csv.DictWriter(output, fieldnames=RAW_DB_COLUMNS)
                writer.writeheader()
                writer.writerow(row)
            manifest_dir = root / "runs" / "historical"
            manifest_dir.mkdir(parents=True)
            manifest = {
                "run_id": "historical",
                "measurement_compatibility": {
                    "xclbin_sha256": "xsha", "config_sha256": "csha",
                    "fpga_period_s": 4e-9, "application_source_identity": "source-v1",
                    "acquisition_settings": {"platform": "xrt"},
                },
            }
            (manifest_dir / "manifest.json").write_text(json.dumps(manifest))
            unit = ExecutionUnit(
                "exec", "gemm", "-n 128", 1, 2, root / "raw", root / "power",
                root / "summary", root / "log",
            )
            policy = StrictMeasurementPolicy(
                "C1", "xsha", "csha", 4e-9, "source-v1", measure_power=False,
                acquisition_settings={"platform": "xrt"},
            )

            coverage = pipeline.plan_measurement_coverage(raw_db, (unit,), policy)
            adopted = pipeline.measurement_adoption_evidence(coverage)

            self.assertTrue(coverage.complete)
            self.assertEqual("historical", adopted[0]["run_id"])
            self.assertEqual(str(manifest_dir / "manifest.json"), adopted[0]["manifest"])
            self.assertFalse(adopted[0]["legacy_provenance"])


class RefinementEvidenceTest(unittest.TestCase):
    def _checkpoint(self, root: Path, outcome: str) -> Path:
        path = root / "recovery.json"
        path.write_text(json.dumps({
            "type": pipeline.REFINEMENT_RECOVERY_TYPE,
            "schema_version": pipeline.REFINEMENT_RECOVERY_SCHEMA_VERSION,
            "phase": "terminal",
            "completed_budget": 3,
            "active_iteration": None,
            "epoch_identity": {"kernel_types": ["softmax|softmax"]},
            "terminal_outcomes": {"softmax|softmax": outcome},
        }))
        return path

    def test_bounded_outcome_is_reportable_and_strict_gate_is_read_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self._checkpoint(Path(temporary), "budget_exhausted")
            before = path.read_bytes()
            evidence = pipeline.inspect_refinement_evidence(path)

            bounded = pipeline.refinement_allows_downstream(evidence)
            strict = pipeline.refinement_allows_downstream(
                evidence, require_convergence=True
            )

            self.assertTrue(bounded[0])
            self.assertIn("warning", bounded[1])
            self.assertFalse(strict[0])
            self.assertEqual(3, evidence.completed_budget)
            self.assertEqual(before, path.read_bytes())

    def test_execution_failure_and_active_iteration_do_not_certify_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self._checkpoint(Path(temporary), "converged")
            payload = json.loads(path.read_text())
            payload["phase"] = "interrupted"
            payload["active_iteration"] = {"phase": "selected"}
            path.write_text(json.dumps(payload))

            evidence = pipeline.inspect_refinement_evidence(path)

            self.assertFalse(evidence.valid)
            self.assertFalse(pipeline.refinement_allows_downstream(evidence)[0])
            self.assertIn("interrupted", evidence.reason)

    def test_legacy_state_json_is_not_recovery_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.json"
            path.write_text(json.dumps({
                "status": "completed", "completed_budget": 99,
            }))

            evidence = pipeline.inspect_refinement_evidence(path)

            self.assertFalse(evidence.valid)
            self.assertIn("legacy report-only", evidence.reason)

class ResourceOwnershipTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_overlapping_canonical_resources_conflict_across_tags(self) -> None:
        resource = self.root / "raw" / ".." / "raw"
        lock_root = self.root / "locks"
        first = pipeline.ResourceLocks(
            (resource,), lock_root=lock_root, owner="tag-a"
        )
        second = pipeline.ResourceLocks(
            (self.root / "raw",), lock_root=lock_root, owner="tag-b"
        )

        first.acquire()
        self.addCleanup(first.release)
        with self.assertRaises(pipeline.ResourceBusyError):
            second.acquire()

        first.release()
        second.acquire()
        second.release()

    def test_failed_lock_metadata_write_releases_kernel_lock(self) -> None:
        resource = self.root / "raw"
        lock_root = self.root / "locks"
        failed = pipeline.ResourceLocks(
            (resource,), lock_root=lock_root, owner="tag-a"
        )
        contender = pipeline.ResourceLocks(
            (resource,), lock_root=lock_root, owner="tag-b"
        )

        with mock.patch.object(
            pipeline.json, "dump", side_effect=OSError("injected metadata failure")
        ), self.assertRaisesRegex(OSError, "injected metadata failure"):
            failed.acquire()

        contender.acquire()
        contender.release()

    def test_child_keeps_resource_until_terminated_and_reaped(self) -> None:
        resource = self.root / "raw"
        lock_root = self.root / "locks"
        child = pipeline.OwnedProcess.start(
            (sys.executable, "-c", "import time; time.sleep(30)"),
            resources=(resource,),
            lock_root=lock_root,
            owner="tag-a",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(child.close)
        contender = pipeline.ResourceLocks(
            (resource,), lock_root=lock_root, owner="tag-b"
        )

        with self.assertRaises(pipeline.ResourceBusyError):
            contender.acquire()
        child.terminate(timeout=2.0)
        self.assertIsNotNone(child.returncode)

        contender.acquire()
        contender.release()

    def test_task_keeps_resource_through_publication_and_receipt(self) -> None:
        publication = self.root / "published"
        resource = self.root / "shared-resource"
        task = pipeline.TaskSpec(
            key="plot:fixture", stage="plot",
            inputs={"input": pipeline.json_identity(1)},
            effective_parameters={},
            outputs=(pipeline.OutputSpec(publication / "result.txt"),),
            resources=(resource,),
            command=(
                sys.executable, "-c",
                "from pathlib import Path; import sys; "
                "p=Path(sys.argv[1]); p.mkdir(parents=True, exist_ok=True); "
                "(p/'result.txt').write_text('fresh')",
                "{attempt_root}",
            ),
            metadata={"publication_root": str(publication)},
        )
        store = pipeline.ReceiptStore(self.root / "state")
        original = pipeline.publish_isolated_attempt

        def assert_locked(*args, **kwargs):
            contender = pipeline.ResourceLocks((resource,), owner="contender")
            with self.assertRaises(pipeline.ResourceBusyError):
                contender.acquire()
            return original(*args, **kwargs)

        with mock.patch.object(
            pipeline, "publish_isolated_attempt", side_effect=assert_locked
        ):
            pipeline._execute_task(task, store, self.root / "attempts")

        self.assertEqual("fresh", (publication / "result.txt").read_text())
        self.assertEqual("complete", store.load(task.key).status)


class ReadOnlyPlanningTest(unittest.TestCase):
    def test_pending_dependency_blocks_downstream_task(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            input_identity = pipeline.json_identity({"version": 1})
            prerequisite = pipeline.TaskSpec(
                key="refine:llama2",
                stage="refine",
                inputs={"suite": input_identity},
                effective_parameters={},
                outputs=(pipeline.OutputSpec(root / "refined.json"),),
            )
            downstream = pipeline.TaskSpec(
                key="compose:llama2",
                stage="compose",
                inputs={"refine": input_identity},
                effective_parameters={},
                outputs=(pipeline.OutputSpec(root / "composed.csv"),),
                dependencies=(prerequisite.key,),
            )

            decisions = pipeline.plan_tasks(
                (prerequisite, downstream), pipeline.ReceiptStore(root / "state")
            )

            self.assertEqual(pipeline.Decision.PENDING, decisions[0].decision)
            self.assertEqual(pipeline.Decision.BLOCKED, decisions[1].decision)
            self.assertIn(prerequisite.key, decisions[1].reason)

    def test_plan_and_status_do_not_create_state_or_output_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state_root = root / "pipeline_state.never-created"
            output = root / "outputs" / "latest" / "result.csv"
            task = pipeline.TaskSpec(
                key="plot:llama2",
                stage="plot",
                inputs={"settings": pipeline.json_identity({"format": "png"})},
                effective_parameters={"format": "png"},
                outputs=(pipeline.OutputSpec(output, "file"),),
                resources=(root / "outputs",),
            )

            decisions = pipeline.plan_tasks((task,), pipeline.ReceiptStore(state_root))
            status = pipeline.inspect_state(state_root)

            self.assertEqual(pipeline.Decision.PENDING, decisions[0].decision)
            self.assertEqual((), status)
            self.assertFalse(state_root.exists())
            self.assertFalse((root / "outputs").exists())

    def test_workflow_status_and_pipeline_dry_run_are_non_mutating(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for arguments in (
                ("status", "--tag", "tag-a", "--state-root", str(root)),
                (
                    "pipeline",
                    "--tag",
                    "tag-a",
                    "--state-root",
                    str(root),
                    "--dry-run",
                ),
                (
                    "pipeline",
                    "--tag",
                    "tag-a",
                    "--state-root",
                    str(root),
                    "--status",
                ),
            ):
                stdout = io.StringIO()
                with redirect_stdout(stdout):
                    self.assertEqual(0, workflow.main(list(arguments)))
                self.assertIn('"tasks": []', stdout.getvalue())

            self.assertEqual([], list(root.iterdir()))


class WorkflowCompatibilityTest(unittest.TestCase):
    def test_suite_retains_index_selection_and_stdout_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            index = root / "generation_merged" / "index.yaml"
            index.parent.mkdir()
            index.touch()
            path = root / "llama2_generation_C1.yaml"
            stdout = io.StringIO()
            with mock.patch.object(
                workflow,
                "indexed_suites",
                return_value=[("C1", path), ("C2", Path("c2"))],
            ) as indexed, redirect_stdout(stdout):
                result = workflow.main(
                    [
                        "suite",
                        "--input",
                        str(root),
                        "--stage",
                        "generation",
                        "--label",
                        "C1",
                    ]
                )

            self.assertEqual(0, result)
            indexed.assert_called_once_with(index)
            self.assertEqual(f"{path}\n", stdout.getvalue())

    def test_run_retains_forwarding_environment_and_extra_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for stage in ("prefill", "generation"):
                merged = root / f"{stage}_merged"
                merged.mkdir()
                (merged / "index.yaml").touch()
            suites = {
                "prefill_merged": [("C1", root / "prefill.yaml")],
                "generation_merged": [("C1", root / "generation.yaml")],
            }

            def indexed(path: Path) -> list[tuple[str, Path]]:
                return suites[path.parent.name]

            with mock.patch.object(
                workflow, "indexed_suites", side_effect=indexed
            ), mock.patch.object(
                workflow.subprocess, "run"
            ) as run, mock.patch.dict(
                os.environ,
                {"STAGES": "prefill generation", "FPGA_BINS": "C1"},
                clear=False,
            ):
                result = workflow.main(
                    [
                        "run",
                        "--input",
                        str(root),
                        "--output",
                        str(root / "raw"),
                        "--no-power",
                        "--retry",
                    ]
                )

            self.assertEqual(0, result)
            self.assertEqual(2, run.call_count)
            first = run.call_args_list[0]
            self.assertEqual(
                [
                    str(SCRIPT_DIR / "run_fpga_bin.sh"),
                    "C1",
                    "--no-power",
                    "--retry",
                ],
                first.args[0],
            )
            self.assertEqual("prefill", first.kwargs["env"]["STAGE"])
            self.assertEqual(str(root / "prefill.yaml"), first.kwargs["env"]["SUITE"])
            self.assertEqual(str(root / "raw" / "C1"), first.kwargs["env"]["OUT_DIR"])
            self.assertTrue(first.kwargs["check"])

    def test_run_discovers_legacy_yaml_suites_without_an_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for stage in ("prefill", "generation"):
                merged = root / f"{stage}_merged"
                merged.mkdir()
                (merged / f"{stage}_merged_legacy_bin.yaml").write_text(
                    "cases: []\n"
                )

            with mock.patch.object(workflow.subprocess, "run") as run, mock.patch.dict(
                os.environ,
                {"STAGES": "prefill generation", "FPGA_BINS": ""},
                clear=False,
            ):
                result = workflow.main(
                    ["run", "--input", str(root), "--output", str(root / "raw")]
                )

        self.assertEqual(0, result)
        self.assertEqual(2, run.call_count)
        for stage, call in zip(("prefill", "generation"), run.call_args_list):
            self.assertEqual("legacy_bin", call.args[0][1])
            self.assertEqual(stage, call.kwargs["env"]["STAGE"])
            self.assertEqual(
                str(
                    root
                    / f"{stage}_merged"
                    / f"{stage}_merged_legacy_bin.yaml"
                ),
                call.kwargs["env"]["SUITE"],
            )


class PipelineOrchestrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.settings = pipeline.PipelineSettings(
            tag="fixture", workspace=self.root / "workspace",
            state_base=self.root / "state", models=("llama2",),
            python=sys.executable,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _task_builder(self, *, fail_stage: str | None = None):
        commands = self.root / "commands.log"

        def build(settings, stage):
            output = self.root / f"{stage}.txt"
            prior = pipeline.STAGES.index(stage)
            inputs = {"settings": pipeline.json_identity({"fixture": 1})}
            if prior:
                previous = self.root / f"{pipeline.STAGES[prior - 1]}.txt"
                inputs["previous"] = pipeline._path_identity(previous)
            code = (
                "from pathlib import Path; "
                f"Path({str(commands)!r}).open('a').write({stage!r}+'\\n'); "
                + ("raise SystemExit(7)" if stage == fail_stage else
                   f"Path({str(output)!r}).write_text({stage!r})")
            )
            return (pipeline.TaskSpec(
                key=f"{stage}:fixture", stage=stage, inputs=inputs,
                effective_parameters={"stage": stage},
                outputs=(pipeline.OutputSpec(output),), resources=(self.root / "resource",),
                command=(sys.executable, "-c", code),
            ),)

        return build, commands

    @staticmethod
    def _terminal_evidence(path):
        return pipeline.RefinementEvidence(
            Path(path), True, "terminal", 3, {"app|backend": "converged"}, "ok"
        )

    def test_complete_flow_restart_launches_zero_commands(self) -> None:
        builder, commands = self._task_builder()
        with mock.patch.object(pipeline, "build_stage_tasks", side_effect=builder), \
                mock.patch.object(pipeline, "_legacy_writer", return_value=None), \
                mock.patch.object(pipeline, "inspect_refinement_evidence",
                                  side_effect=self._terminal_evidence):
            first_code, first = pipeline.run_pipeline(self.settings)
            first_count = len(commands.read_text().splitlines())
            second_code, second = pipeline.run_pipeline(self.settings)

        self.assertEqual(0, first_code)
        self.assertEqual(5, first_count)
        self.assertEqual(0, second_code)
        self.assertEqual(first_count, len(commands.read_text().splitlines()))
        self.assertEqual(5, len(second["reused"]))
        self.assertEqual([], second["executed"])

    def test_failed_sibling_receipt_is_preserved_and_reused(self) -> None:
        commands = self.root / "commands.log"
        success = self.root / "success.txt"
        failed = self.root / "failed.txt"
        should_fail = self.root / "should_fail"
        should_fail.write_text("yes")

        def build(_settings, stage):
            self.assertEqual("run", stage)
            first = pipeline.TaskSpec(
                key="run:first", stage="run", inputs={"v": pipeline.json_identity(1)},
                effective_parameters={}, outputs=(pipeline.OutputSpec(success),),
                command=(sys.executable, "-c",
                         f"from pathlib import Path; Path({str(commands)!r}).open('a').write('first\\n'); Path({str(success)!r}).write_text('ok')"),
            )
            code = (
                "from pathlib import Path; "
                f"Path({str(commands)!r}).open('a').write('second\\n'); "
                f"p=Path({str(should_fail)!r}); "
                f"exec(\"raise SystemExit(9)\" if p.exists() else \"Path({str(failed)!r}).write_text('ok')\")"
            )
            second = pipeline.TaskSpec(
                key="run:second", stage="run", inputs={"v": pipeline.json_identity(1)},
                effective_parameters={}, outputs=(pipeline.OutputSpec(failed),),
                command=(sys.executable, "-c", code),
            )
            return first, second

        with mock.patch.object(pipeline, "build_stage_tasks", side_effect=build), \
                mock.patch.object(pipeline, "_legacy_writer", return_value=None):
            code, _ = pipeline.run_pipeline(self.settings, first="run", last="run")
            should_fail.unlink()
            resumed_code, resumed = pipeline.run_pipeline(
                self.settings, first="run", last="run"
            )

        self.assertEqual(1, code)
        self.assertEqual(0, resumed_code)
        self.assertEqual(["first", "second", "second"], commands.read_text().splitlines())
        self.assertIn("run:first", resumed["reused"])

    def test_stale_excluded_refinement_blocks_compose_without_command(self) -> None:
        builder, commands = self._task_builder()
        invalid = pipeline.RefinementEvidence(
            self.root / "recovery.json", False, "missing", 0, {}, "checkpoint missing"
        )
        # Earlier run receipts are irrelevant to this assertion, so make them reusable.
        with mock.patch.object(pipeline, "build_stage_tasks", side_effect=builder), \
                mock.patch.object(pipeline, "inspect_task", return_value=pipeline.TaskDecision(
                    pipeline.TaskSpec("dummy", "run", {}, {}, ()), pipeline.Decision.REUSE, "ok"
                )), mock.patch.object(pipeline, "inspect_refinement_evidence", return_value=invalid):
            code, summary = pipeline.run_pipeline(
                self.settings, first="compose", last="compose"
            )

        self.assertEqual(2, code)
        self.assertFalse(commands.exists())
        self.assertIn("--from refine", " ".join(summary["blocked"]))

    def test_terminal_excluded_refinement_requires_compatible_receipt(self) -> None:
        builder, commands = self._task_builder()

        def inspect(task, _store):
            if task.stage == "refine":
                return pipeline.TaskDecision(
                    task, pipeline.Decision.PENDING,
                    "effective task parameters changed",
                )
            return pipeline.TaskDecision(task, pipeline.Decision.REUSE, "ok")

        with mock.patch.object(pipeline, "build_stage_tasks", side_effect=builder), \
                mock.patch.object(pipeline, "inspect_task", side_effect=inspect), \
                mock.patch.object(
                    pipeline, "inspect_refinement_evidence",
                    side_effect=AssertionError("stale checkpoint must not be accepted"),
                ):
            code, summary = pipeline.run_pipeline(
                self.settings, first="compose", last="compose"
            )

        blocked = " ".join(summary["blocked"])
        self.assertEqual(2, code)
        self.assertFalse(commands.exists())
        self.assertIn("refine:fixture", blocked)
        self.assertIn("effective task parameters changed", blocked)
        self.assertIn("--from refine", blocked)

    def test_ranges_rerun_and_strict_gate_are_validated_without_probes(self) -> None:
        with self.assertRaisesRegex(ValueError, "reversed"):
            pipeline._stage_range("plot", "run", None)
        with self.assertRaisesRegex(ValueError, "outside"):
            pipeline._stage_range("compose", "plot", "refine")
        bounded = pipeline.RefinementEvidence(
            self.root / "recovery.json", True, "terminal", 3,
            {"app|backend": "budget_exhausted"}, "bounded",
        )
        allowed, _ = pipeline.refinement_allows_downstream(
            bounded, require_convergence=False
        )
        strict, reason = pipeline.refinement_allows_downstream(
            bounded, require_convergence=True
        )
        self.assertTrue(allowed)
        self.assertFalse(strict)
        self.assertIn("strict convergence", reason)

    def test_external_legacy_writer_blocks_before_child_start(self) -> None:
        builder, commands = self._task_builder()
        writer = self.root / "run_state.json"
        writer.write_text('{"status":"running"}')
        with mock.patch.object(pipeline, "build_stage_tasks", side_effect=builder), \
                mock.patch.object(pipeline, "_legacy_writer", return_value=writer):
            code, summary = pipeline.run_pipeline(
                self.settings, first="run", last="run"
            )
        self.assertEqual(2, code)
        self.assertFalse(commands.exists())
        self.assertIn("external legacy writer", " ".join(summary["blocked"]))

    def test_actual_legacy_run_state_blocks_before_child_start(self) -> None:
        builder, commands = self._task_builder()
        writer = (
            self.settings.result_root("llama2") / "C4" / "latest" / "run_state.json"
        )
        writer.parent.mkdir(parents=True)
        writer.write_text('{"status":"running","run_id":"legacy-active"}\n')
        with mock.patch.object(pipeline, "build_stage_tasks", side_effect=builder):
            code, summary = pipeline.run_pipeline(
                self.settings, first="run", last="run"
            )
        self.assertEqual(2, code)
        self.assertFalse(commands.exists())
        blocked_writer = summary["blocked"][0].split(" by ", 1)[1].split(";", 1)[0]
        self.assertEqual(str(writer), blocked_writer)

    def test_incomplete_measurement_evidence_cannot_be_adopted(self) -> None:
        task = pipeline.TaskSpec(
            key="run:llama2:prefill:C1", stage="run",
            inputs={"suite": pipeline.json_identity(1)},
            effective_parameters={"model": "llama2"}, outputs=(),
        )
        evidence = mock.Mock()
        evidence.exec_key = "missing-case"
        evidence.reasons = ("power samples are incomplete",)
        evidence.state.value = "incomplete"
        coverage = mock.Mock(complete=False, evidence=(evidence,))
        store = pipeline.ReceiptStore(self.settings.state_root)
        with mock.patch.object(
            pipeline, "_strict_coverage_for_run_task", return_value=coverage
        ):
            adopted, reason = pipeline._adopt_run_task(
                self.settings, task, store, publish=True
            )
        self.assertFalse(adopted)
        self.assertIn("power samples are incomplete", reason)
        self.assertFalse(self.settings.state_root.exists())

    def test_adoption_marker_preserves_original_measurement_references(self) -> None:
        marker = self.root / "measurement.json"
        task = pipeline.TaskSpec(
            key="run:llama2:prefill:C1", stage="run",
            inputs={"suite": pipeline.json_identity(1)},
            effective_parameters={"model": "llama2"},
            outputs=(pipeline.OutputSpec(marker),),
            resources=(self.root / "raw-root",),
            metadata={"marker": str(marker)},
        )
        coverage = MeasurementCoverage((MeasurementEvidence(
            "exec", MeasurementReuseState.REUSE,
            ("complete compatible measurement",),
            run_id="historical-run",
            manifest="/evidence/historical-run/manifest.json",
            legacy_provenance=True,
        ),))
        store = pipeline.ReceiptStore(self.settings.state_root)

        adopted, _ = pipeline._adopt_run_task(
            self.settings, task, store, publish=True, coverage=coverage
        )

        self.assertTrue(adopted)
        evidence = json.loads(marker.read_text())["measurement_evidence"]
        self.assertEqual("historical-run", evidence[0]["run_id"])
        self.assertEqual(
            "/evidence/historical-run/manifest.json", evidence[0]["manifest"]
        )
        self.assertTrue(evidence[0]["legacy_provenance"])
        self.assertEqual("complete", store.load(task.key).status)

    def test_reused_measurement_receipt_is_revalidated_against_raw_rows(self) -> None:
        marker = self.root / "measurement.json"
        marker.write_text("complete")
        task = pipeline.TaskSpec(
            key="run:llama2:prefill:C1", stage="run",
            inputs={"suite": pipeline.json_identity(1)},
            effective_parameters={"model": "llama2"},
            outputs=(pipeline.OutputSpec(marker),),
            command=(sys.executable, "-c", "raise SystemExit(99)"),
            metadata={
                "suite": str(self.root / "suite.pkl"),
                "raw_db": str(self.root / "raw_db.csv"),
                "marker": str(marker),
            },
        )
        store = pipeline.ReceiptStore(self.settings.state_root)
        store.publish(pipeline.completed_receipt(task, attempt_id="old"))
        coverage = MeasurementCoverage((MeasurementEvidence(
            "exec", MeasurementReuseState.PENDING,
            ("required power metric is missing",),
        ),))
        with mock.patch.object(
            pipeline, "build_stage_tasks", return_value=(task,)
        ), mock.patch.object(
            pipeline, "_strict_coverage_for_run_task", return_value=coverage
        ), mock.patch.object(
            pipeline, "_legacy_writer", return_value=None
        ), mock.patch.object(pipeline, "_execute_task") as execute:
            code, summary = pipeline.run_pipeline(
                self.settings, first="run", last="run", inspect_only=True
            )

        self.assertEqual(0, code)
        self.assertEqual([], summary["reused"])
        self.assertIn("required power metric", str(summary["executed"]))
        execute.assert_not_called()

    def test_blocked_measurement_metadata_never_starts_hardware(self) -> None:
        marker = self.root / "measurement.json"
        task = pipeline.TaskSpec(
            key="run:llama2:prefill:C1", stage="run",
            inputs={"suite": pipeline.json_identity(1)},
            effective_parameters={"model": "llama2"},
            outputs=(pipeline.OutputSpec(marker),),
            command=(sys.executable, "-c", "raise SystemExit(99)"),
            metadata={
                "suite": str(self.root / "suite.pkl"),
                "raw_db": str(self.root / "raw_db.csv"),
                "marker": str(marker),
            },
        )
        coverage = MeasurementCoverage((MeasurementEvidence(
            "exec", MeasurementReuseState.BLOCKED_METADATA,
            ("historical application source identity is missing",),
        ),))
        with mock.patch.object(
            pipeline, "build_stage_tasks", return_value=(task,)
        ), mock.patch.object(
            pipeline, "_strict_coverage_for_run_task", return_value=coverage
        ), mock.patch.object(
            pipeline, "_legacy_writer", return_value=None
        ), mock.patch.object(pipeline, "_execute_task") as execute:
            code, summary = pipeline.run_pipeline(
                self.settings, first="run", last="run"
            )

        self.assertEqual(2, code)
        self.assertIn("application source identity", " ".join(summary["blocked"]))
        execute.assert_not_called()

    def test_read_only_plan_excludes_c2_and_preserves_inputs(self) -> None:
        candidate = self.settings.workspace / "candidate_fpga_bins.yaml"
        aliases = self.settings.workspace.parents[1] / "ci" / "fpga_bin_alias_map.yaml"
        workload = self.settings.suite_root("llama2") / "source.yaml"
        for path, text in (
            (candidate, "candidates: {C2: registered-only}\n"),
            (aliases, "C1: historical-global-alias\n"),
            (workload, "cases: [immutable]\n"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        before = {path: path.read_bytes() for path in (candidate, aliases, workload)}

        code, summary = pipeline.run_pipeline(
            self.settings, first="run", last="run", inspect_only=True
        )

        self.assertEqual(0, code)
        self.assertFalse(self.settings.state_root.exists())
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        reported = [
            task.key for task in pipeline._run_tasks(self.settings)
            if task.key in " ".join(map(str, summary["blocked"] + summary["executed"]))
        ]
        self.assertEqual(6, len(reported))
        self.assertFalse(any(":C2" in key for key in reported))

    def test_resolved_hardware_tasks_exclude_c2_and_share_one_settings_source(self) -> None:
        tasks = pipeline._run_tasks(self.settings)
        self.assertEqual(6, len(tasks))
        self.assertEqual(
            {"C1", "C3", "C4"},
            {str(task.effective_parameters["label"]) for task in tasks},
        )
        for task in tasks:
            self.assertNotIn("C2", task.key)
            self.assertIn("--strict-measurement-reuse", task.command)
            self.assertEqual(self.settings.result_root("llama2"), task.resources[0])
            self.assertEqual(0, task.effective_parameters["warmup"])
            self.assertEqual(1, task.effective_parameters["iterations"])
            self.assertEqual("0", task.metadata["environment"]["WARMUP"])
            self.assertEqual("1", task.metadata["environment"]["ITERATIONS"])

    def test_refinement_output_matches_cli_artifact_layout(self) -> None:
        task = pipeline._refine_tasks(self.settings)[0]
        output_root = Path(task.command[task.command.index("--output-root") + 1])
        refinement_id = task.command[task.command.index("--refinement-id") + 1]

        self.assertEqual(
            output_root
            / "interpolation"
            / "refinements"
            / refinement_id
            / "recovery.json",
            task.outputs[0].path,
        )

    def test_strict_coverage_uses_run_task_acquisition_parameters(self) -> None:
        task = pipeline._run_tasks(self.settings)[0]
        with mock.patch(
            "tools.latency_bench.suite.load_suite",
            side_effect=RuntimeError("stop after inspecting overrides"),
        ) as load_suite, self.assertRaisesRegex(RuntimeError, "stop"):
            pipeline._strict_coverage_for_run_task(self.settings, task)

        self.assertEqual(0, load_suite.call_args.kwargs["warmup_override"])
        self.assertEqual(1, load_suite.call_args.kwargs["iterations_override"])

    def test_plot_receipts_fingerprint_only_each_family_inputs(self) -> None:
        from prepare import EXCEL_FIGURE_DATA_CSV, gemm_only_out_name

        prepared = (
            self.settings.prepared_root
            / gemm_only_out_name(self.settings.model_key("llama2"))
            / EXCEL_FIGURE_DATA_CSV
        )
        prepared.parent.mkdir(parents=True)
        prepared.write_text("value\n1\n")
        before = {task.key: task.inputs for task in pipeline._plot_tasks(self.settings)}

        prepared.write_text("value\n2\n")
        after = {task.key: task.inputs for task in pipeline._plot_tasks(self.settings)}

        changed = {key for key in before if before[key] != after[key]}
        self.assertEqual({"plot:llama_gemm_only:default"}, changed)
        self.assertTrue(all("prepared" not in inputs for inputs in after.values()))

    def test_single_model_plot_tasks_pin_renderer_models_and_exact_inputs(self) -> None:
        tasks = pipeline._plot_tasks(self.settings)
        for task in tasks:
            models_index = task.command.index("--models")
            self.assertEqual("llama2_7b", task.command[models_index + 1])
            self.assertEqual(["llama2_7b"], task.effective_parameters["models"])
            prepared = {
                identity
                for name, identity in task.inputs.items()
                if name.startswith("prepared_")
            }
            model_data = {
                pipeline._path_identity(Path(value.partition("=")[2]))
                for index, value in enumerate(task.command)
                if index and task.command[index - 1] == "--model-data"
            }
            self.assertEqual(prepared, model_data)

    def test_plot_cli_applies_single_model_and_exact_input_selection(self) -> None:
        import plot

        exact = self.root / "llama2" / "excel_figure_data.csv"
        exact.parent.mkdir()
        exact.write_text("stage,batch,seq\nprefill,1,128\n")
        with mock.patch.object(plot, "run_selected_plots") as render, \
                mock.patch.object(plot, "_write_render_manifests"), \
                mock.patch.object(plot, "REQUESTED_LLAMA_MODELS", None), \
                mock.patch.object(plot, "REQUESTED_MODEL_DATA", {}):
            result = plot.main([
                "--plot", "llama_gemm_only",
                "--out-tokens", "128",
                "--workers", "1",
                "--models", "llama2_7b",
                "--model-data", f"llama2_7b={exact}",
            ])
            self.assertEqual(
                (("llama2_7b", "Llama 2"),), plot.requested_llama_models()
            )
            self.assertEqual({"llama2_7b": str(exact)}, plot.REQUESTED_MODEL_DATA)
            model_csvs = plot.collect_model_csvs(
                explicit_by_model={},
                prepared_root=self.root / "missing-prepared-root",
                latency_dir=self.root,
                kind="gemm_only",
                label="GEMM-only",
            )
            self.assertEqual(
                [("llama2_7b", "Llama 2", exact.resolve())], model_csvs
            )

        self.assertEqual(0, result)
        render.assert_called_once()

    def test_rerun_reenters_only_selected_stage_and_keeps_other_receipts(self) -> None:
        builder, commands = self._task_builder()
        with mock.patch.object(pipeline, "build_stage_tasks", side_effect=builder), \
                mock.patch.object(pipeline, "_legacy_writer", return_value=None), \
                mock.patch.object(pipeline, "inspect_refinement_evidence",
                                  side_effect=self._terminal_evidence):
            code, _ = pipeline.run_pipeline(self.settings)
            before = commands.read_text().splitlines()
            rerun_code, rerun = pipeline.run_pipeline(
                self.settings, first="refine", last="plot", rerun="refine"
            )
        self.assertEqual(0, code)
        self.assertEqual(0, rerun_code)
        after = commands.read_text().splitlines()
        self.assertEqual(before + ["refine"], after)
        self.assertEqual(["refine:fixture"], rerun["executed"])


class CampaignWrapperTest(unittest.TestCase):
    def test_spooled_wrapper_uses_slurm_submit_dir_and_pipeline_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            submit = root / "checkout"
            work = submit / "analysis_workspace" / "latency_on_hw"
            task = submit / "agent-tasks" / "latency_on_hw-refine"
            spool = root / "slurm-spool"
            work.mkdir(parents=True)
            task.mkdir(parents=True)
            spool.mkdir()
            source = (
                SCRIPT_DIR.parents[1]
                / "agent-tasks" / "latency_on_hw-refine" / "run_campaign.sh"
            )
            copied = spool / "slurm_script"
            shutil.copy2(source, copied)
            copied.chmod(0o755)
            capture = root / "pipeline.json"
            (work / "workflow.py").write_text(
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "Path(os.environ['PIPELINE_CAPTURE']).write_text(json.dumps({"
                "'argv': sys.argv[1:], 'cwd': os.getcwd()}))\n"
            )
            environment = dict(
                os.environ,
                SLURM_SUBMIT_DIR=str(submit),
                SLURM_JOB_ID="fixture-job",
                EXPERIMENT_TAG="fixture-tag",
                SUITE_SIZE="full",
                PYTHON=sys.executable,
                PIPELINE_CAPTURE=str(capture),
            )

            result = subprocess.run(
                [str(copied), "--from", "compose", "--to", "plot"],
                cwd=spool, env=environment, check=False, capture_output=True, text=True,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            invocation = json.loads(capture.read_text())
            self.assertEqual(str(work), invocation["cwd"])
            self.assertEqual(
                ["pipeline", "--tag", "fixture-tag", "--suite-size", "full",
                 "--from", "compose", "--to", "plot"],
                invocation["argv"],
            )
            status = json.loads((task / "campaign_status.json").read_text())
            self.assertEqual("complete", status["state"])
            self.assertEqual("pipeline", status["phase"])
            self.assertEqual("fixture-job", status["job_id"])


if __name__ == "__main__":
    unittest.main()
