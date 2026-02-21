"""DMA transaction validation for GEMM node RTL logs.

This module ports the legacy gemm_node `log_analyzer/main.py` DMA checker
into the current structured-log analyzer framework.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys

from log_analyzer.log_format import parse_line

BEAT_BYTES = 8
LMEM_SIZE = 1024 * 1024

# Mirrors tb_VX_gemm_node.sv GMEM base layout.
GMEM_IN_BASE = 0x0010_0000
GMEM_W_BASE = 0x0020_0000
GMEM_SC_BASE = 0x0030_0000
GMEM_ZP_BASE = 0x0040_0000

HEX_LINE_RE = re.compile(r"^[0-9a-fA-FxX\s]+$")

DMA_EVENTS = {
    "DMA_START",
    "DMA_RUN_G2L_WR_REQ_LMEM",
    "DMA_RUN_G2L_RD_REQ_DCACHE",
}


def _load_lines(log_path: str | Path) -> list[str]:
    path = Path(log_path)
    if not path.is_file():
        raise FileNotFoundError(f"log file not found: {path}")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def _collect_section_lines(lines: list[str], marker: str) -> list[str]:
    start = None
    for i, line in enumerate(lines):
        if line.strip() == marker:
            start = i + 1
            break
    if start is None:
        raise ValueError(f"section not found in log: {marker}")

    out = []
    for i in range(start, len(lines)):
        s = lines[i].strip()
        if not s:
            continue
        if s.startswith("Test "):
            break
        if s.startswith("[") or "dma_node_tb" in s:
            break
        if not HEX_LINE_RE.match(s):
            break
        out.append(s)

    if not out:
        raise ValueError(f"section is empty in log: {marker}")
    return out


def _parse_hex_tokens(section_lines: list[str], section_name: str) -> list[int]:
    vals: list[int] = []
    for line in section_lines:
        for tok in line.split():
            if "x" in tok.lower():
                raise ValueError(f"unknown-value token in {section_name}: {tok}")
            vals.append(int(tok, 16))
    return vals


def _u16_list_to_le_bytes(vals: list[int]) -> bytearray:
    out = bytearray()
    for v in vals:
        out.append(v & 0xFF)
        out.append((v >> 8) & 0xFF)
    return out


def _pack_int4_rowmajor(weights: list[int], n_cols: int) -> bytearray:
    if n_cols % 2 != 0:
        raise ValueError(f"weight column count must be even, got {n_cols}")
    out = bytearray()
    for i in range(0, len(weights), n_cols):
        row = weights[i : i + n_cols]
        for n in range(0, n_cols, 2):
            lo = row[n] & 0xF
            hi = row[n + 1] & 0xF
            out.append((hi << 4) | lo)
    return out


def _to_int(value, field: str) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise ValueError(f"invalid int field {field}: {value!r}")


def parse_test_tensors(log_path: str | Path) -> dict:
    lines = _load_lines(log_path)

    in_lines = _collect_section_lines(lines, "Test Inputs:")
    w_lines = _collect_section_lines(lines, "Test Weights:")
    sc_lines = _collect_section_lines(lines, "Test Scales:")
    zp_lines = _collect_section_lines(lines, "Test ZPs:")

    input_vals = _parse_hex_tokens(in_lines, "Test Inputs")
    weight_vals = _parse_hex_tokens(w_lines, "Test Weights")
    scale_vals = _parse_hex_tokens(sc_lines, "Test Scales")
    zp_vals = _parse_hex_tokens(zp_lines, "Test ZPs")

    m = len(in_lines)
    k = len(in_lines[0].split())
    k_w = len(w_lines)
    n = len(w_lines[0].split())

    if m * k != len(input_vals):
        raise ValueError("input tensor token count mismatch")
    if k_w != k:
        raise ValueError(f"input K({k}) != weight K({k_w})")
    if k * n != len(weight_vals):
        raise ValueError("weight tensor token count mismatch")
    if len(scale_vals) != n:
        raise ValueError(f"scale size({len(scale_vals)}) != N({n})")
    if len(zp_vals) != n:
        raise ValueError(f"zp size({len(zp_vals)}) != N({n})")

    gmem = {
        GMEM_IN_BASE: _u16_list_to_le_bytes(input_vals),
        GMEM_W_BASE: _pack_int4_rowmajor(weight_vals, n),
        GMEM_SC_BASE: _u16_list_to_le_bytes(scale_vals),
        GMEM_ZP_BASE: _u16_list_to_le_bytes(zp_vals),
    }

    return {
        "shape": {"M": m, "N": n, "K": k},
        "gmem": gmem,
        "sections": {
            "inputs_lines": len(in_lines),
            "weights_lines": len(w_lines),
            "scales_lines": len(sc_lines),
            "zps_lines": len(zp_lines),
        },
    }


def parse_dma_transactions(log_path: str | Path) -> dict:
    lines = _load_lines(log_path)
    starts = []
    wr_reqs = []
    rd_reqs = []

    for ln, line in enumerate(lines, start=1):
        entry = parse_line(line)
        if entry is None or entry.event not in DMA_EVENTS:
            continue
        if not isinstance(entry.payload, dict):
            continue

        payload = entry.payload

        if entry.event == "DMA_START":
            bound = payload.get("bound", [])
            if isinstance(bound, list) and len(bound) >= 3:
                b0 = _to_int(bound[0], "bound[0]")
                b1 = _to_int(bound[1], "bound[1]")
                b2 = _to_int(bound[2], "bound[2]")
            else:
                b0 = _to_int(payload.get("bound0", 0), "bound0")
                b1 = _to_int(payload.get("bound1", 0), "bound1")
                b2 = _to_int(payload.get("bound2", 0), "bound2")

            starts.append(
                {
                    "line": ln,
                    "time": entry.time,
                    "entry_id": _to_int(payload.get("entry_id", 0), "entry_id"),
                    "dir": _to_int(payload.get("dir", 0), "dir"),
                    "src_base": _to_int(payload.get("src_base", 0), "src_base"),
                    "dst_base": _to_int(payload.get("dst_base", 0), "dst_base"),
                    "seg_size": _to_int(payload.get("seg_size", 0), "seg_size"),
                    "padding": _to_int(payload.get("padding", 0), "padding"),
                    "bound0": b0,
                    "bound1": b1,
                    "bound2": b2,
                }
            )
            continue

        if entry.event == "DMA_RUN_G2L_WR_REQ_LMEM":
            wr_reqs.append(
                {
                    "line": ln,
                    "time": entry.time,
                    "addr": _to_int(payload.get("addr", 0), "addr"),
                    "byte_addr": _to_int(payload.get("byte_addr", 0), "byte_addr"),
                    "byteen": _to_int(payload.get("byteen", 0), "byteen"),
                    "data": _to_int(payload.get("data", 0), "data"),
                    "tag": _to_int(payload.get("tag", 0), "tag"),
                    "out_off": _to_int(payload.get("out_off", 0), "out_off"),
                }
            )
            continue

        if entry.event == "DMA_RUN_G2L_RD_REQ_DCACHE":
            rd_reqs.append(
                {
                    "line": ln,
                    "time": entry.time,
                    "addr": _to_int(payload.get("addr", 0), "addr"),
                    "byte_addr": _to_int(payload.get("byte_addr", 0), "byte_addr"),
                    "tag": _to_int(payload.get("tag", 0), "tag"),
                    "out_off": _to_int(payload.get("out_off", 0), "out_off"),
                }
            )

    return {
        "starts": starts,
        "wr_reqs": wr_reqs,
        "rd_reqs": rd_reqs,
    }


def _data_to_bytes_le(data_word: int) -> list[int]:
    return [(data_word >> (8 * i)) & 0xFF for i in range(BEAT_BYTES)]


def _expected_beat(src_bytes: bytearray, src_row_bytes: int, row_idx: int, inrow_off: int) -> list[int]:
    exp = [0] * BEAT_BYTES
    src_off = row_idx * src_row_bytes + inrow_off
    for b in range(BEAT_BYTES):
        idx = src_off + b
        if idx < len(src_bytes):
            exp[b] = src_bytes[idx]
    return exp


def check_dma_transactions(log_path: str | Path) -> dict:
    tensors = parse_test_tensors(log_path)
    dma = parse_dma_transactions(log_path)

    starts = dma["starts"]
    wr_reqs = dma["wr_reqs"]
    rd_reqs = dma["rd_reqs"]
    gmem = tensors["gmem"]

    failures = []
    checks = []

    for i, start in enumerate(starts):
        src_base = start["src_base"]
        dst_base = start["dst_base"]
        seg_size = start["seg_size"]
        padding = start["padding"]
        bound0 = start["bound0"]

        # Only check known G2L transactions that write into LMEM space.
        if start["dir"] != 0:
            continue
        if src_base not in gmem:
            continue
        if dst_base >= LMEM_SIZE:
            continue

        t0 = start["time"]
        t1 = starts[i + 1]["time"] if i + 1 < len(starts) else sys.maxsize

        window_w = [w for w in wr_reqs if t0 <= w["time"] < t1]
        window_r = [r for r in rd_reqs if t0 <= r["time"] < t1]

        expected_wr = (bound0 * seg_size) // BEAT_BYTES
        expected_src_row = seg_size - padding
        expected_rd = (bound0 * expected_src_row) // BEAT_BYTES

        check = {
            "start_line": start["line"],
            "src_base": f"0x{src_base:x}",
            "dst_base": f"0x{dst_base:x}",
            "seg_size": seg_size,
            "padding": padding,
            "bound0": bound0,
            "observed_wr": len(window_w),
            "expected_wr": expected_wr,
            "observed_rd": len(window_r),
            "expected_rd": expected_rd,
            "mismatch_count": 0,
            "mismatches": [],
        }

        if len(window_w) != expected_wr:
            failures.append(
                f"start@line{start['line']}: write count mismatch "
                f"(obs={len(window_w)}, exp={expected_wr})"
            )

        if len(window_r) != expected_rd:
            failures.append(
                f"start@line{start['line']}: read count mismatch "
                f"(obs={len(window_r)}, exp={expected_rd})"
            )

        src_bytes = gmem[src_base]
        expected_src_total = bound0 * expected_src_row
        if len(src_bytes) < expected_src_total:
            failures.append(
                f"start@line{start['line']}: source bytes too short "
                f"(src_len={len(src_bytes)}, needed={expected_src_total})"
            )

        for wr in window_w:
            if wr["byteen"] != 0xFF:
                check["mismatch_count"] += 1
                if len(check["mismatches"]) < 16:
                    check["mismatches"].append(
                        {
                            "line": wr["line"],
                            "reason": f"unexpected byteen=0x{wr['byteen']:x}",
                        }
                    )
                continue

            dst_off = wr["byte_addr"] - dst_base
            row_idx = dst_off // seg_size
            inrow_off = dst_off % seg_size

            if row_idx >= bound0:
                check["mismatch_count"] += 1
                if len(check["mismatches"]) < 16:
                    check["mismatches"].append(
                        {
                            "line": wr["line"],
                            "reason": f"dst row out of range (row={row_idx}, bound0={bound0})",
                        }
                    )
                continue

            if inrow_off < expected_src_row:
                exp = _expected_beat(src_bytes, expected_src_row, row_idx, inrow_off)
            else:
                exp = [0] * BEAT_BYTES
            obs = _data_to_bytes_le(wr["data"])

            if obs != exp:
                check["mismatch_count"] += 1
                if len(check["mismatches"]) < 16:
                    check["mismatches"].append(
                        {
                            "line": wr["line"],
                            "byte_addr": f"0x{wr['byte_addr']:x}",
                            "row": row_idx,
                            "inrow_off": inrow_off,
                            "obs": [f"0x{x:02x}" for x in obs],
                            "exp": [f"0x{x:02x}" for x in exp],
                        }
                    )

        if check["mismatch_count"] != 0:
            failures.append(
                f"start@line{start['line']}: data mismatches={check['mismatch_count']}"
            )

        checks.append(check)

    if not checks:
        failures.append("no eligible G2L->LMEM DMA starts found for validation")

    report = {
        "log_path": str(log_path),
        "shape": tensors["shape"],
        "num_dma_starts": len(starts),
        "num_checked_starts": len(checks),
        "checks": checks,
        "failures": failures,
        "pass": len(failures) == 0,
    }

    return report
