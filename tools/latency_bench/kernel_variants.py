"""Resolve and record software implementations independently of model variants."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess


def variant_variable(repo: Path, app: str) -> str | None:
    if not re.fullmatch(r"[A-Za-z0-9_]+", app):
        raise ValueError(f"invalid application name: {app!r}")
    makefile = repo / "tests" / "regression" / app / "Makefile"
    if not makefile.is_file():
        raise ValueError(f"unknown application: {app}")
    matches = re.findall(r"^([A-Z0-9_]+_VARIANT)\s*\?=", makefile.read_text(), re.M)
    return matches[0] if matches else None


def parse_variants(values: tuple[str, ...] | list[str], repo: Path) -> dict[str, str]:
    result = {}
    for value in values:
        app, sep, variant = value.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z0-9_]+", variant):
            raise ValueError("kernel variant must be APP=NAME")
        variable = variant_variable(repo, app)
        if not variable:
            raise ValueError(f"{app} does not expose a selectable kernel variant")
        text = (repo / "tests" / "regression" / app / "Makefile").read_text()
        allowed = re.search(r"^" + re.escape(variable) + r"S\s*:?=\s*(.*)$", text, re.M)
        if allowed and variant not in allowed.group(1).split():
            raise ValueError(f"unsupported {app} variant: {variant}")
        if app in result and result[app] != variant:
            raise ValueError(f"conflicting variants for {app}")
        result[app] = variant
    return result


def variant_environment(repo: Path, requested: dict[str, str]) -> dict[str, str]:
    return {variant_variable(repo, app): value for app, value in requested.items()}


def source_identity(repo: Path, app: str) -> str:
    """Hash app sources and their local include graph, excluding build artifacts."""
    directory = repo / "tests" / "regression" / app
    pending = list(directory.glob("*.cpp")) + list(directory.glob("*.h")) + [directory / "Makefile"]
    seen = set()
    digest = hashlib.sha256()
    while pending:
        path = pending.pop().resolve()
        if path in seen or not path.is_file() or not path.is_relative_to(repo.resolve()):
            continue
        seen.add(path)
        for include in re.findall(r'^\s*#\s*include\s*"([^"]+)"', path.read_text(), re.M):
            pending.append(path.parent / include)
    for path in sorted(seen):
        digest.update(str(path.relative_to(repo.resolve())).encode() + b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def query_selection(build: Path, app: str, configs: Path | None = None,
                    requested: str = "") -> tuple[str, str, list[str]]:
    repo = Path(__file__).resolve().parents[2]
    build = build.resolve()
    variable = variant_variable(repo, app)
    selected_var = variable.replace("_VARIANT", "_SELECTED_VARIANT") if variable else ""
    expression = f"$({selected_var})" if selected_var else ""
    query = "\n".join([
        ".PHONY: latency-variant-info",
        "latency-variant-info:",
        "\t@printf '%s\\n' '" + (f"$({variable})" if variable else "default") + "' '" + expression + "' '$(VX_SRCS)'",
    ])
    command = ["make", "--no-print-directory", "-s", "-C", str(build / "tests/regression" / app),
               "--eval", query, "latency-variant-info"]
    setup = []
    if configs is not None:
        setup.append("source " + shlex.quote(str(configs.resolve())) + " >/dev/null")
    if requested and variable:
        setup.append("export " + variable + "=" + shlex.quote(requested))
    if setup:
        command = ["bash", "-c", "\n".join(["set -e", *setup, "exec " + shlex.join(command)])]
    lines = subprocess.check_output(command, text=True, cwd=build).splitlines()
    if len(lines) != 3:
        raise RuntimeError(f"unexpected make variant query for {app}: {lines}")
    return lines[0], lines[1] or lines[0], lines[2].split()


def capture(build: Path, out: Path, app: str, requested: str = "") -> dict:
    repo = Path(__file__).resolve().parents[2]
    variable = variant_variable(repo, app)
    configured, selected, sources = query_selection(build, app)
    binary = build / "tests/regression" / app / "kernel.vxbin"
    record = dict(requested=requested or None, configured=configured, selected=selected,
                  make_variable=variable, selection="cli" if requested else
                  "environment" if variable and variable in os.environ else "makefile_default",
                  sources=sources, source_identity=source_identity(repo, app),
                  kernel_vxbin_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    path = out / "kernel_variants.json"
    payload = json.loads(path.read_text()) if path.exists() else {"schema_version": 1, "apps": {}}
    payload["apps"][app] = record
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    manifest_path = out / "manifest.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        manifest["kernel_variants"] = payload["apps"]
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return record


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--requested", default="")
    args = parser.parse_args()
    capture(args.build_dir, args.out, args.app, args.requested)


if __name__ == "__main__":
    main()
