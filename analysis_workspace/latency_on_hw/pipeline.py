"""Durable planning primitives for the latency-on-hardware pipeline.

This module deliberately separates read-only inspection from mutation.  Stage
adapters describe work with :class:`TaskSpec`; only explicit receipt publication
and resource acquisition create filesystem state.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Callable, IO, Iterable, Mapping, Sequence


RECEIPT_TYPE = "vortex-latency-pipeline-receipt"
RECEIPT_SCHEMA_VERSION = 1
REFINEMENT_RECOVERY_TYPE = "vortex-latency-interpolation-recovery"
REFINEMENT_RECOVERY_SCHEMA_VERSION = 1
REFINEMENT_TERMINAL_OUTCOMES = frozenset({
    "converged", "no_candidates", "budget_exhausted", "unbracketed",
})
REFINEMENT_STRICT_OUTCOMES = frozenset({"converged", "no_candidates"})
REFINEMENT_FAILURE_OUTCOMES = frozenset({"failed", "interrupted"})


class ReceiptError(ValueError):
    """Base class for an unusable task receipt."""


class CorruptReceiptError(ReceiptError):
    """A receipt is not valid JSON or does not satisfy its schema."""


class UnsupportedReceiptError(ReceiptError):
    """A receipt uses an unknown type or schema version."""


class OutputValidationError(ValueError):
    """A declared task output does not satisfy its manifest contract."""


class ResourceBusyError(RuntimeError):
    """A canonical output resource already has a live writer."""


STAGES = ("run", "refine", "compose", "prepare", "plot")
MODEL_NAMES = ("llama2", "llama3")
EXECUTION_BINS = ("C1", "C3", "C4")
MEASUREMENT_ACQUISITION = {"warmup": 0, "iterations": 1}
MODEL_KEYS = {"llama2": "llama2_7b", "llama3": "llama3_8b"}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _canonical_json(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
    except (TypeError, ValueError) as error:
        raise ValueError(f"value is not stable JSON: {error}") from error
    return encoded.encode("utf-8")


def canonical_path(path: Path | str) -> Path:
    """Return one absolute resource identity, including for missing paths."""

    return Path(path).expanduser().resolve(strict=False)


@dataclass(frozen=True)
class ContentIdentity:
    """A stable identity for file, directory, or logical JSON content."""

    kind: str
    sha256: str
    size: int

    def __post_init__(self) -> None:
        if self.kind not in {"file", "directory", "json"}:
            raise ValueError(f"unsupported content identity kind: {self.kind}")
        if (
            len(self.sha256) != 64
            or any(character not in "0123456789abcdef" for character in self.sha256)
        ):
            raise ValueError("content identity sha256 must be 64 lowercase hex characters")
        if not isinstance(self.size, int) or self.size < 0:
            raise ValueError("content identity size must be a non-negative integer")

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind, "sha256": self.sha256, "size": self.size}

    @classmethod
    def from_dict(cls, payload: Any) -> "ContentIdentity":
        mapping = _mapping(payload, "content identity")
        _require_keys(mapping, {"kind", "sha256", "size"}, "content identity")
        try:
            return cls(
                kind=_string(mapping["kind"], "content identity kind"),
                sha256=_string(mapping["sha256"], "content identity sha256"),
                size=_integer(mapping["size"], "content identity size"),
            )
        except ValueError as error:
            raise CorruptReceiptError(str(error)) from error


def _hash_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def _directory_identity(path: Path) -> ContentIdentity:
    digest = hashlib.sha256()
    total_size = 0
    entries = sorted(path.rglob("*"), key=lambda entry: entry.relative_to(path).as_posix())
    for entry in entries:
        relative = entry.relative_to(path).as_posix()
        if entry.is_dir():
            digest.update(_canonical_json(["directory", relative]))
            continue
        if not entry.is_file():
            raise OutputValidationError(f"unsupported output entry type: {entry}")
        file_digest, size = _hash_file(entry)
        total_size += size
        digest.update(_canonical_json(["file", relative, file_digest, size]))
    return ContentIdentity("directory", digest.hexdigest(), total_size)


def content_identity(path: Path | str) -> ContentIdentity:
    """Hash the current content at *path* without changing it."""

    resolved = canonical_path(path)
    if resolved.is_file():
        digest, size = _hash_file(resolved)
        return ContentIdentity("file", digest, size)
    if resolved.is_dir():
        return _directory_identity(resolved)
    raise FileNotFoundError(resolved)


def json_identity(value: Any) -> ContentIdentity:
    """Hash logical JSON content using a canonical encoding."""

    encoded = _canonical_json(value)
    return ContentIdentity("json", hashlib.sha256(encoded).hexdigest(), len(encoded))


@dataclass(frozen=True)
class OutputSpec:
    path: Path
    kind: str = "file"
    allow_empty: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "path", Path(self.path))
        if self.kind not in {"file", "directory"}:
            raise ValueError(f"unsupported output kind: {self.kind}")
        if not isinstance(self.allow_empty, bool):
            raise ValueError("allow_empty must be boolean")


@dataclass(frozen=True)
class OutputArtifact:
    path: Path
    kind: str
    allow_empty: bool
    identity: ContentIdentity

    def __post_init__(self) -> None:
        object.__setattr__(self, "path", canonical_path(self.path))
        if self.kind not in {"file", "directory"}:
            raise ValueError(f"unsupported output kind: {self.kind}")
        if self.identity.kind != self.kind:
            raise ValueError(
                f"output identity kind {self.identity.kind} does not match {self.kind}"
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": str(self.path),
            "kind": self.kind,
            "allow_empty": self.allow_empty,
            "identity": self.identity.to_dict(),
        }

    @classmethod
    def from_dict(cls, payload: Any) -> "OutputArtifact":
        mapping = _mapping(payload, "output manifest entry")
        _require_keys(
            mapping,
            {"path", "kind", "allow_empty", "identity"},
            "output manifest entry",
        )
        allow_empty = mapping["allow_empty"]
        if not isinstance(allow_empty, bool):
            raise CorruptReceiptError("output allow_empty must be boolean")
        try:
            return cls(
                path=Path(_string(mapping["path"], "output path")),
                kind=_string(mapping["kind"], "output kind"),
                allow_empty=allow_empty,
                identity=ContentIdentity.from_dict(mapping["identity"]),
            )
        except ValueError as error:
            raise CorruptReceiptError(str(error)) from error


@dataclass(frozen=True)
class ValidationResult:
    valid: bool
    checked_at: str
    details: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "valid": self.valid,
            "checked_at": self.checked_at,
            "details": list(self.details),
        }

    @classmethod
    def from_dict(cls, payload: Any) -> "ValidationResult":
        mapping = _mapping(payload, "validation result")
        _require_keys(mapping, {"valid", "checked_at", "details"}, "validation result")
        if not isinstance(mapping["valid"], bool):
            raise CorruptReceiptError("validation valid must be boolean")
        details = mapping["details"]
        if not isinstance(details, list) or not all(isinstance(item, str) for item in details):
            raise CorruptReceiptError("validation details must be a list of strings")
        return cls(
            valid=mapping["valid"],
            checked_at=_string(mapping["checked_at"], "validation checked_at"),
            details=tuple(details),
        )


@dataclass(frozen=True)
class TaskSpec:
    """Resolved task information used by planning and later stage adapters."""

    key: str
    stage: str
    inputs: Mapping[str, ContentIdentity]
    effective_parameters: Mapping[str, Any]
    outputs: tuple[OutputSpec, ...]
    resources: tuple[Path, ...] = ()
    dependencies: tuple[str, ...] = ()
    command: tuple[str, ...] = ()
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.key or not isinstance(self.key, str):
            raise ValueError("task key must be a non-empty string")
        if not self.stage or not isinstance(self.stage, str):
            raise ValueError("task stage must be a non-empty string")
        if not all(isinstance(name, str) and name for name in self.inputs):
            raise ValueError("task input names must be non-empty strings")
        if not all(isinstance(identity, ContentIdentity) for identity in self.inputs.values()):
            raise ValueError("task inputs must contain ContentIdentity values")
        if not all(isinstance(output, OutputSpec) for output in self.outputs):
            raise ValueError("task outputs must contain OutputSpec values")
        _canonical_json(self.effective_parameters)
        _canonical_json(self.metadata)
        object.__setattr__(self, "outputs", tuple(self.outputs))
        object.__setattr__(self, "resources", tuple(Path(path) for path in self.resources))
        object.__setattr__(self, "dependencies", tuple(self.dependencies))
        object.__setattr__(self, "command", tuple(self.command))


@dataclass(frozen=True)
class TaskReceipt:
    task_key: str
    stage: str
    status: str
    inputs: Mapping[str, ContentIdentity]
    effective_parameters: Mapping[str, Any]
    output_manifest: tuple[OutputArtifact, ...]
    validation: ValidationResult
    attempt_id: str
    started_at: str
    completed_at: str
    exit_code: int
    command: tuple[str, ...] = ()
    logs: Mapping[str, str] = field(default_factory=dict)
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "type": RECEIPT_TYPE,
            "schema_version": RECEIPT_SCHEMA_VERSION,
            "task_key": self.task_key,
            "stage": self.stage,
            "status": self.status,
            "inputs": {
                name: identity.to_dict()
                for name, identity in sorted(self.inputs.items())
            },
            "effective_parameters": self.effective_parameters,
            "output_manifest": [output.to_dict() for output in self.output_manifest],
            "validation": self.validation.to_dict(),
            "attempt": {
                "id": self.attempt_id,
                "started_at": self.started_at,
                "completed_at": self.completed_at,
                "exit_code": self.exit_code,
                "command": list(self.command),
                "logs": dict(sorted(self.logs.items())),
            },
            "metadata": self.metadata,
        }

    @classmethod
    def from_dict(cls, payload: Any) -> "TaskReceipt":
        mapping = _mapping(payload, "receipt")
        receipt_type = mapping.get("type")
        if receipt_type != RECEIPT_TYPE:
            raise UnsupportedReceiptError(f"unsupported receipt type: {receipt_type!r}")
        version = mapping.get("schema_version")
        if version != RECEIPT_SCHEMA_VERSION:
            raise UnsupportedReceiptError(f"unsupported receipt schema version: {version!r}")
        required = {
            "type",
            "schema_version",
            "task_key",
            "stage",
            "status",
            "inputs",
            "effective_parameters",
            "output_manifest",
            "validation",
            "attempt",
            "metadata",
        }
        _require_keys(mapping, required, "receipt")
        inputs_payload = _mapping(mapping["inputs"], "receipt inputs")
        outputs_payload = mapping["output_manifest"]
        if not isinstance(outputs_payload, list):
            raise CorruptReceiptError("receipt output_manifest must be a list")
        parameters = _mapping(mapping["effective_parameters"], "effective parameters")
        metadata = _mapping(mapping["metadata"], "receipt metadata")
        attempt = _mapping(mapping["attempt"], "receipt attempt")
        _require_keys(
            attempt,
            {"id", "started_at", "completed_at", "exit_code", "command", "logs"},
            "receipt attempt",
        )
        command = attempt["command"]
        if not isinstance(command, list) or not all(isinstance(item, str) for item in command):
            raise CorruptReceiptError("receipt command must be a list of strings")
        logs_payload = _mapping(attempt["logs"], "receipt logs")
        if not all(isinstance(key, str) and isinstance(value, str) for key, value in logs_payload.items()):
            raise CorruptReceiptError("receipt logs must map strings to strings")
        try:
            receipt = cls(
                task_key=_string(mapping["task_key"], "receipt task_key"),
                stage=_string(mapping["stage"], "receipt stage"),
                status=_string(mapping["status"], "receipt status"),
                inputs={
                    name: ContentIdentity.from_dict(identity)
                    for name, identity in inputs_payload.items()
                    if isinstance(name, str)
                },
                effective_parameters=dict(parameters),
                output_manifest=tuple(
                    OutputArtifact.from_dict(output) for output in outputs_payload
                ),
                validation=ValidationResult.from_dict(mapping["validation"]),
                attempt_id=_string(attempt["id"], "receipt attempt id"),
                started_at=_string(attempt["started_at"], "receipt started_at"),
                completed_at=_string(attempt["completed_at"], "receipt completed_at"),
                exit_code=_integer(attempt["exit_code"], "receipt exit_code"),
                command=tuple(command),
                logs=dict(logs_payload),
                metadata=dict(metadata),
            )
        except (TypeError, ValueError) as error:
            raise CorruptReceiptError(str(error)) from error
        if len(receipt.inputs) != len(inputs_payload):
            raise CorruptReceiptError("receipt input names must be strings")
        try:
            _canonical_json(receipt.effective_parameters)
            _canonical_json(receipt.metadata)
        except ValueError as error:
            raise CorruptReceiptError(f"corrupt receipt content: {error}") from error
        return receipt


def _mapping(value: Any, description: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise CorruptReceiptError(f"{description} must be an object")
    return value


def _require_keys(mapping: Mapping[str, Any], required: set[str], description: str) -> None:
    missing = sorted(required - set(mapping))
    if missing:
        raise CorruptReceiptError(f"{description} is missing fields: {', '.join(missing)}")


def _string(value: Any, description: str) -> str:
    if not isinstance(value, str) or not value:
        raise CorruptReceiptError(f"{description} must be a non-empty string")
    return value


def _integer(value: Any, description: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise CorruptReceiptError(f"{description} must be an integer")
    return value


def _capture_output(spec: OutputSpec) -> OutputArtifact:
    path = canonical_path(spec.path)
    if not path.exists():
        raise OutputValidationError(f"missing required output: {path}")
    if spec.kind == "file" and not path.is_file():
        raise OutputValidationError(f"expected file output: {path}")
    if spec.kind == "directory" and not path.is_dir():
        raise OutputValidationError(f"expected directory output: {path}")
    identity = content_identity(path)
    if not spec.allow_empty:
        if spec.kind == "file" and identity.size == 0:
            raise OutputValidationError(f"empty required file output: {path}")
        if spec.kind == "directory" and not any(path.iterdir()):
            raise OutputValidationError(f"empty required directory output: {path}")
    return OutputArtifact(path, spec.kind, spec.allow_empty, identity)


def completed_receipt(
    task: TaskSpec,
    *,
    attempt_id: str | None = None,
    started_at: str | None = None,
    completed_at: str | None = None,
    exit_code: int = 0,
    logs: Mapping[str, str] | None = None,
) -> TaskReceipt:
    """Validate fresh outputs and build a typed completion receipt."""

    if exit_code != 0:
        raise ValueError("a completion receipt requires exit code zero")
    checked_at = completed_at or _utc_now()
    manifest = tuple(_capture_output(output) for output in task.outputs)
    return TaskReceipt(
        task_key=task.key,
        stage=task.stage,
        status="complete",
        inputs=dict(task.inputs),
        effective_parameters=dict(task.effective_parameters),
        output_manifest=manifest,
        validation=ValidationResult(
            valid=True,
            checked_at=checked_at,
            details=tuple(f"validated {output.path}" for output in manifest),
        ),
        attempt_id=attempt_id or str(uuid.uuid4()),
        started_at=started_at or checked_at,
        completed_at=checked_at,
        exit_code=exit_code,
        command=task.command,
        logs=dict(logs or {}),
        metadata=dict(task.metadata),
    )


def publish_isolated_attempt(
    task: TaskSpec,
    *,
    store: "ReceiptStore",
    attempt_root: Path | str,
    publication_root: Path | str,
    attempt_id: str | None = None,
    started_at: str | None = None,
    logs: Mapping[str, str] | None = None,
    replace: Callable[[Path | str, Path | str], Any] = os.replace,
) -> TaskReceipt:
    """Validate and publish files produced under an isolated attempt root.

    Every declared output must exist under ``attempt_root`` before any current
    published file is replaced.  The completion receipt is written only after
    all replacements and final output validation succeed.
    """

    attempt = canonical_path(attempt_root)
    published = canonical_path(publication_root)
    sources: list[tuple[Path, Path]] = []
    for output in task.outputs:
        if output.kind != "file":
            raise OutputValidationError(
                "isolated publication currently requires file outputs"
            )
        destination = canonical_path(output.path)
        try:
            relative = destination.relative_to(published)
        except ValueError as error:
            raise OutputValidationError(
                f"published output is outside publication root: {destination}"
            ) from error
        source = attempt / relative
        try:
            _capture_output(OutputSpec(source, output.kind, output.allow_empty))
        except OutputValidationError as error:
            raise OutputValidationError(
                f"invalid attempt output for {relative}: {error}"
            ) from error
        sources.append((source, destination))

    temporary_paths: list[Path] = []
    try:
        for source, destination in sources:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="wb",
                dir=destination.parent,
                prefix=f".{destination.name}.",
                suffix=".publish",
                delete=False,
            ) as temporary:
                temporary_path = Path(temporary.name)
                temporary_paths.append(temporary_path)
                with source.open("rb") as input_file:
                    shutil.copyfileobj(input_file, temporary)
                temporary.flush()
                os.fsync(temporary.fileno())
            replace(temporary_path, destination)
            temporary_paths.remove(temporary_path)

        receipt = completed_receipt(
            task,
            attempt_id=attempt_id,
            started_at=started_at,
            logs=logs,
        )
        store.publish(receipt)
        return receipt
    finally:
        for temporary_path in temporary_paths:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


class ReceiptStore:
    """Atomic storage for per-task receipts under one tagged state directory."""

    def __init__(self, root: Path | str):
        self.root = Path(root)

    def path_for(self, task_key: str) -> Path:
        digest = hashlib.sha256(task_key.encode("utf-8")).hexdigest()
        return self.root / f"{digest}.json"

    def load(self, task_key: str) -> TaskReceipt | None:
        path = self.path_for(task_key)
        try:
            with path.open(encoding="utf-8") as source:
                payload = json.load(source)
        except FileNotFoundError:
            return None
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise CorruptReceiptError(f"corrupt receipt {path}: {error}") from error
        receipt = TaskReceipt.from_dict(payload)
        if receipt.task_key != task_key:
            raise CorruptReceiptError(
                f"corrupt receipt {path}: task key is {receipt.task_key!r}, expected {task_key!r}"
            )
        return receipt

    def publish(self, receipt: TaskReceipt) -> Path:
        """Atomically replace one receipt after fully serializing it."""

        payload = receipt.to_dict()
        # Parse our own payload so hand-constructed receipts cannot publish an
        # unsupported or structurally incomplete record.
        TaskReceipt.from_dict(payload)
        self.root.mkdir(parents=True, exist_ok=True)
        destination = self.path_for(receipt.task_key)
        temporary: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=self.root,
                prefix=f".{destination.name}.",
                suffix=".tmp",
                delete=False,
            ) as output:
                temporary = Path(output.name)
                json.dump(payload, output, sort_keys=True, indent=2)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, destination)
            directory_fd = os.open(self.root, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            temporary = None
        finally:
            if temporary is not None:
                try:
                    temporary.unlink()
                except FileNotFoundError:
                    pass
        return destination


class Decision(str, Enum):
    REUSE = "reuse"
    PENDING = "pending"
    BLOCKED = "blocked"


@dataclass(frozen=True)
class TaskDecision:
    task: TaskSpec
    decision: Decision
    reason: str
    receipt: TaskReceipt | None = None


def _validate_manifest(task: TaskSpec, receipt: TaskReceipt) -> str | None:
    if len(task.outputs) != len(receipt.output_manifest):
        return "output manifest does not match the declared output count"
    for expected, recorded in zip(task.outputs, receipt.output_manifest):
        if canonical_path(expected.path) != recorded.path:
            return f"output manifest path changed: {expected.path}"
        if expected.kind != recorded.kind:
            return f"output manifest type changed: {expected.path}"
        if expected.allow_empty != recorded.allow_empty:
            return f"output manifest empty-file policy changed: {expected.path}"
        try:
            current = _capture_output(expected)
        except OutputValidationError as error:
            return str(error)
        if current.identity != recorded.identity:
            return f"output content does not match receipt: {recorded.path}"
    return None


def inspect_task(task: TaskSpec, store: ReceiptStore) -> TaskDecision:
    """Inspect one task without creating directories or updating receipts."""

    try:
        receipt = store.load(task.key)
    except UnsupportedReceiptError as error:
        return TaskDecision(task, Decision.PENDING, str(error))
    except CorruptReceiptError as error:
        return TaskDecision(task, Decision.PENDING, str(error))
    if receipt is None:
        return TaskDecision(task, Decision.PENDING, "completion receipt is missing")
    if receipt.stage != task.stage:
        return TaskDecision(task, Decision.PENDING, "receipt stage does not match task")
    if receipt.status != "complete":
        return TaskDecision(task, Decision.PENDING, f"receipt status is {receipt.status!r}")
    if receipt.exit_code != 0:
        return TaskDecision(task, Decision.PENDING, "receipt exit code is not zero")
    if not receipt.validation.valid:
        return TaskDecision(task, Decision.PENDING, "receipt validation did not pass")
    if dict(receipt.inputs) != dict(task.inputs):
        return TaskDecision(task, Decision.PENDING, "task input identities changed")
    if _canonical_json(receipt.effective_parameters) != _canonical_json(
        task.effective_parameters
    ):
        return TaskDecision(task, Decision.PENDING, "effective task parameters changed")
    if receipt.command != task.command:
        return TaskDecision(task, Decision.PENDING, "task command metadata changed")
    if _canonical_json(receipt.metadata) != _canonical_json(task.metadata):
        return TaskDecision(task, Decision.PENDING, "task metadata changed")
    manifest_error = _validate_manifest(task, receipt)
    if manifest_error is not None:
        return TaskDecision(task, Decision.PENDING, manifest_error)
    return TaskDecision(
        task,
        Decision.REUSE,
        "receipt inputs and current outputs validated",
        receipt,
    )


def plan_tasks(tasks: Iterable[TaskSpec], store: ReceiptStore) -> tuple[TaskDecision, ...]:
    """Return deterministic reuse decisions without mutating any state."""

    decisions: list[TaskDecision] = []
    by_key: dict[str, TaskDecision] = {}
    for task in tasks:
        if task.key in by_key:
            raise ValueError(f"duplicate task key in plan: {task.key}")
        unavailable = [
            dependency
            for dependency in task.dependencies
            if dependency not in by_key
            or by_key[dependency].decision is not Decision.REUSE
        ]
        if unavailable:
            decision = TaskDecision(
                task,
                Decision.BLOCKED,
                "prerequisites are not reusable: " + ", ".join(unavailable),
            )
        else:
            decision = inspect_task(task, store)
        decisions.append(decision)
        by_key[task.key] = decision
    return tuple(decisions)


def plan_measurement_coverage(
    raw_db: Path,
    units: Sequence[Any],
    policy: Any,
) -> Any:
    """Use the runner's strict predicate during read-only pipeline planning."""

    from tools.latency_bench.runner import evaluate_measurement_coverage

    return evaluate_measurement_coverage(raw_db, list(units), policy)


def measurement_adoption_evidence(coverage: Any) -> tuple[dict[str, Any], ...]:
    """Return receipt-ready references without rewriting source provenance."""

    from tools.latency_bench.runner import MeasurementReuseState

    return tuple(
        {
            "exec_key": item.exec_key,
            "run_id": item.run_id,
            "manifest": item.manifest,
            "legacy_provenance": item.legacy_provenance,
        }
        for item in coverage.evidence
        if item.state is MeasurementReuseState.REUSE
    )


@dataclass(frozen=True)
class RefinementEvidence:
    """Validated terminal evidence exposed to later pipeline stage adapters."""

    path: Path
    valid: bool
    phase: str
    completed_budget: int
    terminal_outcomes: Mapping[str, str]
    reason: str


def inspect_refinement_evidence(path: Path | str) -> RefinementEvidence:
    """Read a durable recovery checkpoint without accepting legacy reports."""

    checkpoint_path = canonical_path(path)
    try:
        with checkpoint_path.open(encoding="utf-8") as source:
            payload = json.load(source)
    except FileNotFoundError:
        return RefinementEvidence(
            checkpoint_path, False, "missing", 0, {},
            "refinement recovery checkpoint is missing",
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        return RefinementEvidence(
            checkpoint_path, False, "invalid", 0, {},
            f"refinement recovery checkpoint is corrupt: {error}",
        )
    if payload.get("type") != REFINEMENT_RECOVERY_TYPE:
        return RefinementEvidence(
            checkpoint_path, False, "legacy", 0, {},
            "legacy report-only state cannot certify refinement recovery",
        )
    if payload.get("schema_version") != REFINEMENT_RECOVERY_SCHEMA_VERSION:
        return RefinementEvidence(
            checkpoint_path, False, "unsupported", 0, {},
            "refinement recovery checkpoint schema is unsupported",
        )
    phase = str(payload.get("phase", ""))
    budget = payload.get("completed_budget")
    outcomes = payload.get("terminal_outcomes")
    if not isinstance(budget, int) or budget < 0 or not isinstance(outcomes, dict):
        return RefinementEvidence(
            checkpoint_path, False, phase, 0, {},
            "refinement recovery checkpoint fields are invalid",
        )
    normalized = {
        str(key): str(value) for key, value in outcomes.items()
    }
    active = payload.get("active_iteration")
    applicable = payload.get("epoch_identity", {}).get("kernel_types", [])
    if active is not None or phase in REFINEMENT_FAILURE_OUTCOMES:
        return RefinementEvidence(
            checkpoint_path, False, phase, budget, normalized,
            f"refinement execution is {phase or 'incomplete'}",
        )
    if phase != "terminal":
        return RefinementEvidence(
            checkpoint_path, False, phase, budget, normalized,
            "refinement checkpoint has not reached its terminal phase",
        )
    if applicable and set(normalized) != {str(key) for key in applicable}:
        return RefinementEvidence(
            checkpoint_path, False, phase, budget, normalized,
            "not every applicable kernel has a terminal refinement outcome",
        )
    if any(value not in REFINEMENT_TERMINAL_OUTCOMES for value in normalized.values()):
        return RefinementEvidence(
            checkpoint_path, False, phase, budget, normalized,
            "refinement checkpoint contains a nonterminal outcome",
        )
    return RefinementEvidence(
        checkpoint_path, True, phase, budget, normalized,
        "durable terminal refinement evidence validated",
    )


def refinement_allows_downstream(
    evidence: RefinementEvidence,
    *,
    require_convergence: bool = False,
) -> tuple[bool, str]:
    """Apply the downstream gate without changing checkpoint or budget."""

    if not evidence.valid:
        return False, evidence.reason
    if require_convergence:
        rejected = {
            key: outcome for key, outcome in evidence.terminal_outcomes.items()
            if outcome not in REFINEMENT_STRICT_OUTCOMES
        }
        if rejected:
            details = ", ".join(
                f"{key}={outcome}" for key, outcome in sorted(rejected.items())
            )
            return False, f"strict convergence gate rejected: {details}"
    bounded = {
        key: outcome for key, outcome in evidence.terminal_outcomes.items()
        if outcome in {"budget_exhausted", "unbracketed"}
    }
    if bounded:
        details = ", ".join(
            f"{key}={outcome}" for key, outcome in sorted(bounded.items())
        )
        return True, f"bounded refinement outcome accepted with warning: {details}"
    return True, "refinement terminal evidence accepted"


@dataclass(frozen=True)
class StateInspection:
    path: Path
    receipt: TaskReceipt | None
    error: str | None


def inspect_state(state_root: Path | str) -> tuple[StateInspection, ...]:
    """Read existing receipt files without creating or repairing anything."""

    root = Path(state_root)
    if not root.is_dir():
        return ()
    inspections = []
    for path in sorted(root.glob("*.json")):
        try:
            with path.open(encoding="utf-8") as source:
                receipt = TaskReceipt.from_dict(json.load(source))
        except UnsupportedReceiptError as error:
            inspections.append(StateInspection(path, None, str(error)))
        except (OSError, UnicodeError, json.JSONDecodeError, CorruptReceiptError) as error:
            inspections.append(StateInspection(path, None, f"corrupt receipt: {error}"))
        else:
            inspections.append(StateInspection(path, receipt, None))
    return tuple(inspections)


def _default_lock_root() -> Path:
    return Path(tempfile.gettempdir()) / f"vortex-latency-pipeline-locks-{os.getuid()}"


class ResourceLocks:
    """Non-blocking process-lifetime locks for canonical output resources."""

    def __init__(
        self,
        resources: Iterable[Path | str],
        *,
        owner: str,
        lock_root: Path | str | None = None,
    ):
        canonical = {canonical_path(resource) for resource in resources}
        self.resources = tuple(sorted(canonical, key=os.fspath))
        self.owner = owner
        self.lock_root = Path(lock_root) if lock_root is not None else _default_lock_root()
        self._files: list[tuple[Path, IO[str]]] = []

    def _lock_path(self, resource: Path) -> Path:
        digest = hashlib.sha256(os.fsencode(resource)).hexdigest()
        return self.lock_root / f"{digest}.lock"

    def acquire(self) -> None:
        if self._files:
            raise RuntimeError("resource locks are already acquired")
        if not self.resources:
            return
        self.lock_root.mkdir(parents=True, exist_ok=True)
        try:
            for resource in self.resources:
                lock_path = self._lock_path(resource)
                lock_file = lock_path.open("a+", encoding="utf-8")
                try:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    lock_file.close()
                    raise ResourceBusyError(
                        f"resource has an active writer: {resource}"
                    ) from error
                self._files.append((resource, lock_file))
                metadata = {
                    "type": "vortex-latency-resource-lock",
                    "schema_version": 1,
                    "resource": str(resource),
                    "owner": self.owner,
                    "pid": os.getpid(),
                    "acquired_at": _utc_now(),
                }
                lock_file.seek(0)
                lock_file.truncate()
                json.dump(metadata, lock_file, sort_keys=True)
                lock_file.write("\n")
                lock_file.flush()
                os.fsync(lock_file.fileno())
        except BaseException:
            self.release()
            raise

    def release(self) -> None:
        while self._files:
            _, lock_file = self._files.pop()
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            finally:
                lock_file.close()

    def __enter__(self) -> "ResourceLocks":
        self.acquire()
        return self

    def __exit__(self, *_: Any) -> None:
        self.release()


class OwnedProcess:
    """A child process whose canonical resource locks live through reaping."""

    def __init__(self, process: subprocess.Popen[Any], locks: ResourceLocks):
        self._process = process
        self._locks = locks
        self._closed = False

    @classmethod
    def start(
        cls,
        command: Sequence[str],
        *,
        resources: Iterable[Path | str],
        owner: str,
        lock_root: Path | str | None = None,
        **popen_options: Any,
    ) -> "OwnedProcess":
        locks = ResourceLocks(resources, owner=owner, lock_root=lock_root)
        locks.acquire()
        try:
            process = subprocess.Popen(list(command), **popen_options)
        except BaseException:
            locks.release()
            raise
        return cls(process, locks)

    @property
    def returncode(self) -> int | None:
        return self._process.returncode

    @property
    def pid(self) -> int:
        return self._process.pid

    def wait(self, timeout: float | None = None, *, release: bool = True) -> int:
        try:
            return self._process.wait(timeout=timeout)
        finally:
            if release and self._process.returncode is not None:
                self._release()

    def terminate(self, timeout: float = 10.0) -> int:
        if self._process.poll() is None:
            self._process.terminate()
        try:
            return self.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self._process.kill()
            return self.wait()

    def close(self) -> None:
        if self._closed:
            return
        if self._process.poll() is None:
            self.terminate()
        else:
            self.wait()

    def _release(self) -> None:
        if not self._closed:
            self._locks.release()
            self._closed = True

    def __enter__(self) -> "OwnedProcess":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()


@dataclass(frozen=True)
class PipelineSettings:
    """One resolved experiment configuration shared by every stage adapter."""

    tag: str
    workspace: Path
    state_base: Path
    suite_size: str = "full"
    models: tuple[str, ...] = MODEL_NAMES
    out_tokens: int = 128
    formats: tuple[str, ...] = ("png", "pdf", "svg")
    target_error: float = 0.05
    validation_samples: int = 3
    max_iterations: int = 3
    adopt_legacy: bool = False
    require_convergence: bool = False
    python: str = sys.executable

    @property
    def state_root(self) -> Path:
        return self.state_base / f"pipeline_state.{self.tag}"

    @property
    def composed_root(self) -> Path:
        return self.workspace / f"composed_results.{self.tag}"

    @property
    def prepared_root(self) -> Path:
        return self.workspace / f"figure_prepare.{self.tag}"

    @property
    def plot_root(self) -> Path:
        return self.workspace / f"figure_output.{self.tag}"

    def model_key(self, model: str) -> str:
        return MODEL_KEYS[model]

    def suite_root(self, model: str) -> Path:
        return self.workspace / "generated_suites" / (
            f"{self.model_key(model)}_main_{self.suite_size}.{self.tag}"
        )

    def result_root(self, model: str) -> Path:
        return self.workspace / f"outputs_{model}_main.{self.tag}"

    def build_root(self, model: str) -> Path:
        return self.workspace.parents[1] / f"build_latency_{model}"

    @property
    def application_source_root(self) -> Path:
        return self.workspace.parents[1] / "tests" / "regression"


def _path_identity(path: Path) -> ContentIdentity:
    """Describe missing prerequisites without creating them (for status/dry-run)."""

    try:
        return content_identity(path)
    except FileNotFoundError:
        return json_identity({"missing": str(canonical_path(path))})


def _stage_range(first: str, last: str, rerun: str | None) -> tuple[str, ...]:
    begin = STAGES.index(first)
    end = STAGES.index(last)
    if begin > end:
        raise ValueError(f"reversed stage range: --from {first} --to {last}")
    selected = STAGES[begin : end + 1]
    if rerun is not None and rerun not in selected:
        raise ValueError(f"--rerun {rerun} is outside selected range {first}..{last}")
    return selected


def _suite_for(settings: PipelineSettings, model: str, stage: str, label: str) -> Path:
    from tools.latency_bench.suite_io import indexed_suites

    index = settings.suite_root(model) / f"{stage}_merged" / "index.yaml"
    if not index.is_file():
        return index.parent / f"missing-{label}.pkl"
    matches = [path for current, path in indexed_suites(index) if current == label]
    if len(matches) != 1:
        raise ValueError(f"expected one generated suite for {model}/{stage}/{label}")
    return matches[0]


def _run_marker(settings: PipelineSettings, model: str, stage: str, label: str) -> Path:
    return settings.state_root / "evidence" / f"run.{model}.{stage}.{label}.json"


def _refinement_checkpoint(settings: PipelineSettings, model: str, label: str) -> Path:
    refinement_id = f"{settings.tag}.{model}.{label}.latency"
    return (
        settings.result_root(model)
        / label
        / "interpolation"
        / "refinements"
        / refinement_id
        / "recovery.json"
    )


def _raw_dbs(settings: PipelineSettings, model: str) -> tuple[Path, ...]:
    return tuple(settings.result_root(model) / label / "raw_db.csv" for label in EXECUTION_BINS)


def _run_tasks(settings: PipelineSettings) -> tuple[TaskSpec, ...]:
    tasks = []
    workflow_script = settings.workspace / "workflow.py"
    application_source = _path_identity(settings.application_source_root)
    for model in settings.models:
        for stage in ("prefill", "generation"):
            for label in EXECUTION_BINS:
                suite = _suite_for(settings, model, stage, label)
                marker = _run_marker(settings, model, stage, label)
                command = (
                    settings.python, str(workflow_script), "run",
                    "--input", str(settings.suite_root(model)),
                    "--output", str(settings.result_root(model)),
                    "--strict-measurement-reuse",
                    "--application-source-identity", application_source.sha256,
                    "--power-kernel-iterations", "auto",
                    "--power-target-sec", "10",
                    "--power-latency-interval", "0.1",
                    "--power-idle-stability-policy",
                    str(settings.workspace / "idle_stability_policy.json"),
                    "--no-power-auto-duration",
                    "--retry",
                ) + (("--adopt-legacy",) if settings.adopt_legacy else ())
                tasks.append(TaskSpec(
                    key=f"run:{model}:{stage}:{label}", stage="run",
                    inputs={"suite": _path_identity(suite),
                            "application_source": application_source},
                    effective_parameters={
                        "model": model, "stage": stage, "label": label,
                        **MEASUREMENT_ACQUISITION,
                        "measure_latency": True, "measure_power": True,
                        "power_kernel_iterations": "auto",
                        "power_target_sec": 10.0,
                        "power_latency_interval": 0.1,
                        "power_idle_stability_policy": str(
                            settings.workspace / "idle_stability_policy.json"
                        ),
                        "power_auto_duration": False,
                        "adopt_legacy": settings.adopt_legacy,
                    },
                    outputs=(OutputSpec(marker),),
                    resources=(settings.result_root(model), settings.build_root(model)),
                    command=command,
                    metadata={
                        "environment": {
                            "STAGES": stage,
                            "FPGA_BINS": label,
                            "BUILD_DIR": str(settings.build_root(model)),
                            "WARMUP": str(MEASUREMENT_ACQUISITION["warmup"]),
                            "ITERATIONS": str(MEASUREMENT_ACQUISITION["iterations"]),
                        },
                        "marker": str(marker),
                        "suite": str(suite),
                        "raw_db": str(settings.result_root(model) / label / "raw_db.csv"),
                    },
                ))
    return tuple(tasks)


def _refine_tasks(settings: PipelineSettings) -> tuple[TaskSpec, ...]:
    tasks = []
    refine_script = settings.workspace / "run_interp_refine_example.sh"
    application_source = _path_identity(settings.application_source_root)
    for model in settings.models:
        for label in EXECUTION_BINS:
            suite = _suite_for(settings, model, "generation", label)
            checkpoint = _refinement_checkpoint(settings, model, label)
            output_root = settings.result_root(model) / label
            refinement_id = f"{settings.tag}.{model}.{label}.latency"
            measure = (
                f"env STAGE=generation SUITE={{suite}} OUT_DIR={{out}} "
                f"BUILD_DIR={settings.build_root(model)} SKIP_EXISTING=1 "
                f"BLACKBOX_TIMEOUT=24h {settings.workspace / 'run_fpga_bin.sh'} "
                f"{label} --latency --no-power --retry --strict-measurement-reuse "
                f"--application-source-identity {application_source.sha256}"
                + (" --adopt-legacy" if settings.adopt_legacy else "")
            )
            command = (
                settings.python, "-m", "tools.latency_bench", "refine-interpolation",
                "--suite", str(suite), "--output-root", str(output_root),
                "--refinement-id", refinement_id, "--measure-command", measure,
                "--metric", "fpga_cycle", "--target-error", str(settings.target_error),
                "--validation-samples", str(settings.validation_samples),
                "--max-iterations", str(settings.max_iterations),
                "--sampling-strategy", "midpoint", "--seed", "0",
            )
            tasks.append(TaskSpec(
                key=f"refine:{model}:{label}", stage="refine",
                # The recovery protocol owns relevant-anchor compatibility.
                # The main raw DB is intentionally mutable because promotion
                # appends the refinement rows that this task produced.
                inputs={"suite": _path_identity(suite),
                        "application_source": application_source},
                effective_parameters={
                    "target_error": settings.target_error,
                    "validation_samples": settings.validation_samples,
                    "max_iterations": settings.max_iterations,
                    "metric": "fpga_cycle", "sampling_strategy": "midpoint", "seed": 0,
                },
                outputs=(OutputSpec(checkpoint),),
                resources=(settings.result_root(model), settings.build_root(model)),
                command=command,
                metadata={"model": model, "label": label, "wrapper": str(refine_script)},
            ))
    return tuple(tasks)


def _compose_tasks(settings: PipelineSettings) -> tuple[TaskSpec, ...]:
    script = settings.workspace / "run_compose.py"
    tasks = []
    for model in settings.models:
        key = settings.model_key(model)
        inputs = {"suites": _path_identity(settings.suite_root(model))}
        inputs.update({f"raw_{label}": _path_identity(path)
                       for label, path in zip(EXECUTION_BINS, _raw_dbs(settings, model))})
        outputs = tuple(OutputSpec(settings.composed_root / key / name)
                        for name in ("composed.csv", "summary.csv", "manifest.json"))
        command = (
            settings.python, str(script),
            "--llama2-results", str(settings.result_root("llama2")),
            "--llama3-results", str(settings.result_root("llama3")),
            "--llama2-suites", str(settings.suite_root("llama2")),
            "--llama3-suites", str(settings.suite_root("llama3")),
            "--models", key, "--no-combine", "--out", "{attempt_root}",
        )
        tasks.append(TaskSpec(
            key=f"compose:{model}", stage="compose", inputs=inputs,
            effective_parameters={"model": key, "metric": "fpga_cycle_latency",
                                  "select": "latest", "missing": "error"},
            outputs=outputs, resources=(settings.composed_root,), command=command,
            metadata={"publication_root": str(settings.composed_root)},
        ))
    tasks.append(_combined_compose_task(settings))
    return tuple(tasks)


def _combined_compose_task(settings: PipelineSettings) -> TaskSpec:
    script = settings.workspace / "run_compose.py"
    model_outputs = {
        f"model_{model}": _path_identity(
            settings.composed_root / settings.model_key(model) / "composed.csv"
        )
        for model in settings.models
    }
    combined_outputs = tuple(OutputSpec(path) for path in (
        settings.composed_root / "combined" / "composed.csv",
        settings.composed_root / "combined" / "summary.csv",
        settings.composed_root / "manifest.json",
    ))
    combine_command = (
        settings.python, str(script),
        "--llama2-results", str(settings.result_root("llama2")),
        "--llama3-results", str(settings.result_root("llama3")),
        "--llama2-suites", str(settings.suite_root("llama2")),
        "--llama3-suites", str(settings.suite_root("llama3")),
        "--models", ",".join(settings.model_key(model) for model in settings.models),
        "--aggregate-only", "--out", "{attempt_root}",
    )
    return TaskSpec(
        key="compose:combined:" + "+".join(settings.models), stage="compose",
        inputs=model_outputs, effective_parameters={"models": list(settings.models)},
        outputs=combined_outputs, resources=(settings.composed_root,), command=combine_command,
        metadata={"publication_root": str(settings.composed_root),
                  "seed_model_dirs": [settings.model_key(model) for model in settings.models]},
    )


def _prepare_tasks(settings: PipelineSettings) -> tuple[TaskSpec, ...]:
    from prepare import prepared_model_output_paths

    tasks = []
    for model in settings.models:
        key = settings.model_key(model)
        composed = settings.composed_root / key / "composed.csv"
        outputs = tuple(OutputSpec(path) for path in
                        prepared_model_output_paths(key, output_root=settings.prepared_root))
        command = (
            settings.python, str(settings.workspace / "prepare.py"),
            "--composed-csv", str(composed), "--out-tokens", str(settings.out_tokens),
            "--models", key, "--workers", "1", "--exact-model-input",
            "--output-root", "{attempt_root}",
        )
        tasks.append(TaskSpec(
            key=f"prepare:{model}", stage="prepare",
            inputs={"composed": _path_identity(composed)},
            effective_parameters={"model": key, "out_tokens": settings.out_tokens,
                                  "workers": 1, "exact_model_input": True},
            outputs=outputs, resources=(settings.prepared_root,), command=command,
            metadata={"publication_root": str(settings.prepared_root)},
        ))
    return tuple(tasks)


def _candidate_snapshot_path(settings: PipelineSettings) -> Path:
    for model in settings.models:
        path = settings.result_root(model) / "C1" / "latest" / "manifest.json"
        if path.is_file():
            return path
    return settings.result_root(settings.models[0]) / "C1" / "latest" / "manifest.json"


def _plot_tasks(settings: PipelineSettings) -> tuple[TaskSpec, ...]:
    from plot import expected_plot_outputs, selected_plot_jobs
    from prepare import (
        EXCEL_FIGURE_DATA_CSV,
        e2e_gemm_layout_stacked_out_name,
        e2e_no_area_norm_stacked_out_name,
        energy_no_area_norm_gemm_layout_vector_stacked_out_name,
        gemm_only_no_area_norm_out_name,
        gemm_only_out_name,
    )

    tasks = []
    snapshot = _candidate_snapshot_path(settings)
    raw_dbs = tuple(path for model in settings.models for path in _raw_dbs(settings, model))
    latency_names = {
        "llama_e2e_gemm_layout_vector_stacked": e2e_gemm_layout_stacked_out_name,
        "llama_e2e_no_area_norm_stacked": e2e_no_area_norm_stacked_out_name,
        "llama_gemm_only": gemm_only_out_name,
        "llama_gemm_only_no_area_norm": gemm_only_no_area_norm_out_name,
    }
    for family, metric in selected_plot_jobs("all"):
            relative = expected_plot_outputs(family, formats=settings.formats,
                                             power_metric=metric)
            outputs = tuple(OutputSpec(settings.plot_root / path) for path in relative)
            inputs: dict[str, ContentIdentity] = {}
            model_data: list[tuple[str, Path]] = []
            if family in latency_names:
                output_name = latency_names[family]
                for model in settings.models:
                    path = (
                        settings.prepared_root
                        / output_name(settings.model_key(model))
                        / EXCEL_FIGURE_DATA_CSV
                    )
                    inputs[f"prepared_{model}"] = _path_identity(path)
                    model_data.append((settings.model_key(model), path))
            elif family == "llama_energy_no_area_norm_gemm_layout_vector_stacked":
                assert metric is not None
                for model in settings.models:
                    path = (
                        settings.prepared_root
                        / energy_no_area_norm_gemm_layout_vector_stacked_out_name(
                            settings.model_key(model), metric
                        )
                        / EXCEL_FIGURE_DATA_CSV
                    )
                    inputs[f"prepared_{model}"] = _path_identity(path)
                    model_data.append((settings.model_key(model), path))
            command = [
                settings.python, str(settings.workspace / "plot.py"), "--plot", family,
                "--out-tokens", str(settings.out_tokens), "--workers", "1",
                "--models", ",".join(
                    settings.model_key(model) for model in settings.models
                ),
                "--formats", ",".join(settings.formats),
                "--prepared-root", str(settings.prepared_root),
                "--out-dir", "{attempt_root}",
            ]
            if metric is not None:
                command.extend(("--power-metric", metric))
            for model_key, path in model_data:
                command.extend(("--model-data", f"{model_key}={path}"))
            if family == "kernel_dynamic_power":
                inputs["candidate_snapshot"] = _path_identity(snapshot)
                command.extend(("--candidate-snapshot", str(snapshot)))
                for index, raw_db in enumerate(raw_dbs):
                    inputs[f"raw_{index}"] = _path_identity(raw_db)
                    command.extend(("--kernel-raw-db", str(raw_db)))
            tasks.append(TaskSpec(
                key=f"plot:{family}:{metric or 'default'}", stage="plot", inputs=inputs,
                effective_parameters={"family": family, "power_metric": metric,
                                      "models": [
                                          settings.model_key(model)
                                          for model in settings.models
                                      ],
                                      "formats": list(settings.formats),
                                      "out_tokens": settings.out_tokens},
                outputs=outputs, resources=(settings.plot_root,), command=tuple(command),
                metadata={"publication_root": str(settings.plot_root)},
            ))
    return tuple(tasks)


def build_stage_tasks(settings: PipelineSettings, stage: str) -> tuple[TaskSpec, ...]:
    return {
        "run": _run_tasks,
        "refine": _refine_tasks,
        "compose": _compose_tasks,
        "prepare": _prepare_tasks,
        "plot": _plot_tasks,
    }[stage](settings)


def _legacy_writer(settings: PipelineSettings) -> Path | None:
    """Conservatively recognize the old runner's explicit running state."""

    for model in settings.models:
        for label in EXECUTION_BINS:
            state = settings.result_root(model) / label / "latest" / "run_state.json"
            try:
                payload = json.loads(state.read_text())
            except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
                continue
            if payload.get("status") == "running":
                return state
    return None


def _write_marker(
    task: TaskSpec, *, measurement_evidence: Sequence[Mapping[str, Any]] = (),
) -> None:
    marker = task.metadata.get("marker")
    if not marker:
        return
    path = Path(str(marker))
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"type": "vortex-latency-measurement-task", "schema_version": 1,
               "task_key": task.key, "completed_at": _utc_now(),
               "inputs": {key: value.to_dict() for key, value in task.inputs.items()},
               "measurement_evidence": list(measurement_evidence)}
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                     prefix=f".{path.name}.", delete=False) as output:
        temporary = Path(output.name)
        json.dump(payload, output, sort_keys=True, indent=2)
        output.write("\n")
    os.replace(temporary, path)


def _strict_coverage_for_run_task(
    settings: PipelineSettings, task: TaskSpec,
) -> Any:
    """Evaluate historical rows with the same acquisition contract as execution."""

    from tools.latency_bench.runner import (
        RunOptions, build_execution_units, evaluate_measurement_coverage,
        strict_measurement_policy,
    )
    from tools.latency_bench.suite import load_suite

    suite_path = Path(str(task.metadata["suite"]))
    suite = load_suite(
        suite_path, repo_root=settings.workspace.parents[1],
        warmup_override=int(task.effective_parameters["warmup"]),
        iterations_override=int(task.effective_parameters["iterations"]),
    )
    label = str(task.effective_parameters["label"])
    candidate = suite.experiment["candidates"][label]
    options = RunOptions(
        build_dir=settings.build_root(str(task.effective_parameters["model"])),
        fpga_bin_dir=Path(str(candidate["bin_dir"])),
        out_dir=Path(str(task.metadata["raw_db"])).parent,
        platform=suite.defaults.platform,
        fpga_bin_label=label,
        configs=Path(str(candidate["config"])),
        strict_measurement_reuse=True,
        adopt_legacy=settings.adopt_legacy,
        application_source_identity=task.inputs["application_source"].sha256,
        skip_existing=True,
        measure_latency=True,
        measure_power=True,
        power_auto_duration=False,
        power_min_interval=0.01,
        power_latency_interval=0.1,
        power_idle_stability_policy=settings.workspace / "idle_stability_policy.json",
        power_kernel_iterations=1,
        power_kernel_iterations_auto=True,
        power_target_sec=10.0,
        power_fpga_freq_mhz=100.0,
        power_fpga_freq_mhz_auto=True,
    )
    policy = strict_measurement_policy(
        suite, options, xclbin_sha256=str(candidate["xclbin_sha256"])
    )
    units = build_execution_units(suite, settings.state_root / "inspection")
    return evaluate_measurement_coverage(
        Path(str(task.metadata["raw_db"])), units, policy
    )


def _is_measurement_task(task: TaskSpec) -> bool:
    return task.stage == "run" and {"suite", "raw_db", "marker"} <= set(task.metadata)


def _coverage_problem(coverage: Any) -> str:
    from tools.latency_bench.runner import MeasurementReuseState

    return "; ".join(
        f"{item.exec_key}: {', '.join(item.reasons)}"
        for item in coverage.evidence
        if item.state is not MeasurementReuseState.REUSE
    ) or "measurement coverage is incomplete"


def _adopt_run_task(
    settings: PipelineSettings, task: TaskSpec, store: ReceiptStore, *, publish: bool,
    coverage: Any | None = None,
) -> tuple[bool, str]:
    if coverage is None:
        try:
            coverage = _strict_coverage_for_run_task(settings, task)
        except (OSError, KeyError, TypeError, ValueError) as error:
            return False, f"measurement adoption unavailable: {error}"
    if not coverage.complete:
        return False, _coverage_problem(coverage)
    if publish:
        with ResourceLocks(task.resources, owner=f"adopt:{task.key}"):
            _write_marker(
                task, measurement_evidence=measurement_adoption_evidence(coverage)
            )
            receipt = completed_receipt(task, attempt_id=f"adopt-{uuid.uuid4()}")
            store.publish(receipt)
    return True, "complete compatible measurement evidence can be adopted"


def _execute_task(
    task: TaskSpec,
    store: ReceiptStore,
    attempts_root: Path,
    *,
    post_validate: Any | None = None,
) -> TaskReceipt:
    attempt_id = str(uuid.uuid4())
    attempt_root = attempts_root / attempt_id / "output"
    log_root = attempts_root / attempt_id
    log_root.mkdir(parents=True, exist_ok=False)
    stdout_path = log_root / "stdout.log"
    stderr_path = log_root / "stderr.log"
    publication = task.metadata.get("publication_root")
    if publication:
        attempt_root.mkdir(parents=True)
        for name in task.metadata.get("seed_model_dirs", []):
            source = Path(str(publication)) / str(name)
            if source.is_dir():
                shutil.copytree(source, attempt_root / str(name))
    command = tuple(str(attempt_root) if part == "{attempt_root}" else part
                    for part in task.command)
    environment = os.environ.copy()
    environment.update({str(key): str(value)
                        for key, value in task.metadata.get("environment", {}).items()})
    started = _utc_now()
    owner = f"{task.key}:{attempt_id}"
    with stdout_path.open("w", encoding="utf-8") as stdout, \
            stderr_path.open("w", encoding="utf-8") as stderr:
        child = OwnedProcess.start(
            command, resources=task.resources, owner=owner, cwd=Path(__file__).parents[2],
            env=environment, stdout=stdout, stderr=stderr, start_new_session=True,
        )
        try:
            try:
                # Keep ownership through validation, publication, and receipt commit.
                return_code = child.wait(release=False)
            except BaseException:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                raise
            if return_code != 0:
                raise subprocess.CalledProcessError(return_code, command)
            evidence = post_validate() if post_validate is not None else ()
            _write_marker(task, measurement_evidence=evidence)
            logs = {"stdout": str(stdout_path), "stderr": str(stderr_path)}
            if publication:
                return publish_isolated_attempt(
                    task, store=store, attempt_root=attempt_root,
                    publication_root=Path(str(publication)), attempt_id=attempt_id,
                    started_at=started, logs=logs,
                )
            receipt = completed_receipt(
                task, attempt_id=attempt_id, started_at=started, logs=logs
            )
            store.publish(receipt)
            return receipt
        finally:
            child.close()


def _validate_excluded_prerequisites(
    settings: PipelineSettings, selected: tuple[str, ...], store: ReceiptStore,
    *, publish_adoption: bool,
) -> list[str]:
    problems: list[str] = []
    first = STAGES.index(selected[0])
    for stage in STAGES[:first]:
        if stage == "refine":
            for task in build_stage_tasks(settings, stage):
                decision = inspect_task(task, store)
                if decision.decision is not Decision.REUSE:
                    problems.append(
                        f"{task.key}: {decision.reason}; rerun with --from refine"
                    )
                    continue
                evidence = inspect_refinement_evidence(task.outputs[0].path)
                allowed, reason = refinement_allows_downstream(
                    evidence, require_convergence=settings.require_convergence
                )
                if not allowed:
                    problems.append(
                        f"{task.key}: {reason}; rerun with --from refine"
                    )
            continue
        for task in build_stage_tasks(settings, stage):
            decision = inspect_task(task, store)
            if _is_measurement_task(task):
                try:
                    coverage = _strict_coverage_for_run_task(settings, task)
                except (OSError, KeyError, TypeError, ValueError) as error:
                    decision = TaskDecision(
                        task, Decision.BLOCKED,
                        f"measurement validation unavailable: {error}",
                    )
                else:
                    if coverage.blocked_exec_keys:
                        decision = TaskDecision(
                            task, Decision.BLOCKED, _coverage_problem(coverage)
                        )
                    elif coverage.complete:
                        if decision.decision is Decision.REUSE:
                            continue
                        adopted, reason = _adopt_run_task(
                            settings, task, store, publish=publish_adoption,
                            coverage=coverage,
                        )
                        if adopted:
                            continue
                        decision = TaskDecision(task, Decision.PENDING, reason)
                    else:
                        decision = TaskDecision(
                            task, Decision.PENDING, _coverage_problem(coverage)
                        )
            if decision.decision is not Decision.REUSE:
                problems.append(f"{task.key}: {decision.reason}; rerun with --from {stage}")
    return problems


def run_pipeline(
    settings: PipelineSettings, *, first: str = "run", last: str = "plot",
    rerun: str | None = None, inspect_only: bool = False,
) -> tuple[int, dict[str, Any]]:
    """Execute stage barriers, committing each successful sibling independently."""

    selected = _stage_range(first, last, rerun)
    store = ReceiptStore(settings.state_root)
    summary: dict[str, Any] = {"tag": settings.tag, "range": list(selected), "tasks": [],
                               "settings": {
                                   "suite_size": settings.suite_size,
                                   "models": list(settings.models),
                                   "out_tokens": settings.out_tokens,
                                   "formats": list(settings.formats),
                                   "target_error": settings.target_error,
                                   "validation_samples": settings.validation_samples,
                                   "max_iterations": settings.max_iterations,
                                   "adopt_legacy": settings.adopt_legacy,
                                   "require_convergence": settings.require_convergence,
                               },
                               "reused": [], "adopted": [], "executed": [],
                               "blocked": [], "failed": []}
    if inspect_only:
        writer = _legacy_writer(settings)
        summary["external_writer"] = str(writer) if writer is not None else None
    if not inspect_only:
        writer = _legacy_writer(settings)
        if writer is not None:
            summary["blocked"].append(
                f"active external legacy writer recorded by {writer}; wait for it to finish"
            )
            return 2, summary
    problems = _validate_excluded_prerequisites(
        settings, selected, store, publish_adoption=not inspect_only
    )
    if problems:
        summary["blocked"].extend(problems)
        return (0 if inspect_only else 2), summary
    for stage in selected:
        tasks = build_stage_tasks(settings, stage)
        for task in tasks:
            # The aggregate consumes model artifacts produced by earlier
            # siblings in this same barrier, so resolve its identities only
            # after those receipts have committed.
            if stage == "compose" and task.metadata.get("seed_model_dirs"):
                task = _combined_compose_task(settings)
            decision = inspect_task(task, store)
            forced = rerun == stage
            measurement_coverage = None
            if _is_measurement_task(task):
                try:
                    measurement_coverage = _strict_coverage_for_run_task(settings, task)
                except (OSError, KeyError, TypeError, ValueError) as error:
                    summary["blocked"].append(
                        f"{task.key}: measurement validation unavailable: {error}"
                    )
                    if inspect_only:
                        continue
                    return (0 if inspect_only else 2), summary
                if measurement_coverage.blocked_exec_keys:
                    summary["blocked"].append(
                        f"{task.key}: {_coverage_problem(measurement_coverage)}"
                    )
                    if inspect_only:
                        continue
                    return (0 if inspect_only else 2), summary
                if not measurement_coverage.complete:
                    decision = TaskDecision(
                        task, Decision.PENDING,
                        _coverage_problem(measurement_coverage),
                    )
            if decision.decision is Decision.REUSE and not forced:
                summary["reused"].append(task.key)
                continue
            if (
                _is_measurement_task(task)
                and measurement_coverage is not None
                and measurement_coverage.complete
                and not inspect_only
            ):
                adopted, _ = _adopt_run_task(
                    settings, task, store, publish=True,
                    coverage=measurement_coverage,
                )
                if adopted:
                    summary["adopted"].append(task.key)
                    continue
            if inspect_only:
                summary["blocked" if decision.decision is Decision.BLOCKED else "executed"].append(
                    {"task": task.key, "action": "rerun" if forced else "pending",
                     "reason": decision.reason}
                )
                continue
            writer = _legacy_writer(settings)
            if writer is not None:
                summary["blocked"].append(
                    f"active external legacy writer recorded by {writer}; wait for it to finish"
                )
                return 2, summary
            try:
                post_validate = None
                if _is_measurement_task(task):
                    def post_validate(task: TaskSpec = task) -> tuple[dict[str, Any], ...]:
                        coverage = _strict_coverage_for_run_task(settings, task)
                        if coverage.blocked_exec_keys or not coverage.complete:
                            raise OutputValidationError(_coverage_problem(coverage))
                        return measurement_adoption_evidence(coverage)
                _execute_task(
                    task, store, settings.state_root / "attempts" / stage,
                    post_validate=post_validate,
                )
            except (Exception, KeyboardInterrupt) as error:
                summary["failed"].append({"task": task.key, "error": str(error)})
                return 1, summary
            summary["executed"].append(task.key)
        if STAGES.index(stage) >= STAGES.index("refine"):
            for model in settings.models:
                for label in EXECUTION_BINS:
                    evidence = inspect_refinement_evidence(
                        _refinement_checkpoint(settings, model, label)
                    )
                    allowed, reason = refinement_allows_downstream(
                        evidence, require_convergence=settings.require_convergence
                    )
                    if not allowed:
                        summary["blocked"].append(f"refine:{model}:{label}: {reason}")
            if summary["blocked"]:
                return (0 if inspect_only else 2), summary
    return 0, summary


def _parse_models(value: str) -> tuple[str, ...]:
    models = tuple(dict.fromkeys(part.strip() for part in value.split(",") if part.strip()))
    unknown = set(models) - set(MODEL_NAMES)
    if not models or unknown:
        raise argparse.ArgumentTypeError(f"expected comma-separated llama2,llama3; got {value!r}")
    return models


def _parse_formats(value: str) -> tuple[str, ...]:
    formats = tuple(dict.fromkeys(part.strip().lower() for part in value.split(",") if part.strip()))
    if not formats or set(formats) - {"png", "pdf", "svg"}:
        raise argparse.ArgumentTypeError("--formats must contain png,pdf,svg")
    return formats


def cli_main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="workflow.py")
    parser.add_argument("action", choices=("pipeline", "status"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--state-root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--suite-size", default=os.environ.get("SUITE_SIZE", "full"))
    parser.add_argument("--models", type=_parse_models, default=MODEL_NAMES)
    parser.add_argument("--from", dest="from_stage", choices=STAGES, default="run")
    parser.add_argument("--to", dest="to_stage", choices=STAGES, default="plot")
    parser.add_argument("--rerun", choices=STAGES)
    parser.add_argument("--adopt-legacy", action="store_true")
    parser.add_argument("--require-convergence", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--out-tokens", type=int, default=128)
    parser.add_argument("--formats", type=_parse_formats, default=("png", "pdf", "svg"))
    parser.add_argument("--target-error", type=float, default=0.05)
    parser.add_argument("--validation-samples", type=int, default=3)
    parser.add_argument("--max-iterations", type=int, default=3)
    parser.add_argument("--python", default=sys.executable)
    args = parser.parse_args(argv)
    if any(separator in args.tag for separator in (os.sep, os.altsep) if separator):
        parser.error("--tag must not contain path separators")
    try:
        _stage_range(args.from_stage, args.to_stage, args.rerun)
    except ValueError as error:
        parser.error(str(error))
    if args.out_tokens < 1 or args.validation_samples < 1 or args.max_iterations < 0:
        parser.error("out-tokens/validation-samples must be positive and max-iterations nonnegative")
    settings = PipelineSettings(
        tag=args.tag, workspace=args.workspace.resolve(), state_base=args.state_root.resolve(),
        suite_size=args.suite_size, models=tuple(args.models), out_tokens=args.out_tokens,
        formats=tuple(args.formats), target_error=args.target_error,
        validation_samples=args.validation_samples, max_iterations=args.max_iterations,
        adopt_legacy=args.adopt_legacy, require_convergence=args.require_convergence,
        python=args.python,
    )
    code, summary = run_pipeline(
        settings, first=args.from_stage, last=args.to_stage, rerun=args.rerun,
        inspect_only=(args.dry_run or args.status or args.action == "status"),
    )
    print(json.dumps(summary, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(cli_main())
