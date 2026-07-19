"""Command-line entry point for creating, running, and comparing layer cases."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

from .artifacts import (
    create_checkpoint_decode_case,
    create_checkpoint_case,
    create_checkpoint_stack_case,
    create_random_decode_case,
    create_random_case,
    create_random_stack_case,
    load_case,
    load_decode_case,
    load_stack_case,
    save_decode_case,
    save_case,
    save_stack_case,
)
from .backends import TorchBackend, VortexBackend
from .compare import COMPARISON_PROFILES, compare_runs
from .graph import DecodeExecutor, LayerExecutor, StackExecutor
from .generator_conformance import check_generator_conformance
from .run_artifacts import load_run, save_decode_run, save_run, save_stack_run
from .specs import DecodeConfig, LayerConfig, StackConfig, SUPPORTED_MODELS
from .stages import DECODE_STAGE_NAMES, STAGE_NAMES, DecodeStopPoint


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m spinquant_inference.layer_accuracy",
        description="Compare one SpinQuant Llama decoder layer on CUDA and Vortex.",
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
    make_case.add_argument("--model", choices=SUPPORTED_MODELS, default=SUPPORTED_MODELS[0])

    make_decode_case = commands.add_parser(
        "make-decode-case", help="create a prompt plus one-token decode inputs"
    )
    make_decode_case.add_argument("--source", choices=("random", "checkpoint"), required=True)
    make_decode_case.add_argument("--output", type=Path, required=True)
    make_decode_case.add_argument("--seed", type=int, default=0)
    make_decode_case.add_argument("--checkpoint", type=Path)
    make_decode_case.add_argument("--checkpoint-profile", choices=("spinquant-w4a16-r3r4",))
    make_decode_case.add_argument("--layer-index", type=int, default=0)
    make_decode_case.add_argument("--batch-size", type=_positive_int, default=1)
    make_decode_case.add_argument(
        "--model", choices=SUPPORTED_MODELS, default=SUPPORTED_MODELS[0]
    )
    make_decode_case.add_argument("--prompt-len", type=_positive_int, required=True)
    make_decode_case.add_argument("--decode-steps", type=_positive_int, required=True)
    make_decode_case.add_argument("--max-seq-len", type=_positive_int, required=True)

    make_stack_case = commands.add_parser(
        "make-stack-case", help="create a multi-layer decoder-stack case"
    )
    make_stack_case.add_argument(
        "--source", choices=("random", "checkpoint"), required=True
    )
    make_stack_case.add_argument("--output", type=Path, required=True)
    make_stack_case.add_argument("--seed", type=int, default=0)
    make_stack_case.add_argument("--checkpoint", type=Path)
    make_stack_case.add_argument(
        "--checkpoint-profile", choices=("spinquant-w4a16-r3r4",)
    )
    make_stack_case.add_argument("--layer-start", type=int, default=0)
    make_stack_case.add_argument("--num-layers", type=_positive_int)
    make_stack_case.add_argument("--batch-size", type=_positive_int, default=1)
    make_stack_case.add_argument("--seq-len", type=_positive_int, default=32)
    make_stack_case.add_argument(
        "--model", choices=SUPPORTED_MODELS, default=SUPPORTED_MODELS[0]
    )
    make_stack_case.add_argument(
        "--random-weight-mode",
        choices=("shared", "independent"),
        default="shared",
    )

    run = commands.add_parser("run", help="execute one backend and save stage captures")
    run.add_argument("--case", type=Path, required=True)
    run.add_argument("--backend", choices=("cuda", "vortex", "cpu"), required=True)
    run.add_argument(
        "--stop-after",
        choices=tuple(dict.fromkeys((*STAGE_NAMES, *DECODE_STAGE_NAMES))),
        default="final_residual",
    )
    run.add_argument(
        "--decode-step",
        type=int,
        help="zero-based decode step for a decode case (defaults to the final step)",
    )
    run.add_argument(
        "--stop-after-layer",
        type=int,
        help="zero-based model-global stop layer for a decoder-stack case",
    )
    run.add_argument("--capture", choices=("semantic", "physical", "both"), default="semantic")
    run.add_argument("--physical-plan", choices=("standalone", "fused"), default="standalone")
    run.add_argument("--strict-native", action="store_true")
    run.add_argument("--output", type=Path, required=True)

    compare = commands.add_parser("compare", help="compare two saved backend runs")
    compare.add_argument("--reference", type=Path, required=True)
    compare.add_argument("--candidate", type=Path, required=True)
    compare.add_argument(
        "--profile",
        choices=COMPARISON_PROFILES,
        default=COMPARISON_PROFILES[0],
    )
    compare.add_argument("--include-auxiliary", action="store_true")
    compare.add_argument("--output", type=Path)

    conformance = commands.add_parser(
        "check-generator", help="advisory check against tools/workload/gen_kernel_cfgs.py"
    )
    conformance.add_argument("--generator", type=Path)
    conformance.add_argument("--output", type=Path)
    return parser


def _make_case(args: argparse.Namespace) -> int:
    config = LayerConfig.for_model(
        args.model,
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


def _make_decode_case(args: argparse.Namespace) -> int:
    total_length = args.prompt_len + args.decode_steps
    config = DecodeConfig(
        layer=LayerConfig.for_model(
            args.model, batch_size=args.batch_size, sequence_length=total_length
        ),
        prompt_length=args.prompt_len,
        decode_steps=args.decode_steps,
        max_sequence_length=args.max_seq_len,
    )
    if args.source == "random":
        if args.checkpoint is not None or args.checkpoint_profile is not None:
            raise SystemExit(
                "--checkpoint and --checkpoint-profile are valid only with --source checkpoint"
            )
        case = create_random_decode_case(config, seed=args.seed)
    else:
        if args.checkpoint is None or args.checkpoint_profile is None:
            raise SystemExit(
                "--source checkpoint requires --checkpoint and --checkpoint-profile"
            )
        case = create_checkpoint_decode_case(
            args.checkpoint,
            layer_index=args.layer_index,
            checkpoint_profile=args.checkpoint_profile,
            config=config,
            seed=args.seed,
        )
    save_decode_case(case, args.output)
    print(f"created decode case {args.output} ({case.manifest['case_hash']})")
    return 0


def _make_stack_case(args: argparse.Namespace) -> int:
    config = StackConfig.for_model(
        args.model,
        layer_start=args.layer_start,
        layer_count=args.num_layers,
        batch_size=args.batch_size,
        sequence_length=args.seq_len,
    )
    if args.source == "random":
        if args.checkpoint is not None or args.checkpoint_profile is not None:
            raise SystemExit(
                "--checkpoint and --checkpoint-profile are valid only with "
                "--source checkpoint"
            )
        case = create_random_stack_case(
            config,
            seed=args.seed,
            random_weight_mode=args.random_weight_mode,
        )
    else:
        if args.checkpoint is None or args.checkpoint_profile is None:
            raise SystemExit(
                "--source checkpoint requires --checkpoint and --checkpoint-profile"
            )
        case = create_checkpoint_stack_case(
            args.checkpoint,
            config=config,
            checkpoint_profile=args.checkpoint_profile,
            seed=args.seed,
        )
    save_stack_case(case, args.output)
    print(f"created decoder stack case {args.output} ({case.manifest['case_hash']})")
    return 0


def _run(args: argparse.Namespace) -> int:
    if args.backend != "vortex" and args.physical_plan != "standalone":
        raise SystemExit("--physical-plan fused is valid only with --backend vortex")
    manifest = json.loads((args.case / "manifest.json").read_text(encoding="utf-8"))
    is_decode = manifest.get("case_kind") == "decode"
    is_stack = manifest.get("case_kind") == "decoder_stack"
    if is_decode:
        case = load_decode_case(args.case)
    elif is_stack:
        case = load_stack_case(args.case)
    else:
        case = load_case(args.case)
    if args.backend == "cuda":
        backend = TorchBackend("cuda")
    elif args.backend == "cpu":
        backend = TorchBackend("cpu")
    else:
        if not args.strict_native:
            raise SystemExit("the Vortex accuracy backend requires --strict-native")
        backend = VortexBackend(strict_native=True, physical_plan=args.physical_plan)
    capture_physical = args.capture in ("physical", "both")
    if is_decode:
        if getattr(args, "stop_after_layer", None) is not None:
            raise SystemExit("--stop-after-layer is valid only for a decoder-stack case")
        step = (
            case.config.decode_steps - 1
            if args.decode_step is None
            else args.decode_step
        )
        stop = DecodeStopPoint(step=step, stage=args.stop_after)
        result = DecodeExecutor(backend).run(
            case,
            stop_after=stop,
            capture_physical=capture_physical,
        )
        save_decode_run(result, args.output, capture_mode=args.capture)
        capture_count = len(result.prefill.stage_order) + sum(
            len(value.stage_order) for value in result.steps
        )
        stop_label = f"step{stop.step}:{stop.stage}"
    elif is_stack:
        if args.decode_step is not None:
            raise SystemExit("--decode-step is valid only for a decode case")
        result = StackExecutor(backend).run(
            case,
            stop_after_layer=getattr(args, "stop_after_layer", None),
            stop_after=args.stop_after,
            capture_physical=capture_physical,
        )
        save_stack_run(result, args.output, capture_mode=args.capture)
        capture_count = len(result.captures)
        stop_label = f"layer{result.stop_after_layer}:{result.stop_after}"
    else:
        if args.decode_step is not None:
            raise SystemExit("--decode-step is valid only for a decode case")
        if getattr(args, "stop_after_layer", None) is not None:
            raise SystemExit("--stop-after-layer is valid only for a decoder-stack case")
        if args.stop_after not in STAGE_NAMES:
            raise SystemExit(f"{args.stop_after!r} is valid only for a decode case")
        result = LayerExecutor(backend).run(
            case,
            stop_after=args.stop_after,
            capture_physical=capture_physical,
        )
        save_run(result, args.output, capture_mode=args.capture)
        capture_count = len(result.stage_order)
        stop_label = result.stop_after
    print(
        f"saved {result.backend} run through {stop_label} to {args.output} "
        f"({capture_count} semantic captures)"
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
    if args.command == "make-decode-case":
        return _make_decode_case(args)
    if args.command == "make-stack-case":
        return _make_stack_case(args)
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
