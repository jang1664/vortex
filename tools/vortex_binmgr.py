#!/usr/bin/env python3
import argparse
import contextlib
import copy
import ctypes
import datetime as dt
import errno
import fcntl
import getpass
import hashlib
import json
import os
import re
import shutil
import shlex
import socket
import stat
import sys
import tempfile
import uuid
from pathlib import Path


EXCLUDE_DIRS = {"by-hash", "by-tag", "latest"}
DEFAULT_HASH_LEN = 10
RTL_SOURCE_EXTS = {".sv", ".svh", ".v", ".vh", ".vhd", ".vhdl"}
ROUTE_SUBDIRS = {"baseline", "fpint"}


def routing_target_root(root: Path, flag_fpint: bool) -> Path:
    """Resolve the leaf root for a build given the configured root and fpint flag.

    Builds are split into <root>/baseline/ and <root>/fpint/ leaves. If --root
    already names one of those leaves, it is used as-is (no further routing).
    """
    if root.name in ROUTE_SUBDIRS:
        return root
    return root / ("fpint" if flag_fpint else "baseline")


def reserve_target_path(target_root: Path, base_name: str, src: Path, reserved: set[Path]) -> Path:
    """Pick the next available target path using base, then _1, _2, ..."""

    validate_component(base_name)
    if src.parent == target_root and re.fullmatch(re.escape(base_name) + r"(?:_[1-9][0-9]*)?", src.name):
        return src
    suffix: int | None = None
    while True:
        candidate_name = base_name if suffix is None else f"{base_name}_{suffix}"
        candidate = target_root / candidate_name
        if candidate == src:
            return candidate
        if candidate not in reserved and not candidate.exists() and not candidate.is_symlink():
            return candidate
        suffix = 1 if suffix is None else suffix + 1


def read_text(path: Path) -> str | None:
    try:
        return path.read_text()
    except FileNotFoundError:
        return None


def parse_config_stamp(path: Path) -> dict | None:
    text = read_text(path)
    if text is None:
        return None
    text = " ".join(text.split())
    if not text:
        return {}
    # Only match top-level KEY= tokens (avoid -D* inside CONFIGS)
    matches = list(re.finditer(r"(?:(?<=^)|(?<=\s))([A-Z][A-Z0-9_]*)=", text))
    params: dict[str, str] = {}
    for i, match in enumerate(matches):
        key = match.group(1)
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        value = text[start:end].strip()
        params[key] = value
    return params


def parse_defines_from_sources(path: Path) -> list[str]:
    text = read_text(path)
    if text is None:
        return []
    defines: list[str] = []
    for line in text.splitlines():
        if line.startswith("+define+"):
            defines.append(line[len("+define+") :].strip())
    return defines


def collect_rtl_source_paths(sources_text: str, dir_path: Path) -> list[Path]:
    paths: list[Path] = []
    seen: set[str] = set()
    for raw_line in sources_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("+") or line.startswith("-"):
            continue
        path = Path(line)
        if not path.is_absolute():
            path = dir_path / path
        if path.suffix.lower() not in RTL_SOURCE_EXTS:
            continue
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        paths.append(path)
    return paths


def compute_rtl_sources_sha(sources_text: str | None, dir_path: Path) -> tuple[str | None, int, int]:
    if not sources_text:
        return None, 0, 0

    rtl_paths = collect_rtl_source_paths(sources_text, dir_path)
    if not rtl_paths:
        return None, 0, 0

    records: list[str] = []
    missing_or_unreadable = 0
    for path in sorted(rtl_paths, key=lambda p: str(p)):
        try:
            data = path.read_bytes()
        except OSError:
            missing_or_unreadable += 1
            continue
        file_sha = hashlib.sha256(data).hexdigest()
        records.append(f"{path}={file_sha}")

    if not records:
        return None, 0, missing_or_unreadable

    canonical = "\n".join(records)
    if missing_or_unreadable:
        canonical += f"\nmissing_or_unreadable={missing_or_unreadable}"
    rtl_sha = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return rtl_sha, len(records), missing_or_unreadable


def parse_configs_tokens(value: str) -> list[str]:
    return [t for t in value.split() if t]


def has_define(defines: list[str], name: str) -> bool:
    prefix = f"{name}="
    return any(d == name or d.startswith(prefix) for d in defines)


def has_any_define(defines: list[str], names: tuple[str, ...]) -> bool:
    return any(has_define(defines, name) for name in names)


def parse_platform_from_log(path: Path) -> str | None:
    text = read_text(path)
    if text is None:
        return None
    m = re.search(r"/([^/]+)\.xpfm", text)
    if m:
        return m.group(1)
    return None


def link_summary_option(path: Path, option: str) -> str | None:
    text = read_text(path)
    if not text:
        return None
    blocks = re.findall(r"<ENTRY>\s*(.*?)\s*</ENTRY>", text, re.S)
    for block in blocks:
        try:
            record = json.loads(block)
            step = record.get("buildStep", {})
            args = step.get("args")
            if not isinstance(args, list):
                args = shlex.split(step.get("commandLine", ""))
            for i, arg in enumerate(args):
                if arg == option and i + 1 < len(args):
                    return args[i + 1]
                if isinstance(arg, str) and arg.startswith(option + "="):
                    return arg.split("=", 1)[1]
        except (ValueError, AttributeError, TypeError):
            continue
    # Older summaries can contain a plain command line instead of ENTRY JSON.
    if not blocks:
        match = re.search(re.escape(option) + r"(?:\s+|=)(\"[^\"]*\"|'[^']*'|[^\s]+)", text)
        if match:
            return shlex.split(match.group(1))[0]
    return None


def parse_platform_from_link_summary(path: Path) -> str | None:
    return link_summary_option(path, "--platform")


def parse_target_from_link_summary(path: Path) -> str | None:
    return link_summary_option(path, "--target")


def parse_kernel_freq_from_link_summary(path: Path) -> str | None:
    value = link_summary_option(path, "--kernel_frequency")
    if value is None:
        text = read_text(path) or ""
        # The Vitis config may be embedded in an ENTRY's JSON content string.
        match = re.search(r"kernel_frequency\s*=\s*((?:0:)?[0-9]+(?:\.[0-9]+)?)", text)
        value = match.group(1) if match else None
    if value and re.fullmatch(r"(?:0:)?[0-9]+(?:\.[0-9]+)?", value):
        return value.removeprefix("0:")
    return None


def parse_build_time_from_vivado_log(path: Path) -> str | None:
    text = read_text(path)
    if text is None:
        return None
    # Example: "Exiting Vivado at Sat Mar  7 13:06:00 2026..."
    m = re.search(r"Exiting Vivado at ([A-Za-z]{3} [A-Za-z]{3}\s+\d{1,2} \d{2}:\d{2}:\d{2} \d{4})", text)
    if not m:
        return None
    raw = m.group(1)
    try:
        ts = dt.datetime.strptime(raw, "%a %b %d %H:%M:%S %Y")
        return ts.isoformat()
    except ValueError:
        return None


def extract_xilinx_tool_info(text: str, tool_name: str) -> tuple[str | None, str | None, str | None]:
    settings_match = re.search(rf"(/opt/Xilinx/{tool_name}/(\d+\.\d+)/settings64\.sh)", text)
    if settings_match:
        settings64 = settings_match.group(1)
        version = settings_match.group(2)
        home = f"/opt/Xilinx/{tool_name}/{version}"
        return version, home, settings64

    home_match = re.search(rf"(/opt/Xilinx/{tool_name}/(\d+\.\d+))(?=/|\\b)", text)
    if home_match:
        home = home_match.group(1)
        version = home_match.group(2)
        return version, home, f"{home}/settings64.sh"

    return None, None, None


def short_platform(platform: str) -> str:
    if "\\" in platform or any(ord(c) < 32 or ord(c) == 127 for c in platform):
        raise ValueError(f"invalid platform: {platform!r}")
    if ".." in platform.split("/"):
        raise ValueError(f"invalid platform path: {platform!r}")
    platform = Path(platform).name.removesuffix(".xpfm")
    validate_component(platform)
    m = re.match(r"xilinx_([^_]+)", platform)
    if m:
        return m.group(1)
    return platform


def validate_component(value: str) -> None:
    if not value or value in (".", "..") or not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
        raise ValueError(f"unsafe directory name component: {value!r}")


def read_manifest(directory: Path) -> dict | None:
    path = directory / "manifest.json"
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or not isinstance(data.get("id"), dict):
        raise ValueError(f"invalid manifest object: {path}")
    for key in ("params", "sources", "flags", "timestamps", "origin"):
        if key in data and not isinstance(data[key], dict) and not (key == "origin" and data[key] is None):
            raise ValueError(f"invalid manifest {key}: {path}")
    identity = data.get("id", {})
    full, short = identity.get("full", ""), identity.get("short", "")
    if (data.get("schema_version") != 2 or identity.get("alg") != "sha256"
            or not isinstance(full, str) or not re.fullmatch(r"[0-9a-f]{64}", full)
            or not isinstance(short, str) or not re.fullmatch(r"[0-9a-f]{1,64}", short)
            or not full.startswith(short)):
        raise ValueError(f"invalid manifest identity: {path}")
    return data


def normalize_configs(value: str) -> tuple[str, list[str]]:
    tokens = [t for t in value.split() if t]
    tokens_sorted = sorted(tokens)
    return " ".join(tokens_sorted), tokens


def normalize_params(params: dict) -> tuple[dict, dict]:
    params_norm = dict(params)
    extras = {}
    if "CONFIGS" in params_norm:
        norm, tokens = normalize_configs(params_norm["CONFIGS"])
        params_norm["CONFIGS"] = norm
        extras["CONFIGS_TOKENS"] = tokens
    return params_norm, extras


def canonical_kv_lines(params: dict) -> list[str]:
    lines = [f"{k}={params[k]}" for k in params.keys()]
    return sorted(lines)


def compute_hash(lines: list[str], hash_len: int) -> tuple[str, str]:
    canonical = "\n".join(lines)
    sha = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return sha[:hash_len], sha


def detect_build_dir(path: Path) -> bool:
    if not path.is_dir():
        return False
    if path.is_symlink():
        return False
    if path.name in EXCLUDE_DIRS or path.name.startswith("."):
        return False
    if (path / ".config.stamp").exists():
        return True
    if (path / "bin" / "vortex_afu.xclbin").exists():
        return True
    if (path / "v++_vortex_afu.log").exists():
        return True
    return False


def collect_dirs(root: Path) -> list[Path]:
    return [p for p in sorted(root.iterdir()) if detect_build_dir(p)] if root.exists() else []


def scan_dirs(root: Path) -> list[Path]:
    dirs = collect_dirs(root)
    if root.name not in ROUTE_SUBDIRS:
        for name in sorted(ROUTE_SUBDIRS):
            dirs.extend(collect_dirs(root / name))
    return dirs


def compact_dict(obj: dict) -> dict:
    out = {}
    for k, v in obj.items():
        if isinstance(v, dict):
            v = compact_dict(v)
            if not v:
                continue
        if v is None:
            continue
        if isinstance(v, str) and v == "":
            continue
        if isinstance(v, list) and len(v) == 0:
            continue
        out[k] = v
    return out


def build_manifest(entry: dict, now_iso: str) -> dict:
    if entry.get("existing_manifest") is not None:
        manifest = copy.deepcopy(entry["existing_manifest"])
        manifest["name"] = entry["name_final"]
        manifest["resolved_params"] = compact_dict(entry["params_norm"])
        manifest["origin"] = {**(manifest.get("origin") or {}), "original_dir": entry["original_dir_hint"]}
        return manifest
    manifest = {
        "schema_version": 2,
        "name": entry["name_final"],
        "id": {
            "short": entry["build_id"],
            "full": entry["hash_full"],
            "alg": "sha256",
        },
        "flags": {
            "fpint": entry["flag_fpint"],
            "fpnew": entry["flag_fpnew"],
            "ila": entry["flag_ila"],
            "tcu": entry["flag_tcu"],
            "dcache_disable": entry["flag_dcache_disable"],
            "l2cache": entry["flag_l2_enable"],
            "nocache": entry["flag_nocache"],
        },
        "params": entry["params_raw"],
        "resolved_params": entry["params_norm"],
        "sources": {
            "params_source": entry["params_source"],
            "params_incomplete": entry["params_incomplete"],
            "missing_keys": entry["missing_keys"],
            "config_stamp": {
                "path": entry["config_stamp_path"],
                "sha256": entry["config_stamp_sha256"],
            },
            "sources_txt": {
                "path": entry["sources_txt_path"],
                "sha256": entry["sources_txt_sha256"],
            },
            "rtl_sources": {
                "sha256": entry["rtl_sources_sha256"],
                "file_count": entry["rtl_sources_file_count"],
                "missing_or_unreadable_files": entry["rtl_sources_missing_count"],
            },
        },
        "tools": entry["tool_versions"],
        "artifacts": entry["artifacts"],
        "timestamps": {
            "build_time": entry["build_time"],
            "generated_at": now_iso,
        },
        "origin": {
            "original_dir": entry.get("original_dir_hint"),
        },
        "system": {
            "user": entry["user"],
            "host": entry["host"],
        },
        "notes": entry.get("notes", ""),
    }
    return compact_dict(manifest)


def extract_tool_versions(dir_path: Path) -> dict:
    versions = {}
    vivado_log = dir_path / "vivado.log"
    if not vivado_log.exists():
        vivado_log = dir_path / "bin" / "vivado.log"
    text = read_text(vivado_log)
    if text:
        m = re.search(r"Vivado v(\d+\.\d+)", text)
        if m:
            versions["vivado"] = m.group(1)
        vivado_ver, vivado_home, vivado_settings = extract_xilinx_tool_info(text, "Vivado")
        if vivado_ver:
            versions.setdefault("vivado", vivado_ver)
        if vivado_home:
            versions["vivado_home"] = vivado_home
        if vivado_settings:
            versions["vivado_settings64"] = vivado_settings

    vpp_log = dir_path / "v++_vortex_afu.log"
    text = read_text(vpp_log)
    if text:
        m = re.search(r"/Vitis/(\d+\.\d+)/bin", text)
        if m:
            versions["vitis"] = m.group(1)
        vitis_ver, vitis_home, vitis_settings = extract_xilinx_tool_info(text, "Vitis")
        if vitis_ver:
            versions.setdefault("vitis", vitis_ver)
        if vitis_home:
            versions["vitis_home"] = vitis_home
        if vitis_settings:
            versions["vitis_settings64"] = vitis_settings

    return versions


def extract_artifacts(dir_path: Path) -> dict:
    artifacts = {}
    candidates = {
        "xclbin": dir_path / "bin" / "vortex_afu.xclbin",
        "xclbin_info": dir_path / "bin" / "vortex_afu.xclbin.info",
        "xclbin_link_summary": dir_path / "bin" / "vortex_afu.xclbin.link_summary",
        "xo": dir_path / "bin" / "vortex_afu.xo",
        "ltx": dir_path / "bin" / "vortex_afu.ltx",
        "xsa": dir_path / "bin" / "xsa.xml",
        "emconfig": dir_path / "bin" / "emconfig.json",
    }
    for key, path in candidates.items():
        if path.exists():
            artifacts[key] = str(path.relative_to(dir_path))
    return artifacts


def load_params(dir_path: Path, original_name: str | None) -> tuple[dict, dict, dict]:
    params_source = "sources_txt"
    params_incomplete = False
    missing_keys: list[str] = []
    params = {}
    extras = {}

    sources_path = dir_path / "sources.txt"
    if not sources_path.exists():
        alt_sources_path = dir_path / "sources.tx"
        if alt_sources_path.exists():
            sources_path = alt_sources_path
    sources_text = read_text(sources_path) if sources_path.exists() else None
    sources_text_lc = sources_text.lower() if sources_text else ""
    defines = parse_defines_from_sources(sources_path)

    config_path = dir_path / ".config.stamp"
    config_params = parse_config_stamp(config_path)
    config_sha = None
    if config_params is not None:
        params_source = "config_stamp"
        params = config_params
        if config_path.exists():
            text = read_text(config_path)
            if text is not None:
                config_sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    if not params.get("CONFIGS", "").strip() and defines:
        params["CONFIGS"] = " ".join(f"-D{d}" for d in sorted(defines))

    link_summary = dir_path / "bin" / "vortex_afu.xclbin.link_summary"
    platform = parse_platform_from_link_summary(link_summary) or parse_platform_from_log(dir_path / "v++_vortex_afu.log")
    if platform and not params.get("PLATFORM", "").strip():
        params["PLATFORM"] = platform

    target = parse_target_from_link_summary(link_summary)
    if target and not params.get("TARGET", "").strip():
        params["TARGET"] = target

    freq = parse_kernel_freq_from_link_summary(link_summary)
    if freq and not params.get("CLOCK_FREQ_HZ", "").strip():
        params["CLOCK_FREQ_HZ"] = freq

    # Fallback from dir name (works for both old and hashed names)
    name = original_name or dir_path.name
    m = re.search(r"(xilinx_[A-Za-z0-9_]+)", name)
    if m and not params.get("PLATFORM", "").strip():
        params["PLATFORM"] = m.group(1)
    core_candidates = [params.get("NUM_CORES", "").strip()]
    core_candidates += re.findall(r"(?:^|\s)-DNUM_CORES=([^\s]+)", params.get("CONFIGS", ""))
    core_candidates += [d.split("=", 1)[1] for d in defines if d.startswith("NUM_CORES=")]
    core_candidates = [c for c in core_candidates if c]
    if len(set(core_candidates)) > 1:
        raise ValueError(f"conflicting NUM_CORES in {dir_path}: {core_candidates}")
    if core_candidates:
        params["NUM_CORES"] = core_candidates[0]
    m = re.search(r"(?:^|_)core(\d+)", name)
    if m and not params.get("NUM_CORES", "").strip():
        params["NUM_CORES"] = m.group(1)
    m = re.search(r"(?:^|_)c(\d+)", name)
    if m and not params.get("NUM_CORES", "").strip():
        params["NUM_CORES"] = m.group(1)
    m = re.search(r"(?:^|_)f(\d+)", name)
    if m and not params.get("CLOCK_FREQ_HZ", "").strip():
        params["CLOCK_FREQ_HZ"] = m.group(1)

    if not params.get("TARGET", "").strip():
        params["TARGET"] = "hw"
    required = ["CONFIGS", "PLATFORM", "CLOCK_FREQ_HZ", "NUM_CORES"]
    missing_keys = [k for k in required if not params.get(k, "").strip()]
    if missing_keys:
        params_incomplete = True

    params_norm, extras = normalize_params(params)
    sources_sha = None
    if sources_text is not None:
        sources_sha = hashlib.sha256(sources_text.encode("utf-8")).hexdigest()
    rtl_sources_sha, rtl_sources_file_count, rtl_sources_missing_count = compute_rtl_sources_sha(sources_text, dir_path)

    configs_tokens = parse_configs_tokens(params.get("CONFIGS", ""))
    configs_defines = [t[2:] if t.startswith("-D") else t for t in configs_tokens]

    return params, params_norm, {
        "params_source": params_source,
        "params_incomplete": params_incomplete,
        "missing_keys": missing_keys,
        "extras": extras,
        "config_path": config_path if config_path.exists() else None,
        "config_sha": config_sha,
        "sources_path": sources_path if sources_path.exists() else None,
        "sources_sha": sources_sha,
        "rtl_sources_sha": rtl_sources_sha,
        "rtl_sources_file_count": rtl_sources_file_count,
        "rtl_sources_missing_count": rtl_sources_missing_count,
        "sources_defines": sorted(defines),
        "configs_defines": configs_defines,
        "sources_has_fpint": "fpint" in sources_text_lc,
        "sources_has_ila": "ila" in sources_text_lc,
    }


def plan_entries(dirs: list[Path], hash_len: int) -> list[dict]:
    if not 1 <= hash_len <= 64:
        raise ValueError("--hash-len must be between 1 and 64")
    entries: list[dict] = []
    now_iso = dt.datetime.now().isoformat()
    for d in dirs:
        original_name = None
        existing = read_manifest(d)
        if existing:
            origin = existing.get("origin") or {}
            original_name = origin.get("original_dir") or existing.get("original_dir") or existing.get("original_dir_hint")

        params_raw, params_norm, meta = load_params(d, original_name)
        lines = canonical_kv_lines(params_norm)
        build_id, hash_full = compute_hash(lines, hash_len)
        if existing:
            build_id, hash_full = existing["id"]["short"], existing["id"]["full"]
        target = params_norm.get("TARGET", "hw")
        platform = params_norm.get("PLATFORM", "unknown")
        plat_short = short_platform(platform)
        cores = params_norm.get("NUM_CORES", "na")
        freq = params_norm.get("CLOCK_FREQ_HZ", "na")
        errors = []
        if target not in ("hw", "hw_emu", "sw_emu"):
            errors.append(f"invalid TARGET={target!r}")
        if not re.fullmatch(r"[1-9][0-9]*", cores):
            errors.append(f"invalid NUM_CORES={cores!r}")
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", freq) or float(freq) <= 0:
            errors.append(f"invalid CLOCK_FREQ_HZ={freq!r}")
        if meta["missing_keys"]:
            errors.append("missing " + ",".join(meta["missing_keys"]))
        name_base = f"xrt_{target}_{plat_short}_c{cores}_f{freq}"
        original_hint = original_name or d.name
        fpint_flag = "fpint" in original_hint.lower() or meta["sources_has_fpint"]
        if existing:
            fpint_flag = existing.get("flags", {}).get("fpint", fpint_flag)
        sources_defines = meta["sources_defines"]
        configs_defines = meta["configs_defines"]
        fpnew_flag = has_define(sources_defines, "FPU_FPNEW") or has_define(configs_defines, "FPU_FPNEW")
        ila_flag = has_define(sources_defines, "CHIPSCOPE") or has_define(configs_defines, "CHIPSCOPE")
        tcu_flag = has_define(sources_defines, "EXT_TCU_ENABLE") or has_define(configs_defines, "EXT_TCU_ENABLE")
        dcache_disable_flag = has_define(sources_defines, "DCACHE_DISABLE") or has_define(configs_defines, "DCACHE_DISABLE")
        l2_enable_flag = has_define(sources_defines, "L2_ENABLE") or has_define(configs_defines, "L2_ENABLE")
        nocache_flag = has_any_define(sources_defines, ("L1_DISABLE", "DL1_DISABLE")) or has_any_define(
            configs_defines, ("L1_DISABLE", "DL1_DISABLE")
        )

        if fpint_flag:
            name_base += "_fpint"
        if tcu_flag:
            name_base += "_tcu"
        if dcache_disable_flag:
            name_base += "_noDcache"
        if l2_enable_flag:
            name_base += "_L2cache"
        if nocache_flag:
            name_base += "_nocache"
        name_base += f"_{build_id}"

        build_time = parse_build_time_from_vivado_log(d / "vivado.log") or parse_build_time_from_vivado_log(d / "bin" / "vivado.log")

        entry = {
            "existing_manifest": existing,
            "validation_errors": errors,
            "dir_path": d,
            "dir_name": d.name,
            "name_base": name_base,
            "name_final": name_base,  # may be adjusted for collisions
            "build_id": build_id,
            "hash_full": hash_full,
            "hash_len": hash_len,
            "canonical_params": lines,
            "params_raw": params_raw,
            "params_norm": params_norm,
            "params_source": meta["params_source"],
            "params_incomplete": meta["params_incomplete"],
            "missing_keys": meta["missing_keys"],
            "config_stamp_path": ".config.stamp" if meta["config_path"] else None,
            "config_stamp_sha256": meta["config_sha"],
            "sources_txt_path": meta["sources_path"].name if meta["sources_path"] else None,
            "sources_txt_sha256": meta["sources_sha"],
            "rtl_sources_sha256": meta["rtl_sources_sha"],
            "rtl_sources_file_count": meta["rtl_sources_file_count"],
            "rtl_sources_missing_count": meta["rtl_sources_missing_count"],
            "sources_defines": meta["sources_defines"],
            "original_dir_hint": original_hint,
            "flag_fpint": fpint_flag,
            "flag_fpnew": fpnew_flag,
            "flag_ila": ila_flag,
            "flag_tcu": tcu_flag,
            "flag_dcache_disable": dcache_disable_flag,
            "flag_l2_enable": l2_enable_flag,
            "flag_nocache": nocache_flag,
            "tool_versions": extract_tool_versions(d),
            "artifacts": extract_artifacts(d),
            "build_time": build_time,
            "generated_at": now_iso,
            "user": getpass.getuser(),
            "host": socket.gethostname(),
        }
        entries.append(entry)

    # Handle name collisions
    used = {}
    for entry in entries:
        base = entry["name_base"]
        if base not in used:
            used[base] = [entry]
        else:
            used[base].append(entry)

    for base, group in used.items():
        if len(group) <= 1:
            continue
        # Stable order by original dir name
        group_sorted = sorted(group, key=lambda e: e["dir_name"])
        for idx, e in enumerate(group_sorted[1:], start=1):
            e["name_final"] = f"{base}_{idx}"
            e["collision_suffix"] = idx
            e["duplicate_of"] = group_sorted[0]["name_base"]

    return entries


def plan_actions(root: Path, entries: list[dict]) -> dict:
    reserved_by_root: dict[Path, set[Path]] = {}
    grouped_entries: dict[tuple[Path, str], list[dict]] = {}

    for e in entries:
        target_root = routing_target_root(root, e["flag_fpint"])
        e["target_root"] = target_root
        grouped_entries.setdefault((target_root, e["name_base"]), []).append(e)

    for (target_root, base_name), group in grouped_entries.items():
        reserved = reserved_by_root.setdefault(target_root, set())
        for e in sorted(group, key=lambda item: item["dir_name"]):
            src = e["dir_path"]
            canonical = reserve_target_path(target_root, base_name, src, reserved)
            reserved.add(canonical)
            e["name_final"] = canonical.name
            e["canonical_path"] = canonical

    renames = []
    symlinks = []
    manifests = []
    for e in entries:
        src = e["dir_path"]
        target_root = e["target_root"]
        canonical = e["canonical_path"]
        if canonical.parent != target_root or canonical.parent.resolve() != target_root.resolve():
            raise ValueError(f"destination must be a direct child of {target_root}: {canonical}")
        manifest_path = canonical / "manifest.json"

        if src == canonical:
            # Already at canonical location with canonical name.
            pass
        elif src.parent == target_root:
            # Keep callers of the old archive name working after a repair.
            renames.append((src, canonical))
            symlinks.append((src, canonical))
        else:
            # Source is elsewhere (external --dir, or under a different leaf):
            # move into the target leaf and leave a symlink at the original.
            renames.append((src, canonical))
            symlinks.append((src, canonical))

        manifests.append((manifest_path, e))

    return {
        "renames": renames,
        "symlinks": symlinks,
        "manifests": manifests,
    }


def print_plan(root: Path, entries: list[dict], actions: dict) -> None:
    print(f"root: {root}")
    print(f"builds: {len(entries)}")
    if actions["renames"]:
        print("renames (move into target leaf):")
        for src, dst in actions["renames"]:
            if src.parent == dst.parent:
                print(f"  {src.parent}/{src.name} -> {dst.name}")
            else:
                print(f"  {src} -> {dst}")
    else:
        print("renames: none")
    if actions.get("symlinks"):
        print("symlinks (original -> canonical):")
        for link_path, target in actions["symlinks"]:
            print(f"  {link_path} -> {target}")
    print("manifests:")
    for manifest_path, _ in actions["manifests"]:
        print(f"  {manifest_path}")
    target_roots = sorted({e["target_root"] for e in entries}, key=str)
    if root.name in ROUTE_SUBDIRS and root not in target_roots:
        target_roots.append(root)
    if target_roots:
        print("indices (per leaf):")
        for tr in target_roots:
            print(f"  {tr}/hashes.json + by-hash/ + latest")
    else:
        print("indices: (no targets)")
    warn = [e for e in entries if e["params_incomplete"]]
    if warn:
        print("warnings:")
        for e in warn:
            if e["missing_keys"]:
                print(f"  {e['dir_name']}: missing {','.join(e['missing_keys'])}")
            else:
                print(f"  {e['dir_name']}: fallback params (no .config.stamp)")
    for e in entries:
        for error in e.get("validation_errors", []):
            print(f"ERROR: {e['dir_path']}: {error}")


def atomic_bytes(path: Path, data: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix=".vortex_binmgr_write_", dir=path.parent)
    tmp = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        tmp.chmod(stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644)
        os.replace(tmp, path)
        sync_dir(path.parent)
    finally:
        tmp.unlink(missing_ok=True)


def atomic_json(path: Path, data: dict) -> None:
    atomic_bytes(path, (json.dumps(data, indent=2, sort_keys=True) + "\n").encode())


def sync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def replace_symlink(path: Path, link_text: str) -> None:
    if path.exists() and not path.is_symlink():
        raise RuntimeError(f"refusing to replace a real entry with a link: {path}")
    temporary = path.parent / (".vortex_binmgr_link_" + uuid.uuid4().hex)
    try:
        temporary.symlink_to(link_text)
        os.replace(temporary, path)
        sync_dir(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_link(path: Path, target: Path) -> None:
    replace_symlink(path, os.path.relpath(target, path.parent))


@contextlib.contextmanager
def archive_locks(root: Path):
    leaves = [root] if root.name in ROUTE_SUBDIRS else [root, *(root / n for n in ROUTE_SUBDIRS)]
    with contextlib.ExitStack() as stack:
        for leaf in sorted(leaves):
            if leaf.is_symlink():
                raise RuntimeError(f"archive leaf must not be a symlink: {leaf}")
            leaf.mkdir(parents=True, exist_ok=True)
            fd = os.open(leaf / ".vortex_binmgr.lock", os.O_CREAT | os.O_RDONLY | os.O_NOFOLLOW, 0o666)
            stream = stack.enter_context(os.fdopen(fd, "r"))
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise RuntimeError(f"archive lock is not a regular file: {leaf}")
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise RuntimeError(f"another --apply is using {leaf}") from exc
        yield leaves


def file_identity(path: Path) -> list[int]:
    info = path.stat()
    return [info.st_dev, info.st_ino]


def same_identity(path: Path, identity: list[int]) -> bool:
    return not path.is_symlink() and path.exists() and file_identity(path) == identity


def rename_noreplace(src: Path, dst: Path) -> None:
    """Linux rename with atomic destination exclusion, including empty directories."""
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise OSError(errno.ENOSYS, "atomic no-replace rename is unavailable")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(-100, os.fsencode(src), -100, os.fsencode(dst), 1) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), str(dst))


def tree_inventory(root: Path) -> dict:
    """Hash regular files in bounded memory; never follow directory symlinks."""
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            info = path.lstat()
            key = str(path.relative_to(root))
            if stat.S_ISLNK(info.st_mode):
                result[key] = ["link", os.readlink(path)]
            elif stat.S_ISDIR(info.st_mode):
                result[key] = ["dir"]
            elif stat.S_ISREG(info.st_mode):
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                result[key] = ["file", info.st_size, digest.hexdigest()]
            else:
                raise RuntimeError(f"unsupported special file: {path}")
    return result


def journal_write(path: Path, record: dict, state: str) -> None:
    atomic_json(path, {**record, "state": state})
    record["state"] = state


def restore_links(record: dict) -> None:
    dst = Path(record["dst"])
    for name, old in record["links"].items():
        path = Path(name)
        if path.is_symlink():
            if os.readlink(path) == old:
                continue
            if path.resolve() != dst:
                raise RuntimeError(f"link changed externally; preserved: {path}")
            if old is None:
                path.unlink()
            else:
                # Preserve the original literal relative/absolute link target.
                replace_symlink(path, old)
        elif old is not None:
            raise RuntimeError(f"original symlink missing or replaced: {path}")


def rollback_move(record: dict) -> None:
    src, dst = Path(record["src"]), Path(record["dst"])
    backup, stage = Path(record["backup"]), Path(record["stage"])
    expected = record.get("copy_identity") or record["source_identity"]
    # Refuse ambiguous external changes before restoring aliases or data.
    if dst != src and dst.exists() and not same_identity(dst, expected):
        raise RuntimeError(f"destination changed externally; preserved: {dst}")
    if backup.exists() and not same_identity(backup, record["source_identity"]):
        raise RuntimeError(f"source backup changed externally; preserved: {backup}")
    if src != dst and src.exists() and not src.is_symlink() and not same_identity(src, record["source_identity"]):
        raise RuntimeError(f"source changed externally; preserved: {src}")
    restore_links(record)
    if backup.exists():
        if src.exists() or src.is_symlink():
            raise RuntimeError(f"cannot restore backup over {src}; backup retained at {backup}")
        rename_noreplace(backup, src)
        if dst.exists():
            if stage.exists():
                raise RuntimeError(f"copy staging path occupied: {stage}")
            rename_noreplace(dst, stage)
    elif src != dst and same_identity(dst, record["source_identity"]):
        if src.exists() or src.is_symlink():
            raise RuntimeError(f"cannot restore destination over {src}")
        rename_noreplace(dst, src)
    if not same_identity(src, record["source_identity"]):
        raise RuntimeError(f"original source not located; inspect {src}, {backup}, {dst}")
    manifest = src / "manifest.json"
    old = record["old_manifest"]
    if old is not None:
        atomic_bytes(manifest, old.encode())
    elif manifest.exists():
        manifest.unlink()
    sync_dir(src.parent)
    if stage.exists():
        print(f"RECOVERY COPY RETAINED: {stage}", flush=True)
    print(f"RESTORED: {src}", flush=True)


def finish_committed(record: dict) -> None:
    dst, backup = Path(record["dst"]), Path(record["backup"])
    expected = record.get("copy_identity") or record["source_identity"]
    if not same_identity(dst, expected):
        raise RuntimeError(f"committed destination changed or missing: {dst}")
    manifest = read_manifest(dst)
    if manifest is None or manifest["id"]["full"] != record["build_id"]:
        raise RuntimeError(f"committed manifest changed or missing: {dst}")
    for name in record["links"]:
        link = Path(name)
        if not link.is_symlink() or link.resolve() != dst:
            raise RuntimeError(f"committed link changed: {link}")
    if backup.exists():
        if not same_identity(backup, record["source_identity"]):
            raise RuntimeError(f"backup identity changed; preserved: {backup}")
        # This is the original half of a verified cross-filesystem move. Never
        # retire it before destination, manifest and source aliases commit.
        shutil.rmtree(backup)
        sync_dir(backup.parent)


def recover_journals(leaves: list[Path], hash_len: int) -> None:
    for leaf in sorted(leaves):
        for journal in sorted(leaf.glob(".vortex_binmgr_journal_*.json")):
            if journal.is_symlink():
                raise RuntimeError(f"recovery journal must not be a symlink: {journal}")
            record = json.loads(journal.read_text())
            if not isinstance(record, dict):
                raise RuntimeError(f"invalid recovery journal object: {journal}")
            paths = ("src", "dst", "stage", "backup")
            identity = record.get("source_identity")
            if (any(not isinstance(record.get(k), str) or not Path(record[k]).is_absolute()
                    or ".." in Path(record[k]).parts for k in paths)
                    or not isinstance(identity, list) or len(identity) != 2
                    or any(not isinstance(n, int) or n < 0 for n in identity)
                    or not isinstance(record.get("links"), dict)
                    or any(not Path(p).is_absolute() or (v is not None and not isinstance(v, str))
                           for p, v in record.get("links", {}).items())
                    or "old_manifest" not in record
                    or (record["old_manifest"] is not None and not isinstance(record["old_manifest"], str))
                    or not re.fullmatch(r"[0-9a-f]{64}", str(record.get("build_id", "")))):
                raise RuntimeError(f"invalid recovery journal fields: {journal}")
            token = journal.name.removeprefix(".vortex_binmgr_journal_").removesuffix(".json")
            src, dst = Path(record["src"]), Path(record["dst"])
            if (not re.fullmatch(r"[0-9a-f]{32}", token) or dst.parent != leaf
                    or record.get("state") not in {"prepared", "moving", "copying", "copy_verified", "source_staged", "published", "committed"}
                    or Path(record["stage"]) != leaf / (".vortex_binmgr_copy_" + token)
                    or Path(record["backup"]) != src.parent / (".vortex_binmgr_backup_" + token)):
                raise RuntimeError(f"invalid recovery journal; preserved: {journal}")
            print(f"RECOVERING: {journal} state={record['state']}", flush=True)
            if record["state"] == "committed":
                finish_committed(record)
            else:
                rollback_move(record)
            update_root_index(leaf, hash_len)
            journal.unlink()
            sync_dir(leaf)


def preflight(entries: list[dict], actions: dict) -> None:
    errors = []
    sources = [e["dir_path"] for e in entries]
    for e in entries:
        src, dst, leaf = e["dir_path"], e["canonical_path"], e["target_root"]
        errors.extend(f"{src}: {message}" for message in e.get("validation_errors", []))
        if not src.is_dir() or src.is_symlink():
            errors.append(f"source is not a real build directory: {src}")
        if dst.parent != leaf or leaf.is_symlink():
            errors.append(f"destination must be a direct child of a real archive leaf: {dst}")
        if src != dst and (src in dst.parents or dst in src.parents):
            errors.append(f"source and destination overlap: {src} -> {dst}")
        if src != dst and (dst.exists() or dst.is_symlink()):
            errors.append(f"destination already exists: {dst}")
        for directory in (src, src.parent, leaf):
            existing = directory
            while not existing.exists():
                existing = existing.parent
            if not os.access(existing, os.W_OK | os.X_OK):
                errors.append(f"directory is not writable/searchable: {existing}")
        for child in (src / "manifest.json", leaf / "hashes.json", leaf / "by-hash", leaf / "latest"):
            if child.name != "latest" and child.is_symlink():
                errors.append(f"metadata location must not be a symlink: {child}")
            if child.exists() and child.name in ("manifest.json", "hashes.json") and not child.is_file():
                errors.append(f"metadata location must be a regular file: {child}")
            if child.exists() and child.name == "by-hash" and not child.is_dir():
                errors.append(f"by-hash must be a directory: {child}")
        if (leaf / "latest").exists() and not (leaf / "latest").is_symlink():
            errors.append(f"latest is not a managed link: {leaf / 'latest'}")
        for other in sources:
            if src != other and src in other.parents:
                errors.append(f"overlapping input directories: {src}, {other}")
    source_by_destination = {e["canonical_path"]: e["dir_path"] for e in entries}
    for link, target in actions.get("symlinks", []):
        if link.exists() and not link.is_symlink() and link not in sources:
            errors.append(f"cannot replace real entry with alias: {link}")
        if link.is_symlink() and link.resolve() != source_by_destination[target]:
            errors.append(f"input alias changed before apply: {link}")
        if not os.access(link.parent, os.W_OK | os.X_OK):
            errors.append(f"alias parent not writable: {link.parent}")
    if errors:
        raise RuntimeError("preflight failed before moving builds:\n  " + "\n  ".join(errors))


def apply_actions(root: Path, entries: list[dict], actions: dict, force: bool) -> dict:
    preflight(entries, actions)
    result = {"moved": 0, "unchanged": 0, "journals": []}
    for e in entries:
        src, dst, leaf = e["dir_path"], e["canonical_path"], e["target_root"]
        token = uuid.uuid4().hex
        journal = leaf / (".vortex_binmgr_journal_" + token)
        journal = journal.with_suffix(".json")
        links = {str(link): os.readlink(link) if link.is_symlink() else None
                 for link, target in actions.get("symlinks", []) if target == dst and link != dst}
        if src != dst:
            links.setdefault(str(src), None)
        record = dict(src=str(src), dst=str(dst),
                      stage=str(leaf / (".vortex_binmgr_copy_" + token)),
                      backup=str(src.parent / (".vortex_binmgr_backup_" + token)),
                      source_identity=file_identity(src), links=links,
                      old_manifest=read_text(src / "manifest.json"), build_id=e["hash_full"])
        journal_write(journal, record, "prepared")
        try:
            if src != dst:
                print(f"MOVING: {src} -> {dst}", flush=True)
                journal_write(journal, record, "moving")
                try:
                    rename_noreplace(src, dst)
                except OSError as exc:
                    if exc.errno != errno.EXDEV:
                        raise
                    stage, backup = Path(record["stage"]), Path(record["backup"])
                    journal_write(journal, record, "copying")
                    before = tree_inventory(src)
                    shutil.copytree(src, stage, symlinks=True)
                    if before != tree_inventory(stage) or before != tree_inventory(src):
                        raise RuntimeError(f"cross-filesystem copy verification failed: {src} -> {stage}")
                    record["copy_identity"] = file_identity(stage)
                    journal_write(journal, record, "copy_verified")
                    rename_noreplace(src, backup)
                    journal_write(journal, record, "source_staged")
                    rename_noreplace(stage, dst)
            journal_write(journal, record, "published")
            manifest = build_manifest(e, dt.datetime.now().isoformat())
            old = e.get("existing_manifest")
            if force or old != manifest:
                atomic_json(dst / "manifest.json", manifest)
            for name in links:
                link = Path(name)
                if link.is_symlink() and os.readlink(link) != links[name]:
                    raise RuntimeError(f"alias changed during move: {link}")
                if links[name] is not None and not link.is_symlink():
                    raise RuntimeError(f"alias disappeared during move: {link}")
                atomic_link(Path(name), dst)
            journal_write(journal, record, "committed")
            e["dir_path"] = dst
            result["journals"].append(journal)
            result["moved" if src != dst else "unchanged"] += 1
            print(f"MOVED: {src} -> {dst}" if src != dst else f"UNCHANGED: {dst}", flush=True)
            for name in links:
                print(f"SYMLINK: {name} -> {dst}", flush=True)
            print(f"MANIFEST: {dst / 'manifest.json'}", flush=True)
            finish_committed(record)
        except Exception as exc:
            phase = record["state"]
            try:
                if phase != "committed":
                    rollback_move(record)
                    journal.unlink()
            except Exception as recovery_error:
                print(f"ERROR: recovery incomplete: {recovery_error}; journal={journal}", file=sys.stderr, flush=True)
            print(f"PARTIAL: moved={result['moved']} unchanged={result['unchanged']} failed=1", file=sys.stderr, flush=True)
            raise RuntimeError(f"phase={phase}: {exc}; source={src}; destination={dst}; journal={journal}") from exc
    return result


def update_root_index(root: Path, hash_len: int) -> None:
    """Index actual locations using archived identities, not new naming rules."""
    if not root.exists():
        return
    entries = []
    for directory in collect_dirs(root):
        manifest = read_manifest(directory)
        if manifest is None:
            entry = plan_entries([directory], hash_len)[0]
            build_id = entry["build_id"]
            source = entry["params_source"]
            incomplete = entry["params_incomplete"]
            build_time = entry["build_time"]
        else:
            build_id = manifest["id"]["short"]
            source = manifest.get("sources", {}).get("params_source", "manifest")
            incomplete = manifest.get("sources", {}).get("params_incomplete", False)
            build_time = manifest.get("timestamps", {}).get("build_time")
        entries.append(dict(build_id=build_id, name=directory.name, path=str(directory),
                            manifest=str(directory / "manifest.json"), params_source=source,
                            params_incomplete=incomplete, build_time=build_time))
    by_hash = root / "by-hash"
    if by_hash.is_symlink():
        raise RuntimeError(f"by-hash must be a real directory: {by_hash}")
    by_hash.mkdir(exist_ok=True)
    desired = {}
    for entry in entries:
        existing = sorted(link for link in by_hash.iterdir()
                          if link.is_symlink() and link.resolve() == Path(entry["path"])
                          and re.fullmatch(re.escape(entry["build_id"]) + r"(?:_[1-9][0-9]*)?", link.name))
        if existing:
            desired[existing[0].name] = Path(entry["path"])
    for entry in entries:
        target = Path(entry["path"])
        if target in desired.values():
            continue
        name = entry["build_id"]
        suffix = 0
        # A live legacy link may point to a directory no longer recognizable as
        # a build. Keep that compatibility alias and reserve a fresh suffix.
        while name in desired or (by_hash / name).exists():
            suffix += 1
            name = f"{entry['build_id']}_{suffix}"
        desired[name] = target
    for name, target in desired.items():
        atomic_link(by_hash / name, target)
    index_entries = [{k: v for k, v in e.items() if k != "build_time"} for e in entries]
    atomic_json(root / "hashes.json", dict(generated_at=dt.datetime.now().isoformat(),
                                         hash_len=hash_len, entries=index_entries))
    if entries:
        def build_sort_key(entry):
            try:
                return dt.datetime.fromisoformat(entry["build_time"]).timestamp()
            except (TypeError, ValueError):
                return Path(entry["path"]).stat().st_mtime
        latest = max(entries, key=build_sort_key)
        atomic_link(root / "latest", Path(latest["path"]))
    elif (root / "latest").is_symlink():
        (root / "latest").unlink()
    for link in by_hash.iterdir():
        if (link.is_symlink() and not link.exists()
                and re.fullmatch(r"[0-9a-f]{1,64}(?:_[1-9][0-9]*)?", link.name)
                and link.name not in desired):
            link.unlink()
    print(f"INDEX UPDATED: {root}", flush=True)


def run(args) -> int:
    root = args.root.resolve()
    if args.apply:
        with archive_locks(root) as leaves:
            recover_journals(leaves, args.hash_len)
            return process(args, root)
    return process(args, root)


def process(args, root: Path) -> int:
    aliases = {}
    if args.dir:
        dirs = []
        for value in args.dir:
            original = Path(os.path.abspath(value))
            resolved = original.resolve()
            if not detect_build_dir(resolved):
                raise ValueError(f"not a build directory: {original} -> {resolved}")
            aliases.setdefault(resolved, []).append(original)
            if resolved not in dirs:
                dirs.append(resolved)
    else:
        dirs = scan_dirs(root)
    entries = plan_entries(dirs, args.hash_len)
    for entry in entries:
        inputs = aliases.get(entry["dir_path"], [])
        origin = (entry.get("existing_manifest") or {}).get("origin") or {}
        if inputs and not origin.get("original_dir"):
            entry["original_dir_hint"] = inputs[0].name
    actions = plan_actions(root, entries)
    for entry in entries:
        for alias in aliases.get(entry["dir_path"], []):
            pair = (alias, entry["canonical_path"])
            if alias != entry["canonical_path"] and pair not in actions["symlinks"]:
                actions["symlinks"].append(pair)
    if not args.apply:
        print_plan(root, entries, actions)
        return 1 if any(e["validation_errors"] for e in entries) else 0
    result = apply_actions(root, entries, actions, args.force)
    targets = {e["target_root"] for e in entries}
    if root.name in ROUTE_SUBDIRS:
        targets.add(root)
    try:
        for leaf in sorted(targets):
            update_root_index(leaf, args.hash_len)
        for journal in result["journals"]:
            journal.unlink()
            sync_dir(journal.parent)
    except Exception as exc:
        raise RuntimeError(f"index finalization failed after moved={result['moved']} unchanged={result['unchanged']}; committed journals retained for retry: {exc}") from exc
    print(f"DONE: moved={result['moved']} unchanged={result['unchanged']} failed=0", flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Manage vortex FPGA build bins", epilog=(
        "Without --apply, print the plan without changing files. Apply prints absolute "
        "MOVED/UNCHANGED destinations and link/index results. Failed transactions retain "
        "a recovery journal when needed; rerun with the same --root to recover. Existing "
        "manifest IDs are preserved. See tools/vortex_binmgr.md for recovery details."))
    ap.add_argument("--root", type=Path, default=Path("/opt/vortex_fpga_bins"))
    ap.add_argument(
        "--dir",
        type=Path,
        action="append",
        default=[],
        metavar="DIR",
        help="specific build dir to process (repeatable). "
             "If omitted, scan --root and its baseline/fpint leaves (no recursive build scan). "
             "When used, the directory is moved into --root with the canonical "
             "name and a symlink is left at the original location.",
    )
    ap.add_argument("--hash-len", type=int, default=DEFAULT_HASH_LEN)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--force", action="store_true", help="rewrite metadata while preserving existing identity; never overwrite build directories")
    args = ap.parse_args()

    if not 1 <= args.hash_len <= 64:
        ap.error("--hash-len must be between 1 and 64")
    try:
        return run(args)
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
