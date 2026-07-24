from __future__ import annotations

import hashlib
import re
from pathlib import Path

from .models import CaseSpec, RegressionCase


CASE_SEPARATOR = "::"


def find_repo_root(start: Path | None = None) -> Path:
    current = (start or Path.cwd()).resolve()
    for candidate in (current, *current.parents):
        if (candidate / "tests" / "regression").is_dir() and (candidate / "ci" / "run_black.sh").is_file():
            return candidate
    raise RuntimeError("Vortex repository root not found")


def discover_tests(repo_root: Path) -> list[str]:
    regression_root = repo_root / "tests" / "regression"
    if not regression_root.is_dir():
        raise ValueError(f"regression directory not found: {regression_root}")

    tests: list[str] = []
    for makefile in regression_root.rglob("Makefile"):
        test_dir = makefile.parent
        if test_dir == regression_root or not (test_dir / "main.cpp").is_file():
            continue
        tests.append(test_dir.relative_to(regression_root).as_posix())
    return sorted(set(tests))


def compile_regex(pattern: str, *, option: str) -> re.Pattern[str]:
    try:
        return re.compile(pattern)
    except re.error as exc:
        raise ValueError(f"invalid {option} regex {pattern!r}: {exc}") from exc


def parse_case_spec(raw: str) -> CaseSpec:
    pattern, separator, args = raw.partition(CASE_SEPARATOR)
    if not separator:
        raise ValueError(
            f"invalid --case {raw!r}: expected REGEX{CASE_SEPARATOR}ARGS "
            f"(use REGEX{CASE_SEPARATOR} for empty arguments)"
        )
    if not pattern:
        raise ValueError(f"invalid --case {raw!r}: test regex must not be empty")
    compile_regex(pattern, option="--case")
    return CaseSpec(pattern=pattern, args=args)


def _case_id(order: int, test: str, args: str) -> str:
    safe_test = re.sub(r"[^A-Za-z0-9_.-]+", "_", test).strip("_") or "test"
    digest = hashlib.sha256(f"{test}\0{args}".encode()).hexdigest()[:10]
    return f"{order:04d}-{safe_test}-{digest}"


def expand_cases(
    tests: list[str],
    specs: list[CaseSpec],
    exclude_patterns: list[str] | None = None,
) -> list[RegressionCase]:
    if not specs:
        raise ValueError("run requires at least one --case")

    excludes = [
        compile_regex(pattern, option="--exclude")
        for pattern in (exclude_patterns or [])
    ]
    expanded: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()

    for spec in specs:
        regex = compile_regex(spec.pattern, option="--case")
        matched = [test for test in tests if regex.search(test)]
        if not matched:
            raise ValueError(f"--case regex matched no tests: {spec.pattern!r}")

        for test in matched:
            excluded = False
            for regex_exclude in excludes:
                if regex_exclude.search(test):
                    excluded = True
            pair = (test, spec.args)
            if not excluded and pair not in seen:
                seen.add(pair)
                expanded.append(pair)

    if not expanded:
        raise ValueError("all selected cases were excluded")

    return [
        RegressionCase(
            order=index,
            case_id=_case_id(index, test, args),
            test=test,
            args=args,
        )
        for index, (test, args) in enumerate(expanded, start=1)
    ]


def filter_tests(
    tests: list[str],
    include_patterns: list[str] | None = None,
    exclude_patterns: list[str] | None = None,
) -> list[str]:
    includes = [
        compile_regex(pattern, option="--match")
        for pattern in (include_patterns or [])
    ]
    excludes = [
        compile_regex(pattern, option="--exclude")
        for pattern in (exclude_patterns or [])
    ]
    return [
        test
        for test in tests
        if (not includes or any(regex.search(test) for regex in includes))
        and not any(regex.search(test) for regex in excludes)
    ]
