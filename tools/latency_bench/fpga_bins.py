from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .yaml_io import safe_load


CompileConfigs = tuple[str, ...]
FPGA_BIN_ALIAS_MAP_ENV = "VORTEX_FPGA_BIN_ALIAS_MAP"
DEFAULT_FPGA_BIN_ALIAS_MAP = Path(__file__).resolve().parents[2] / "ci" / "fpga_bin_alias_map.yaml"


@dataclass(frozen=True)
class FpgaBinAlias:
    path: str
    configs: str = ""


@dataclass(frozen=True)
class FpgaBinConfig:
    path: Path
    configs: Path | None = None


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


def _config_path_from_yaml(value: Any, *, alias: str, alias_map: Path) -> str:
    if value is None:
        return ""
    if not isinstance(value, str) or not value:
        raise ValueError(f"configs for FPGA bin alias {alias!r} must be a non-empty path string")

    config_path = Path(value).expanduser()
    if config_path.is_absolute():
        return str(config_path.resolve())

    candidates = (
        alias_map.parent / config_path,
        alias_map.parent.parent / config_path,
    )
    for candidate in candidates:
        if candidate.exists():
            return str(candidate.resolve())
    return str(candidates[0].resolve())


def load_fpga_bin_aliases(path: str | Path | None = None) -> dict[str, FpgaBinAlias]:
    path = alias_map_path(path)
    with path.open() as fp:
        data = safe_load(fp) or {}

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
            configs=_config_path_from_yaml(spec.get("configs"), alias=name, alias_map=path),
        )
    return out


def resolve_fpga_bin_config(
    value: str | Path,
    *,
    alias_map_path: str | Path | None = None,
    aliases: dict[str, FpgaBinAlias] | None = None,
) -> FpgaBinConfig:
    raw_value = str(value)
    alias_table = aliases if aliases is not None else load_fpga_bin_aliases(alias_map_path)
    alias = alias_table.get(raw_value)
    if alias is None:
        resolved = raw_value
        configs: Path | None = None
    else:
        resolved = alias.path
        configs = Path(alias.configs) if alias.configs else None

    return FpgaBinConfig(
        path=normalize_fpga_bin(Path(resolved)),
        configs=configs,
    )


def resolve_fpga_bin(value: str | Path) -> Path:
    return resolve_fpga_bin_config(value).path


def list_fpga_bin_aliases(path: str | Path | None = None) -> tuple[str, ...]:
    return tuple(sorted(load_fpga_bin_aliases(path).keys()))
