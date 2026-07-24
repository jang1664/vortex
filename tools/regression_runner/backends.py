from __future__ import annotations

import os
import sys
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path

from tools.latency_bench.fpga_bins import resolve_fpga_bin_config

from .models import RegressionCase


DEFAULT_SRUN_ARGS = (
    "--gres=fpga:u55c:1",
    "--cpus-per-task=4",
    "--mem=16G",
    "--time=12:00:00",
)


@dataclass(frozen=True)
class BackendContext:
    repo_root: Path
    build_dir: Path
    fpga_alias: str


class Backend(ABC):
    name: str

    @abstractmethod
    def validate(self, context: BackendContext) -> None:
        """Validate backend inputs before allocating execution resources."""

    @abstractmethod
    def case_command(self, context: BackendContext, case: RegressionCase) -> list[str]:
        """Return the command for one regression case."""

    def allocation_command(self, manifest_path: Path) -> list[str]:
        return [
            "srun",
            *DEFAULT_SRUN_ARGS,
            sys.executable,
            "-m",
            "tools.regression_runner",
            "_worker",
            "--manifest",
            str(manifest_path),
        ]


class HwBackend(Backend):
    name = "hw"

    def validate(self, context: BackendContext) -> None:
        if not context.fpga_alias:
            raise ValueError("--fpga-alias is required for the hw backend")

        wrapper = context.build_dir / "ci" / "run_black.sh"
        blackbox = context.build_dir / "ci" / "blackbox.sh"
        if not wrapper.is_file() or not blackbox.is_file():
            raise ValueError(
                f"configured build directory is missing ci/run_black.sh or ci/blackbox.sh: "
                f"{context.build_dir}"
            )

        resolved = resolve_fpga_bin_config(context.fpga_alias)
        if not resolved.path.is_dir():
            raise ValueError(
                f"FPGA bin directory for {context.fpga_alias!r} does not exist: {resolved.path}"
            )
        xclbin = resolved.path / "vortex_afu.xclbin"
        if not xclbin.is_file():
            raise ValueError(f"FPGA binary not found for {context.fpga_alias!r}: {xclbin}")
        if resolved.configs is not None and not resolved.configs.is_file():
            raise ValueError(
                f"FPGA config file not found for {context.fpga_alias!r}: {resolved.configs}"
            )

    def case_command(self, context: BackendContext, case: RegressionCase) -> list[str]:
        return [
            str(context.build_dir / "ci" / "run_black.sh"),
            "hw",
            "--no-srun",
            "--fpga-bin",
            context.fpga_alias,
            "--app",
            case.test,
            "--args",
            case.args,
        ]


BACKENDS: dict[str, type[Backend]] = {
    HwBackend.name: HwBackend,
}


def make_backend(name: str) -> Backend:
    backend_type = BACKENDS.get(name)
    if backend_type is None:
        supported = ", ".join(sorted(BACKENDS))
        raise ValueError(f"unsupported backend {name!r}; supported backends: {supported}")
    return backend_type()


def has_slurm_allocation(env: dict[str, str] | None = None) -> bool:
    values = os.environ if env is None else env
    return bool(values.get("SLURM_JOB_ID") or values.get("SLURM_STEP_ID"))
