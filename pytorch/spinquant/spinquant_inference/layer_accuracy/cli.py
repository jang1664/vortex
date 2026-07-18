"""Command-line entry point for creating, running, and comparing layer cases."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

from .artifacts import (
    create_checkpoint_case,
    create_random_case,
    load_case,
    save_case,
)
from .backends import TorchBackend, VortexBackend
from .compare import compare_runs
from .graph import LayerExecutor
from .generator_conformance import check_generator_conformance
from .run_artifacts import load_run, save_run
from .specs import LayerConfig
from .stages import STAGE_NAMES


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m spinquant_inference.layer_accuracy",
        description="Compare one SpinQuant Llama2-7B decoder layer on CUDA and Vortex.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    make_case = commands.add_parser("make-case", help="create a portable input/weight case")
    make_case.add_argument("--source", choices=("random", "checkpoint"), required=True)
    make_case.add_argument("--output", type=Path, required=True)
    make_case.add_argument("--seed", type=int, default=0)
    make_case.add_argument("--checkpoint", type=Path)
    make_case.add_argument("--checkpoint-profile", choices=("spinquant-w4a16-r3r4",))
    make_case.add_argument("--layer-index", type=int, default=0)
    make_case.add_argument("--batch-size", type=_positive_int, default=1)
    make_case.add_argument("--seq-len", type=_positive_int, default=32)

    run = commands.add_parser("run", help="execute one backend and save stage captures")
    run.add_argument("--case", type=Path, required=True)
    run.add_argument("--backend", choices=("cuda", "vortex", "cpu"), required=True)
    run.add_argument("--stop-after", choices=STAGE_NAMES, default="final_residual")
    run.add_argument("--capture", choices=("semantic", "physical", "both"), default="semantic")
    run.add_argument("--physical-plan", choices=("standalone", "fused"), default="standalone")
    run.add_argument("--strict-native", action="store_true")
    run.add_argument("--output", type=Path, required=True)

    compare = commands.add_parser("compare", help="compare two saved backend runs")
    compare.add_argument("--reference", type=Path, required=True)
    compare.add_argument("--candidate", type=Path, required=True)
    compare.add_argument("--profile", choices=("llama2_fp16_w4kv4_v1",), default="llama2_fp16_w4kv4_v1")
    compare.add_argument("--include-auxiliary", action="store_true")
    compare.add_argument("--output", type=Path)

    conformance = commands.add_parser(
        "check-generator", help="advisory check against tools/workload/gen_kernel_cfgs.py"
    )
    conformance.add_argument("--generator", type=Path)
    conformance.add_argument("--output", type=Path)
    return parser


def _make_case(args: argparse.Namespace) -> int:
    config = LayerConfig(
        batch_size=args.batch_size,
        sequence_length=args.seq_len,
    )
    if args.source == "random":
        if args.checkpoint is not None or args.checkpoint_profile is not None:
            raise SystemExit("--checkpoint and --checkpoint-profile are valid only with --source checkpoint")
        case = create_random_case(config=config, seed=args.seed)
    else:
        if args.checkpoint is None or args.checkpoint_profile is None:
            raise SystemExit("--source checkpoint requires --checkpoint and --checkpoint-profile")
        case = create_checkpoint_case(
            args.checkpoint,
            layer_index=args.layer_index,
            checkpoint_profile=args.checkpoint_profile,
            config=config,
            seed=args.seed,
        )
    save_case(case, args.output)
    print(f"created case {args.output} ({case.manifest['case_hash']})")
    return 0


def _run(args: argparse.Namespace) -> int:
    if args.backend != "vortex" and args.physical_plan != "standalone":
        raise SystemExit("--physical-plan fused is valid only with --backend vortex")
    case = load_case(args.case)
    if args.backend == "cuda":
        backend = TorchBackend("cuda")
    elif args.backend == "cpu":
        backend = TorchBackend("cpu")
    else:
        if not args.strict_native:
            raise SystemExit("the Vortex accuracy backend requires --strict-native")
        backend = VortexBackend(strict_native=True, physical_plan=args.physical_plan)
    result = LayerExecutor(backend).run(
        case,
        stop_after=args.stop_after,
        capture_physical=args.capture in ("physical", "both"),
    )
    save_run(result, args.output, capture_mode=args.capture)
    print(
        f"saved {result.backend} run through {result.stop_after} to {args.output} "
        f"({len(result.stage_order)} semantic captures)"
    )
    return 0


def _compare(args: argparse.Namespace) -> int:
    reference_meta, reference, reference_aux = load_run(args.reference)
    candidate_meta, candidate, candidate_aux = load_run(args.candidate)
    if reference_meta["case_hash"] != candidate_meta["case_hash"]:
        raise SystemExit("reference and candidate were produced from different case hashes")
    if reference_meta["graph_version"] != candidate_meta["graph_version"]:
        raise SystemExit("reference and candidate use different semantic graph versions")
    if args.include_auxiliary:
        reference = {**reference, **reference_aux}
        candidate = {**candidate, **candidate_aux}
    report = compare_runs(reference, candidate, profile=args.profile)
    report.update(
        {
            "reference_backend": reference_meta["backend"],
            "candidate_backend": candidate_meta["backend"],
            "case_hash": reference_meta["case_hash"],
            "reference_placement": reference_meta["placement"],
            "candidate_placement": candidate_meta["placement"],
        }
    )
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if report["passed"] else 1


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "make-case":
        return _make_case(args)
    if args.command == "run":
        return _run(args)
    if args.command == "compare":
        return _compare(args)
    if args.command == "check-generator":
        report = check_generator_conformance(args.generator)
        encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.write_text(encoded, encoding="utf-8")
        print(encoded, end="")
        return 0 if report["passed"] else 1
    raise AssertionError(f"unhandled command {args.command!r}")
