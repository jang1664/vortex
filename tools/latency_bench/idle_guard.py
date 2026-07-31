#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import statistics
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Sequence


IDLE_UNSTABLE_EXIT_CODE = 75


@dataclass(frozen=True)
class IdlePolicy:
    window_samples: int = 8
    confirmation_windows: int = 2
    window_step_samples: int = 4
    max_wait_s: float = 4.0
    poll_interval_s: float = 0.05
    max_mean_delta_w: float = 0.08
    max_std_w: float = 0.30
    max_stderr_w: float = 0.08
    max_abs_slope_w_per_s: float = 0.08

    @property
    def required_samples(self) -> int:
        return self.window_samples + (
            (self.confirmation_windows - 1) * self.window_step_samples
        )

    def validate(self) -> None:
        if self.window_samples < 2:
            raise ValueError("window_samples must be >= 2")
        if self.confirmation_windows < 2:
            raise ValueError("confirmation_windows must be >= 2")
        if not 1 <= self.window_step_samples <= self.window_samples:
            raise ValueError(
                "window_step_samples must be in [1, window_samples]"
            )
        if self.max_wait_s <= 0.0:
            raise ValueError("max_wait_s must be > 0")
        if self.poll_interval_s <= 0.0:
            raise ValueError("poll_interval_s must be > 0")
        for name in (
            "max_mean_delta_w",
            "max_std_w",
            "max_stderr_w",
            "max_abs_slope_w_per_s",
        ):
            value = getattr(self, name)
            if not math.isfinite(value) or value < 0.0:
                raise ValueError(f"{name} must be a non-negative finite number")


@dataclass(frozen=True)
class PowerSample:
    timestamp_s: float
    total_power_w: float


@dataclass(frozen=True)
class WindowStats:
    start_s: float
    end_s: float
    samples: int
    mean_w: float
    std_w: float
    stderr_w: float
    slope_w_per_s: float


@dataclass(frozen=True)
class IdleDecision:
    stable: bool
    selected: WindowStats | None
    observed_samples: int
    mean_delta_w: float
    max_std_w: float
    max_stderr_w: float
    max_abs_slope_w_per_s: float
    reason: str


def _policy_values(raw: dict[str, Any]) -> dict[str, Any]:
    names = set(IdlePolicy.__dataclass_fields__)
    unknown = sorted(set(raw) - names)
    if unknown:
        raise ValueError(f"unknown idle policy field(s): {', '.join(unknown)}")
    return {key: raw[key] for key in names if key in raw}


def load_policy(path: Path, *, device_bdf: str = "") -> IdlePolicy:
    with path.open() as fp:
        raw = json.load(fp)
    if not isinstance(raw, dict):
        raise ValueError("idle policy root must be a JSON object")

    if "default" in raw or "devices" in raw:
        default = raw.get("default", {})
        devices = raw.get("devices", {})
        if not isinstance(default, dict) or not isinstance(devices, dict):
            raise ValueError("idle policy default/devices values must be objects")
        values = _policy_values(default)
        override = devices.get(device_bdf, {}) if device_bdf else {}
        if not isinstance(override, dict):
            raise ValueError(f"idle policy override for {device_bdf!r} must be an object")
        values.update(_policy_values(override))
    else:
        values = _policy_values(raw)

    policy = IdlePolicy(**values)
    policy.validate()
    return policy


def read_power_samples(
    path: Path,
    *,
    not_before_s: float | None = None,
    not_after_s: float | None = None,
) -> list[PowerSample]:
    if not path.exists():
        return []
    samples: list[PowerSample] = []
    try:
        with path.open(newline="") as fp:
            rows = csv.DictReader(fp)
            if not rows.fieldnames:
                return []
            for row in rows:
                try:
                    timestamp_s = float(row.get("timestamp_s", ""))
                    total_power_w = float(row.get("total_power_w", ""))
                except (TypeError, ValueError):
                    continue
                if not math.isfinite(timestamp_s) or not math.isfinite(total_power_w):
                    continue
                if not_before_s is not None and timestamp_s < not_before_s:
                    continue
                if not_after_s is not None and timestamp_s > not_after_s:
                    continue
                samples.append(PowerSample(timestamp_s, total_power_w))
    except OSError:
        return []
    return samples


def _window_stats(samples: Sequence[PowerSample]) -> WindowStats:
    timestamps = [sample.timestamp_s for sample in samples]
    watts = [sample.total_power_w for sample in samples]
    mean_w = statistics.fmean(watts)
    std_w = statistics.stdev(watts) if len(watts) > 1 else 0.0
    stderr_w = std_w / math.sqrt(len(watts))
    mean_t = statistics.fmean(timestamps)
    denominator = sum((timestamp - mean_t) ** 2 for timestamp in timestamps)
    slope = (
        sum(
            (timestamp - mean_t) * (watt - mean_w)
            for timestamp, watt in zip(timestamps, watts)
        )
        / denominator
        if denominator > 0.0
        else 0.0
    )
    return WindowStats(
        start_s=timestamps[0],
        end_s=timestamps[-1],
        samples=len(samples),
        mean_w=mean_w,
        std_w=std_w,
        stderr_w=stderr_w,
        slope_w_per_s=slope,
    )


def evaluate_idle(
    samples: Sequence[PowerSample],
    policy: IdlePolicy,
) -> IdleDecision:
    if len(samples) < policy.required_samples:
        return IdleDecision(
            stable=False,
            selected=None,
            observed_samples=len(samples),
            mean_delta_w=math.inf,
            max_std_w=math.inf,
            max_stderr_w=math.inf,
            max_abs_slope_w_per_s=math.inf,
            reason="samples_low",
        )

    windows: list[WindowStats] = []
    for offset in reversed(range(policy.confirmation_windows)):
        end = len(samples) - (offset * policy.window_step_samples)
        start = end - policy.window_samples
        windows.append(_window_stats(samples[start:end]))

    mean_delta_w = max(
        abs(right.mean_w - left.mean_w)
        for left, right in zip(windows, windows[1:])
    )
    max_std_w = max(window.std_w for window in windows)
    max_stderr_w = max(window.stderr_w for window in windows)
    max_abs_slope = max(abs(window.slope_w_per_s) for window in windows)

    failed: list[str] = []
    if mean_delta_w > policy.max_mean_delta_w:
        failed.append("mean_delta")
    if max_std_w > policy.max_std_w:
        failed.append("std")
    if max_stderr_w > policy.max_stderr_w:
        failed.append("stderr")
    if max_abs_slope > policy.max_abs_slope_w_per_s:
        failed.append("slope")
    return IdleDecision(
        stable=not failed,
        selected=windows[-1] if not failed else None,
        observed_samples=len(samples),
        mean_delta_w=mean_delta_w,
        max_std_w=max_std_w,
        max_stderr_w=max_stderr_w,
        max_abs_slope_w_per_s=max_abs_slope,
        reason="stable" if not failed else "+".join(failed),
    )


def replay_idle(
    samples: Sequence[PowerSample],
    policy: IdlePolicy,
) -> IdleDecision:
    last = evaluate_idle(samples[: policy.required_samples], policy)
    for count in range(policy.required_samples, len(samples) + 1):
        last = evaluate_idle(samples[:count], policy)
        if last.stable:
            return last
    return last


def wait_for_stable_idle(
    csv_path: Path,
    policy: IdlePolicy,
    *,
    not_before_s: float,
) -> IdleDecision:
    started = time.monotonic()
    last = evaluate_idle([], policy)
    while True:
        samples = read_power_samples(csv_path, not_before_s=not_before_s)
        last = evaluate_idle(samples, policy)
        if last.stable:
            return last
        if time.monotonic() - started >= policy.max_wait_s:
            return IdleDecision(
                stable=False,
                selected=None,
                observed_samples=last.observed_samples,
                mean_delta_w=last.mean_delta_w,
                max_std_w=last.max_std_w,
                max_stderr_w=last.max_stderr_w,
                max_abs_slope_w_per_s=last.max_abs_slope_w_per_s,
                reason=f"timeout:{last.reason}",
            )
        time.sleep(policy.poll_interval_s)


def _decision_dict(decision: IdleDecision) -> dict[str, Any]:
    result = asdict(decision)
    return result


def write_result(path: Path, decision: IdleDecision) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    with temporary.open("w", newline="") as fp:
        writer = csv.writer(fp)
        writer.writerow(
            (
                "stable",
                "start_s",
                "end_s",
                "samples",
                "mean_w",
                "std_w",
                "stderr_w",
                "slope_w_per_s",
                "mean_delta_w",
                "observed_samples",
                "reason",
            )
        )
        selected = decision.selected
        writer.writerow(
            (
                int(decision.stable),
                selected.start_s if selected else "",
                selected.end_s if selected else "",
                selected.samples if selected else "",
                selected.mean_w if selected else "",
                selected.std_w if selected else "",
                selected.stderr_w if selected else "",
                selected.slope_w_per_s if selected else "",
                decision.mean_delta_w,
                decision.observed_samples,
                decision.reason,
            )
        )
    temporary.replace(path)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Detect a stable FPGA idle-power window from sampler CSV data."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("wait", "replay"):
        sub = subparsers.add_parser(command)
        sub.add_argument("--csv", required=True, type=Path)
        sub.add_argument("--policy", required=True, type=Path)
        sub.add_argument("--device-bdf", default=os.environ.get("XRT_DEVICE_BDF", ""))
        sub.add_argument("--not-before", type=float, default=None)
        sub.add_argument("--not-after", type=float, default=None)
        sub.add_argument("--result", type=Path, default=None)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    policy = load_policy(args.policy, device_bdf=args.device_bdf)
    if args.command == "wait":
        if args.not_before is None:
            raise ValueError("wait requires --not-before")
        decision = wait_for_stable_idle(
            args.csv,
            policy,
            not_before_s=args.not_before,
        )
    else:
        samples = read_power_samples(
            args.csv,
            not_before_s=args.not_before,
            not_after_s=args.not_after,
        )
        decision = replay_idle(samples, policy)
    if args.result is not None:
        write_result(args.result, decision)
    print(json.dumps(_decision_dict(decision), sort_keys=True))
    return 0 if decision.stable else IDLE_UNSTABLE_EXIT_CODE


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"idle guard error: {exc}", file=sys.stderr)
        raise SystemExit(2)
