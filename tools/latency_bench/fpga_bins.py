from __future__ import annotations

import os
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


CompileConfigs = tuple[str, ...]
FPGA_BIN_ALIAS_MAP_ENV = "VORTEX_FPGA_BIN_ALIAS_MAP"
DEFAULT_FPGA_BIN_ALIAS_MAP = Path(__file__).resolve().parents[2] / "ci" / "fpga_bin_alias_map.yaml"


@dataclass(frozen=True)
class FpgaBinAlias:
    path: str
    configs_extra: CompileConfigs = ()


@dataclass(frozen=True)
class FpgaBinConfig:
    path: Path
    configs_extra: CompileConfigs = ()


def normalize_fpga_bin(path: Path) -> Path:
    path = path.expanduser().resolve()
    return path.parent if path.name == "vortex_afu.xclbin" else path


def alias_map_path(path: str | Path | None = None) -> Path:
    if path is not None:
        return Path(path).expanduser()
    env_path = os.environ.get(FPGA_BIN_ALIAS_MAP_ENV)
    if env_path:
        return Path(env_path).expanduser()
    return DEFAULT_FPGA_BIN_ALIAS_MAP


def _configs_from_yaml(value: Any, *, alias: str) -> CompileConfigs:
    if value is None:
        return ()
    if isinstance(value, str):
        return tuple(shlex.split(value))
    if isinstance(value, list):
        configs: list[str] = []
        for item in value:
            if not isinstance(item, str):
                raise ValueError(f"configs_extra for FPGA bin alias {alias!r} must contain only strings")
            configs.append(item)
        return tuple(configs)
    raise ValueError(f"configs_extra for FPGA bin alias {alias!r} must be a string or list")


def load_fpga_bin_aliases(path: str | Path | None = None) -> dict[str, FpgaBinAlias]:
    path = alias_map_path(path)
    with path.open() as fp:
        data = yaml.safe_load(fp) or {}

    aliases = data.get("aliases", data)
    if not isinstance(aliases, dict):
        raise ValueError(f"FPGA bin alias map must contain a mapping: {path}")

    out: dict[str, FpgaBinAlias] = {}
    for name, spec in aliases.items():
        if not isinstance(name, str):
            raise ValueError(f"FPGA bin alias names must be strings: {path}")
        if isinstance(spec, str):
            out[name] = FpgaBinAlias(path=spec)
            continue
        if not isinstance(spec, dict):
            raise ValueError(f"FPGA bin alias {name!r} must be a path string or mapping")
        raw_path = spec.get("path")
        if not isinstance(raw_path, str) or not raw_path:
            raise ValueError(f"FPGA bin alias {name!r} must define a non-empty path")
        out[name] = FpgaBinAlias(
            path=raw_path,
            configs_extra=_configs_from_yaml(spec.get("configs_extra"), alias=name),
        )
    return out


def _replace_xrt_mem_map_config(configs: list[str], mode: str) -> list[str]:
    replacement = f"-DXRT_MEM_MAP={mode}"
    out: list[str] = []
    replaced = False
    for config in configs:
        if config.startswith("-DXRT_MEM_MAP="):
            if not replaced:
                out.append(replacement)
                replaced = True
        else:
            out.append(config)
    if not replaced:
        out.insert(0, replacement)
    return out


def resolve_fpga_bin_config(
    value: str | Path,
    *,
    xrt_mem_map: str | None = None,
    alias_map_path: str | Path | None = None,
    aliases: dict[str, FpgaBinAlias] | None = None,
) -> FpgaBinConfig:
    raw_value = str(value)
    alias_table = aliases if aliases is not None else load_fpga_bin_aliases(alias_map_path)
    alias = alias_table.get(raw_value)
    configs_extra: list[str] = []
    if alias is None:
        resolved = raw_value
    else:
        resolved = alias.path
        configs_extra.extend(alias.configs_extra)

    if xrt_mem_map:
        configs_extra = _replace_xrt_mem_map_config(configs_extra, xrt_mem_map)

    return FpgaBinConfig(
        path=normalize_fpga_bin(Path(resolved)),
        configs_extra=tuple(configs_extra),
    )


def resolve_fpga_bin(value: str | Path) -> Path:
    return resolve_fpga_bin_config(value).path


def list_fpga_bin_aliases(path: str | Path | None = None) -> tuple[str, ...]:
    return tuple(sorted(load_fpga_bin_aliases(path).keys()))
