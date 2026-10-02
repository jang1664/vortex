#!/usr/bin/env python3
"""Open a saved FPGA implementation with the floorplan photo Tcl script."""

from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import shlex
import subprocess
import sys

from yaml import YAMLError

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EXPORT_TCL = ROOT / "hw/syn/xilinx/xrt/export_photo.tcl"
PROJECT_PATH = Path("_x/link/vivado/vpl/prj/prj.xpr")
sys.path.insert(0, str(ROOT))

from tools.latency_bench.fpga_bins import (  # noqa: E402
    list_fpga_bin_aliases,
    load_fpga_bin_aliases,
    resolve_fpga_bin_config,
)


def resolve_project(target: str, alias_map: Path | None) -> Path:
    path = Path(target).expanduser()
    if path.is_dir():
        path = path.resolve()
    else:
        aliases = load_fpga_bin_aliases(alias_map)
        if target not in aliases:
            raise ValueError(
                f"Unknown FPGA alias or directory: {target!r}. "
                "Use --list to see available aliases."
            )
        path = resolve_fpga_bin_config(target, aliases=aliases).path

    # Alias paths normally point to bin/, alongside the saved _x/ project.
    root = path
    if path.name == "bin" and not (path / "bin").is_dir():
        root = path.parent
    if not (root / "bin").is_dir():
        raise FileNotFoundError(f"FPGA root must contain a bin/ directory: {root}")
    project = root / PROJECT_PATH
    if not project.is_file():
        raise FileNotFoundError(f"Vivado project does not exist: {project}")
    return project


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Open or automatically capture the colored Vivado Device view."
    )
    parser.add_argument(
        "target", nargs="?", help="FPGA alias, root directory containing bin/, or bin/ directory."
    )
    parser.add_argument("--alias-map", type=Path, help="Override ci/fpga_bin_alias_map.yaml.")
    parser.add_argument("--list", action="store_true", help="List FPGA aliases and exit.")
    parser.add_argument("--impl-run", default="impl_1", help="Implementation run (default: impl_1).")
    parser.add_argument("--vivado", default="vivado", help="Vivado executable (default: vivado).")
    parser.add_argument(
        "--display", default=os.environ.get("DISPLAY") or ":1",
        help="X display (default: inherited DISPLAY, or :1).",
    )
    parser.add_argument("--dry-run", action="store_true", help="Validate paths without launching Vivado.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--capture", action="store_true", help="Capture PNG and PowerPoint on a private Xvfb display.")
    mode.add_argument("--image", type=Path, help="Create PowerPoint from an existing PNG without launching Vivado.")
    parser.add_argument("--pptx", type=Path, help="PowerPoint path (default: PNG path with .pptx suffix).")
    parser.add_argument("--title", help="Slide title (default: target or 'FPGA floorplan').")
    parser.add_argument("--output", type=Path, help="New capture directory (default: result/<target>_<timestamp>).")
    parser.add_argument("--timeout", type=float, default=900, help="Capture timeout in seconds (default: 900).")
    parser.add_argument("--settle", type=float, default=5, help="Rendering delay in seconds (default: 5).")
    args = parser.parse_args(argv)
    if not args.list and not args.target and not args.image:
        parser.error("target is required unless --list or --image is used")
    if args.image and args.target:
        parser.error("--image cannot be combined with a target; use --title for a slide title")
    if (args.pptx or args.title) and not (args.capture or args.image):
        parser.error("--pptx and --title require --capture or --image")
    if args.timeout <= 0 or args.settle < 0:
        parser.error("--timeout must be positive and --settle must be non-negative")
    if args.output and not args.capture:
        parser.error("--output requires --capture")

    try:
        if args.list:
            print("\n".join(list_fpga_bin_aliases(args.alias_map)))
            return 0
        if args.capture or args.image:
            from pptx_export import export_floorplan
        if args.image:
            image = args.image.expanduser().resolve()
            if not image.is_file():
                raise FileNotFoundError(f"Floorplan PNG does not exist: {image}")
            pptx = (args.pptx or image.with_suffix(".pptx")).expanduser().resolve()
            if args.dry_run:
                print(f"PowerPoint: {image} -> {pptx}")
                return 0
            export_floorplan(image, pptx, args.title or "FPGA floorplan")
            return 0
        project = resolve_project(args.target, args.alias_map)
        if not EXPORT_TCL.is_file():
            raise FileNotFoundError(f"Floorplan Tcl script does not exist: {EXPORT_TCL}")
        if not args.capture and not args.display:
            raise ValueError("--display must not be empty")
        command = [
            args.vivado, "-mode", "gui", "-nolog", "-nojournal", "-notrace",
            "-source", str(EXPORT_TCL), "-tclargs", str(project), args.impl_run,
        ]
        print(f"Project: {project}", flush=True)
        if args.capture:
            label = args.target if args.target.isidentifier() else project.parents[5].name
            output = (args.output or HERE / "result" / f"{label}_{datetime.now():%Y%m%d_%H%M%S_%f}").expanduser().resolve()
            print(f"Automatic capture: {output}", flush=True)
        else:
            print(f"Working directory: {HERE}", flush=True)
            print(f"DISPLAY={shlex.quote(args.display)} {shlex.join(command)}", flush=True)
        if args.dry_run:
            return 0
        if args.capture:
            from capture import capture_floorplan
            status = capture_floorplan(command, output, args.timeout, args.settle)
            if status == 0:
                image = output / "floorplan.png"
                pptx = (args.pptx or image.with_suffix(".pptx")).expanduser().resolve()
                export_floorplan(image, pptx, args.title or f"{label} — FPGA floorplan")
            return status
        env = os.environ.copy()
        env["DISPLAY"] = args.display
        return subprocess.call(command, cwd=HERE, env=env)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, YAMLError) as exc:
        parser.exit(1, f"error: {exc}\n")
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
