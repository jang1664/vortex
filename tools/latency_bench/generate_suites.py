from __future__ import annotations

import json
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .suite import (
    BenchCase,
    BenchDefaults,
    BenchSuite,
    SuiteMatrixOverrides,
    find_repo_root,
    load_suite_artifacts,
    resolve_case_fpga_bin,
    sanitize_id,
    suite_to_expanded_yaml,
)
from .yaml_io import safe_dump


@dataclass(frozen=True)
class GenerateSuitesOptions:
    suite: Path
    out_dir: Path
    overwrite: bool = False
    repo_root: Path | None = None
    batch_values: tuple[int, ...] = ()
    seq_len_values: tuple[int, ...] = ()
    prefill_batch_values: tuple[int, ...] = ()
    generation_batch_values: tuple[int, ...] = ()
    prefill_seq_len_values: tuple[int, ...] = ()
    generation_seq_len_values: tuple[int, ...] = ()
    generation_out_token_values: tuple[int, ...] = ()
    generation_max_seq_len: int | None = None
    generation_decode_measurement: str | None = None
    generation_decode_sample_interval: int | None = None
    dump_model_structures: bool = False


def _case_without_fpga_bin(case: BenchCase) -> BenchCase:
    return BenchCase(**{**case.__dict__, "fpga_bin": ""})


def _group_name(base_name: str, app: str, fpga_bin: str) -> str:
    return sanitize_id(f"{base_name}__{app}__{fpga_bin}")


def _run_command(suite_path: Path, out_dir: Path) -> str:
    return " ".join([
        "python",
        "-m",
        "tools.latency_bench",
        "run",
        "--suite",
        shlex.quote(str(suite_path)),
        "--out",
        shlex.quote(str(out_dir)),
    ])


def _write_model_structure_dumps(
    out_dir: Path,
    suite_name: str,
    structures: list[dict[str, Any]],
) -> dict[str, str]:
    from tools.workload.gen_kernel_cfgs import format_layout_view

    paths = {
        "json": out_dir / "model_structure.json",
        "layout": out_dir / "model_structure.layout",
        "text": out_dir / "model_structure.text",
    }
    with paths["json"].open("w") as fp:
        json.dump({"suite": suite_name, "structures": structures}, fp, indent=2)
        fp.write("\n")
    with paths["layout"].open("w") as layout_fp, paths["text"].open("w") as text_fp:
        for index, structure in enumerate(structures):
            prefix = "" if index == 0 else "\n"
            rendered = f"{prefix}[workload: {structure['workload_id']}]\n{format_layout_view(structure)}"
            layout_fp.write(rendered)
            text_fp.write(rendered)
    return {name: str(path) for name, path in paths.items()}


def generate_suites(options: GenerateSuitesOptions) -> dict[str, Any]:
    repo_root = options.repo_root or find_repo_root()
    matrix_overrides = SuiteMatrixOverrides(
        batch_values=tuple(options.batch_values),
        seq_len_values=tuple(options.seq_len_values),
        prefill_batch_values=tuple(options.prefill_batch_values),
        generation_batch_values=tuple(options.generation_batch_values),
        prefill_seq_len_values=tuple(options.prefill_seq_len_values),
        generation_seq_len_values=tuple(options.generation_seq_len_values),
        generation_out_token_values=tuple(options.generation_out_token_values),
        generation_max_seq_len=options.generation_max_seq_len,
        generation_decode_measurement=options.generation_decode_measurement,
        generation_decode_sample_interval=options.generation_decode_sample_interval,
    )
    loaded = load_suite_artifacts(
        options.suite,
        repo_root=repo_root,
        matrix_overrides=matrix_overrides,
    )
    source_suite = loaded.suite
    out_dir = options.out_dir.expanduser().resolve()

    groups: dict[tuple[str, str], list[BenchCase]] = {}
    for case in source_suite.cases:
        fpga_bin = resolve_case_fpga_bin(source_suite, case)
        groups.setdefault((case.app, fpga_bin), []).append(case)

    generated_specs: list[tuple[Path, BenchSuite, str, str]] = []
    for app, fpga_bin in sorted(groups):
        name = _group_name(source_suite.name, app, fpga_bin)
        generated_suite = BenchSuite(
            name=name,
            defaults=BenchDefaults(**{**source_suite.defaults.__dict__, "app": app, "fpga_bin": fpga_bin}),
            cases=[_case_without_fpga_bin(case) for case in groups[(app, fpga_bin)]],
        )
        generated_specs.append((out_dir / f"{name}.yaml", generated_suite, app, fpga_bin))

    index_path = out_dir / "index.yaml"
    targets = [index_path, *(path for path, _suite, _app, _fpga_bin in generated_specs)]
    if options.dump_model_structures:
        targets.extend([
            out_dir / "model_structure.json",
            out_dir / "model_structure.layout",
            out_dir / "model_structure.text",
        ])
    existing = [path for path in targets if path.exists()]
    if existing and not options.overwrite:
        formatted = ", ".join(str(path) for path in existing)
        raise FileExistsError(f"generated suite output already exists; use --overwrite: {formatted}")

    out_dir.mkdir(parents=True, exist_ok=True)
    index: dict[str, Any] = {
        "base_suite": str(options.suite.expanduser().resolve()),
        "output_dir": str(out_dir),
        "generated": [],
    }
    if options.dump_model_structures:
        index["model_structures"] = _write_model_structure_dumps(
            out_dir,
            source_suite.name,
            loaded.workload_structures,
        )
    for suite_path, generated_suite, app, fpga_bin in generated_specs:
        with suite_path.open("w") as fp:
            safe_dump(suite_to_expanded_yaml(generated_suite), fp, sort_keys=False)
        kinds = sorted({case.kind for case in generated_suite.cases if case.kind})
        backends = sorted({case.backend for case in generated_suite.cases if case.backend})
        index["generated"].append({
            "suite": str(suite_path),
            "name": generated_suite.name,
            "app": app,
            "fpga_bin": fpga_bin,
            "kinds": kinds,
            "backends": backends,
            "case_count": len(generated_suite.cases),
            "run_command": _run_command(suite_path, out_dir / generated_suite.name),
        })

    with index_path.open("w") as fp:
        safe_dump(index, fp, sort_keys=False)
    return index
