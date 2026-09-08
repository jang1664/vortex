"""Generate VCS configuration from evaluated Make values, never Makefile text."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re


def defines(raw, allow_identical=False):
    result = {}
    for token in raw.split():
        match = re.fullmatch(r"-D([A-Za-z_][A-Za-z_0-9]*)(?:=(.+))?", token)
        if not match:
            raise ValueError(f"Invalid define: {token}")
        name, value = match.groups()
        value = "1" if value is None else value
        if name in result and (not allow_identical or result[name] != value):
            raise ValueError(f"Duplicate or conflicting define: {name}")
        result[name] = value
    return result


def positive(value, name):
    if not re.fullmatch(r"[0-9]+", value) or int(value) <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


def resolve(env):
    defines(env["U55C_INPUT_DEFINES"])
    config = defines(env["U55C_EFFECTIVE_DEFINES"], allow_identical=True)
    ports = positive(config.get("NUM_HBM_PORTS", "8"), "NUM_HBM_PORTS")
    if ports not in (4, 8):
        raise ValueError("U55C requires 4 or 8 kernel AXI ports")
    dma = positive(config.get("NUM_DMA_CHANNELS", "8"), "NUM_DMA_CHANNELS")
    tmem = positive(config.get("NUM_TMEM_BANKS", "8"), "NUM_TMEM_BANKS")
    if dma & (dma - 1) or tmem & (tmem - 1) or dma > min(ports, tmem):
        raise ValueError("Vortex_axi requires power-of-two DMA/TMEM counts and DMA <= HBM ports/TMEM banks")
    if "PLATFORM_MEMORY_NUM_PORTS" in config and config["PLATFORM_MEMORY_NUM_PORTS"] != str(ports):
        raise ValueError("PLATFORM_MEMORY_NUM_PORTS disagrees with NUM_HBM_PORTS")
    for name, expected in (("PLATFORM_MEMORY_NUM_BANKS", "32"),
                           ("PLATFORM_MEMORY_ADDR_WIDTH", "34"),
                           ("MEM_ADDR_WIDTH", "34"),
                           ("PLATFORM_MEMORY_DATA_SIZE", "64"),
                           ("PLATFORM_MEMORY_ID_WIDTH", "32")):
        if config.get(name) != expected:
            raise ValueError(f"Unsupported U55C geometry: {name}={config.get(name)}")
    routes = {}
    covered = set()
    for spec in env["U55C_SP_FLAGS"].split():
        match = re.fullmatch(r"vortex_afu_1\.m_axi_mem_(\d+):HBM\[(\d+):(\d+)\]", spec)
        if not match:
            raise ValueError(f"Unsupported connectivity: {spec}")
        port, first, last = map(int, match.groups())
        if port in routes or not 0 <= port < ports or not 0 <= first <= last < 32:
            raise ValueError(f"Invalid or repeated port/range: {spec}")
        pcs = set(range(first, last + 1))
        if covered & pcs:
            raise ValueError(f"Overlapping PC aperture: {spec}")
        covered |= pcs
        routes[port] = {"port": port, "first_pc": first, "last_pc": last}
    if set(routes) != set(range(ports)) or covered != set(range(32)):
        raise ValueError("Connectivity must cover every kernel port and all 32 PCs")
    logic = positive(env["U55C_LOGIC_FREQ_HZ"], "LOGIC_FREQ_HZ")
    hbm = positive(env["U55C_HBM_AXI_FREQ_HZ"], "HBM_AXI_FREQ_HZ")
    if max(logic, hbm) > 500_000_000_000:
        raise ValueError("Clock half-period must be at least 1 ps")
    platform = env["U55C_PLATFORM"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]*xilinx_u55c[A-Za-z0-9_.-]*", platform):
        raise ValueError("Unsupported platform identity")
    platform_dir = Path(env["U55C_PLATFORM_DIR"])
    return {
        "schema_version": 1, "platform": platform,
        "defines": config, "kernel_ports": ports, "kernel_data_bytes": 64,
        "pc_count": 32, "pc_bytes": 1 << 29, "aperture_bytes": 1 << 34,
        "logic_freq_hz": logic, "hbm_axi_freq_hz": hbm,
        "dram_profile": "HBM2_2Gbps", "dram_tck_ps": 1000,
        "time_precision_ps": 1,
        "switch_profile": {
            "name": "abstract-paired-pc-links-v1",
            "request_bytes_per_hbm_edge_per_port": 32,
            "return_bytes_per_hbm_edge_per_port": 32,
            "shared_link": "one 32-byte link per physical channel, per direction",
            "request_cdc_receiving_edges": 2,
            "response_cdc_receiving_edges": 2,
            "read_response_capacity_per_port": 256,
            "write_burst_capacity_per_port": 16,
            "unassociated_w_capacity_per_port": 64,
            "ordering": "FIFO per port per response channel; stronger than same-ID AXI ordering",
            "visibility": "AR snapshots RAM; W updates RAM when associated with AW; BO writes immediate on service",
        },
        "routes": [routes[p] for p in range(ports)],
        "provenance": {
            "connectivity": "Make-evaluated platforms.mk SP_FLAGS",
            "source_sha256": {name: hashlib.sha256((platform_dir / name).read_bytes()).hexdigest()
                              for name in ("platforms.mk", "geometry.mk")},
            "physical_routing": "abstract; no verified linked HMSS ingress metadata",
            "timing": "uncalibrated; HBM AXI frequency is a model input, not a measured U55C clock",
        },
    }


def generate(env, output):
    manifest = resolve(env)
    canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode()).hexdigest()
    manifest["sha256"] = digest
    constants = {"MANIFEST_HASH": f'"{digest}"',
                 "LOGIC_FREQ_HZ": manifest["logic_freq_hz"],
                 "HBM_AXI_FREQ_HZ": manifest["hbm_axi_freq_hz"],
                 "DRAM_TCK_PS": manifest["dram_tck_ps"],
                 "NUM_PORTS": manifest["kernel_ports"]}
    cpp = "// Generated; do not edit.\n#pragma once\n"
    sv = "// Generated; do not edit.\n`ifndef U55C_MODEL_CONFIG_SVH\n`define U55C_MODEL_CONFIG_SVH\n"
    for name, value in constants.items():
        cpp += f"#define U55C_{name} {value}\n"
        sv += f"`define U55C_{name} {value}\n"
    cpp += "namespace u55c_config {\n"
    for field in ("first_pc", "last_pc"):
        values = ", ".join(str(route[field]) for route in manifest["routes"])
        cpp += f"inline constexpr unsigned {field}[] = {{{values}}};\n"
    cpp += "}\n"
    sv += "`endif\n"
    output.mkdir(parents=True, exist_ok=True)
    for name, contents in (("u55c_model_manifest.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n"),
                           ("u55c_model_config.svh", sv), ("u55c_model_config.h", cpp)):
        path = output / name
        if not path.exists() or path.read_text() != contents:
            temporary = path.with_suffix(path.suffix + ".tmp")
            temporary.write_text(contents)
            temporary.replace(path)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        generate(os.environ, args.output_dir)
    except (ValueError, KeyError) as exc:
        parser.exit(2, f"HBM configuration error: {exc}\n")
