#!/usr/bin/env python3
import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
import re
import socket
from pathlib import Path


EXCLUDE_DIRS = {"by-hash", "by-tag", "latest"}
DEFAULT_HASH_LEN = 10
RTL_SOURCE_EXTS = {".sv", ".svh", ".v", ".vh", ".vhd", ".vhdl"}


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


def parse_platform_from_link_summary(path: Path) -> str | None:
    text = read_text(path)
    if text is None:
        return None
    m = re.search(r"--platform\s+([A-Za-z0-9_]+)", text)
    if m:
        return m.group(1)
    return None


def parse_target_from_link_summary(path: Path) -> str | None:
    text = read_text(path)
    if text is None:
        return None
    m = re.search(r"--target\s+([A-Za-z0-9_]+)", text)
    if m:
        return m.group(1)
    return None


def parse_kernel_freq_from_link_summary(path: Path) -> str | None:
    text = read_text(path)
    if text is None:
        return None
    m = re.search(r"--kernel_frequency\s+(\d+)", text)
    if m:
        return m.group(1)
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
    m = re.match(r"xilinx_([^_]+)", platform)
    if m:
        return m.group(1)
    return platform


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
    if path.name in EXCLUDE_DIRS:
        return False
    if (path / ".config.stamp").exists():
        return True
    if (path / "bin" / "vortex_afu.xclbin").exists():
        return True
    if (path / "v++_vortex_afu.log").exists():
        return True
    return False


def collect_dirs(root: Path) -> list[Path]:
    return [p for p in sorted(root.iterdir()) if detect_build_dir(p)]


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
    else:
        if defines:
            params["CONFIGS"] = " ".join(f"-D{d}" for d in sorted(defines))

    link_summary = dir_path / "bin" / "vortex_afu.xclbin.link_summary"
    platform = parse_platform_from_link_summary(link_summary) or parse_platform_from_log(dir_path / "v++_vortex_afu.log")
    if platform and "PLATFORM" not in params:
        params["PLATFORM"] = platform

    target = parse_target_from_link_summary(link_summary)
    if target and "TARGET" not in params:
        params["TARGET"] = target

    freq = parse_kernel_freq_from_link_summary(link_summary)
    if freq and "CLOCK_FREQ_HZ" not in params:
        params["CLOCK_FREQ_HZ"] = freq

    # Fallback from dir name (works for both old and hashed names)
    name = original_name or dir_path.name
    m = re.search(r"(xilinx_[A-Za-z0-9_]+)", name)
    if m and "PLATFORM" not in params:
        params["PLATFORM"] = m.group(1)
    m = re.search(r"(?:^|_)core(\d+)", name)
    if m and "NUM_CORES" not in params:
        params["NUM_CORES"] = m.group(1)
    m = re.search(r"(?:^|_)c(\d+)", name)
    if m and "NUM_CORES" not in params:
        params["NUM_CORES"] = m.group(1)
    m = re.search(r"(?:^|_)f(\d+)", name)
    if m and "CLOCK_FREQ_HZ" not in params:
        params["CLOCK_FREQ_HZ"] = m.group(1)

    if "NUM_CORES" not in params and "CONFIGS" in params:
        m = re.search(r"-DNUM_CORES=(\d+)", params["CONFIGS"])
        if m:
            params["NUM_CORES"] = m.group(1)

    params.setdefault("TARGET", "hw")
    required = ["CONFIGS", "PLATFORM", "CLOCK_FREQ_HZ", "NUM_CORES"]
    missing_keys = [k for k in required if k not in params]
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
    entries: list[dict] = []
    now_iso = dt.datetime.now().isoformat()
    for d in dirs:
        original_name = None
        manifest_path = d / "manifest.json"
        if manifest_path.exists():
            try:
                mj = json.loads(manifest_path.read_text())
                origin = mj.get("origin", {})
                original_name = (
                    origin.get("original_dir")
                    or mj.get("original_dir")
                    or mj.get("original_dir_hint")
                )
            except Exception:
                original_name = None

        params_raw, params_norm, meta = load_params(d, original_name)
        lines = canonical_kv_lines(params_norm)
        build_id, hash_full = compute_hash(lines, hash_len)
        target = params_norm.get("TARGET", "hw")
        platform = params_norm.get("PLATFORM", "unknown")
        plat_short = short_platform(platform)
        cores = params_norm.get("NUM_CORES", "na")
        freq = params_norm.get("CLOCK_FREQ_HZ", "na")
        name_base = f"xrt_{target}_{plat_short}_c{cores}_f{freq}"
        original_hint = original_name or d.name
        fpint_flag = "fpint" in original_hint.lower() or meta["sources_has_fpint"]
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
            "original_dir_hint": original_hint if original_hint != d.name else None,
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
        for idx, e in enumerate(group_sorted, start=1):
            if idx == 1:
                continue
            e["name_final"] = f"{base}_{idx}"
            e["collision_suffix"] = idx
            e["duplicate_of"] = group_sorted[0]["name_base"]

    return entries


def plan_actions(entries: list[dict], keep_original: bool) -> dict:
    renames = []
    symlinks = []
    manifests = []
    for e in entries:
        src = e["dir_path"]
        canonical = src.parent / e["name_final"]

        if src.name == e["name_final"]:
            # Already canonically named — no rename/symlink needed.
            manifest_path = src / "manifest.json"
        elif keep_original:
            # Keep original folder name; expose canonical name via sibling symlink.
            symlinks.append((canonical, src.name))
            manifest_path = src / "manifest.json"
        else:
            # Rename original folder to canonical name.
            renames.append((src, canonical))
            manifest_path = canonical / "manifest.json"

        manifests.append((manifest_path, e))

    return {
        "renames": renames,
        "symlinks": symlinks,
        "manifests": manifests,
    }


def print_plan(root: Path, entries: list[dict], actions: dict, update_index: bool) -> None:
    print(f"root: {root}")
    print(f"builds: {len(entries)}")
    if actions["renames"]:
        print("renames:")
        for src, dst in actions["renames"]:
            if src.parent == dst.parent:
                print(f"  {src.parent}/{src.name} -> {dst.name}")
            else:
                print(f"  {src} -> {dst}")
    else:
        print("renames: none")
    if actions.get("symlinks"):
        print("symlinks (canonical -> original, keep-original mode):")
        for link_path, target_name in actions["symlinks"]:
            print(f"  {link_path} -> {target_name}")
    print("manifests:")
    for manifest_path, e in actions["manifests"]:
        print(f"  {manifest_path}")
    if update_index:
        print("links:")
        print(f"  {root/'by-hash'}/<hash> -> <build dir>")
        print(f"  {root/'latest'} -> <build dir>")
        print(f"hash index: {root/'hashes.json'}")
    else:
        print("links: skipped (--dir mode, root index untouched)")
    warn = [e for e in entries if e["params_incomplete"]]
    if warn:
        print("warnings:")
        for e in warn:
            if e["missing_keys"]:
                print(f"  {e['dir_name']}: missing {','.join(e['missing_keys'])}")
            else:
                print(f"  {e['dir_name']}: fallback params (no .config.stamp)")


def apply_actions(root: Path, entries: list[dict], actions: dict, force: bool, update_index: bool) -> None:
    # Preflight manifest write permissions before mutating any directory names.
    rename_src_by_dst = {dst: src for src, dst in actions["renames"]}
    manifest_blocked: list[Path] = []
    for manifest_path, _ in actions["manifests"]:
        if manifest_path.exists() and not force:
            continue

        dst_parent = manifest_path.parent
        src_parent = rename_src_by_dst.get(dst_parent)
        check_parent = dst_parent if dst_parent.exists() else src_parent

        if check_parent is None or not check_parent.exists():
            manifest_blocked.append(dst_parent)
            continue
        if not os.access(check_parent, os.W_OK):
            manifest_blocked.append(check_parent)
            continue

        if force:
            check_manifest_path = manifest_path
            if not check_manifest_path.exists() and src_parent is not None:
                src_manifest = src_parent / manifest_path.name
                if src_manifest.exists():
                    check_manifest_path = src_manifest
            if check_manifest_path.exists() and not os.access(check_manifest_path, os.W_OK):
                manifest_blocked.append(check_manifest_path)

    if manifest_blocked:
        unique_blocked = sorted({str(p) for p in manifest_blocked})
        blocked_lines = "\n".join(f"  - {p}" for p in unique_blocked)
        raise RuntimeError(
            "insufficient write permission for manifest update:\n"
            f"{blocked_lines}\n"
            "fix permissions and retry (--force does not bypass filesystem ACLs)"
        )

    # Execute renames in two phases to avoid destination conflicts.
    # Example: old_name -> xrt_name and xrt_name -> xrt_name_2.
    # tmp file is staged in the source's own parent so that in-place renames
    # (--dir mode, source outside --root) do not depend on root being writable.
    renamed_sources = {src for src, _ in actions["renames"]}

    staged_renames: list[tuple[Path, Path, Path]] = []
    for idx, (src, dst) in enumerate(actions["renames"], start=1):
        if not src.exists():
            raise RuntimeError(f"source missing: {src}")

        stage_dir = src.parent
        tmp = stage_dir / f".vortex_binmgr_tmp_{idx}_{src.name}"
        salt = 1
        while tmp.exists() or tmp.is_symlink() or tmp == src or tmp == dst:
            tmp = stage_dir / f".vortex_binmgr_tmp_{idx}_{salt}_{src.name}"
            salt += 1

        src.rename(tmp)
        staged_renames.append((src, tmp, dst))

    for _, tmp, dst in staged_renames:
        if dst.exists() or dst.is_symlink():
            raise RuntimeError(f"destination exists: {dst}")
        tmp.rename(dst)

    # Create keep-original symlinks (canonical -> original sibling).
    for link_path, target_name in actions.get("symlinks", []):
        if link_path.is_symlink():
            current = os.readlink(link_path)
            if current == target_name:
                continue  # already correct
            if not force:
                raise RuntimeError(
                    f"symlink exists and points elsewhere: {link_path} -> {current} "
                    f"(want {target_name}); use --force to replace"
                )
            link_path.unlink()
        elif link_path.exists():
            raise RuntimeError(
                f"cannot create canonical symlink, a real entry exists at: {link_path}"
            )
        link_path.symlink_to(target_name)

    # Update entry paths after rename. Keep-original entries retain their src path.
    for e in entries:
        if e["dir_path"] in renamed_sources:
            e["dir_path"] = e["dir_path"].parent / e["name_final"]

    now_iso = dt.datetime.now().isoformat()

    # Write manifests
    for manifest_path, e in actions["manifests"]:
        if manifest_path.exists() and not force:
            continue
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest = build_manifest(e, now_iso)
        try:
            manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        except PermissionError as exc:
            raise RuntimeError(
                f"manifest write permission denied: {manifest_path} "
                "(fix ACL/ownership and retry)"
            ) from exc

    if not update_index:
        return

    # Build hash index
    index = {
        "generated_at": now_iso,
        "hash_len": entries[0]["hash_len"] if entries else DEFAULT_HASH_LEN,
        "entries": [],
    }
    for e in sorted(entries, key=lambda x: x["name_final"]):
        index["entries"].append(
            {
                "build_id": e["build_id"],
                "name": e["name_final"],
                "path": str(e["dir_path"]),
                "manifest": str(e["dir_path"] / "manifest.json"),
                "params_source": e["params_source"],
                "params_incomplete": e["params_incomplete"],
            }
        )
    (root / "hashes.json").write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")

    # by-hash links
    by_hash = root / "by-hash"
    by_hash.mkdir(exist_ok=True)
    hash_seen = {}
    for e in entries:
        h = e["build_id"]
        n = hash_seen.get(h, 0) + 1
        hash_seen[h] = n
        link_name = h if n == 1 else f"{h}_{n}"
        link_path = by_hash / link_name
        if link_path.exists() or link_path.is_symlink():
            link_path.unlink()
        rel_target = os.path.relpath(e["dir_path"], by_hash)
        link_path.symlink_to(rel_target)

    # latest link (by build_time if available, else by dir mtime)
    def build_sort_key(e):
        if e["build_time"]:
            try:
                return dt.datetime.fromisoformat(e["build_time"])
            except ValueError:
                pass
        return dt.datetime.fromtimestamp(e["dir_path"].stat().st_mtime)

    if entries:
        latest = max(entries, key=build_sort_key)
        latest_link = root / "latest"
        if latest_link.exists() or latest_link.is_symlink():
            latest_link.unlink()
        latest_link.symlink_to(os.path.relpath(latest["dir_path"], root))


def main() -> int:
    ap = argparse.ArgumentParser(description="Manage vortex FPGA build bins")
    ap.add_argument("--root", type=Path, default=Path("/opt/vortex_fpga_bins"))
    ap.add_argument(
        "--dir",
        type=Path,
        action="append",
        default=[],
        metavar="DIR",
        help="specific build dir to process (repeatable). "
             "If omitted, scan --root. "
             "When used, rename is in-place in DIR's parent and root index/symlinks are NOT updated.",
    )
    ap.add_argument(
        "--rename-original",
        action="store_true",
        help="With --dir: rename the original folder to the canonical name. "
             "Default is to keep the original folder untouched and expose the "
             "canonical name as a sibling symlink. "
             "Ignored without --dir (root scan always renames).",
    )
    ap.add_argument("--hash-len", type=int, default=DEFAULT_HASH_LEN)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--force", action="store_true", help="overwrite manifest.json or mismatched symlinks if exist")
    args = ap.parse_args()

    if args.dir:
        seen: set[Path] = set()
        dirs: list[Path] = []
        for p in args.dir:
            resolved = p.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            if not resolved.exists():
                raise SystemExit(f"not a directory: {p}")
            if not resolved.is_dir():
                raise SystemExit(f"not a directory: {p}")
            if not detect_build_dir(resolved):
                raise SystemExit(
                    f"not a build dir (needs .config.stamp, bin/vortex_afu.xclbin, "
                    f"or v++_vortex_afu.log): {p}"
                )
            dirs.append(resolved)
        update_index = False
        keep_original = not args.rename_original
    else:
        dirs = collect_dirs(args.root)
        update_index = True
        # Root-scan mode preserves existing behavior: always rename to canonical.
        keep_original = False

    entries = plan_entries(dirs, args.hash_len)
    actions = plan_actions(entries, keep_original)

    if not args.apply:
        print_plan(args.root, entries, actions, update_index)
        return 0

    apply_actions(args.root, entries, actions, args.force, update_index)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
