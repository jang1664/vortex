import argparse
import json
import os
import re
import sys

BEAT_BYTES = 8
LMEM_SIZE = 1024 * 1024

# Mirrors tb_VX_gemm_node.sv GMEM base layout.
GMEM_IN_BASE = 0x0010_0000
GMEM_W_BASE  = 0x0020_0000
GMEM_SC_BASE = 0x0030_0000
GMEM_ZP_BASE = 0x0040_0000

SECTION_RE = re.compile(r"^Test (Inputs|Weights|Scales|ZPs):\s*$")
HEX_LINE_RE = re.compile(r"^[0-9a-fA-FxX\s]+$")

DMA_START_RE = re.compile(
  r"(?P<time>\d+)ns: dma_node_tb dma-start: "
  r"entry_id=(?P<entry>\d+), dir=(?P<dir>\d+), "
  r"src_base=0x(?P<src>[0-9a-fA-F]+), dst_base=0x(?P<dst>[0-9a-fA-F]+), "
  r"seg_size=(?P<seg>\d+), padding=(?P<pad>\d+), "
  r"bound=\((?P<b0>\d+),(?P<b1>\d+),(?P<b2>\d+)\)"
)

DMA_G2L_WR_RE = re.compile(
  r"(?P<time>\d+)ns: dma_node_tb dma-run G2L wr-req\(lmem\): "
  r"addr=0x(?P<addr>[0-9a-fA-F]+), byte_addr=0x(?P<byte_addr>[0-9a-fA-F]+), "
  r"byteen=0x(?P<byteen>[0-9a-fA-F]+), data=0x(?P<data>[0-9a-fA-F]+), "
  r"tag=0x(?P<tag>[0-9a-fA-F]+), out_off=(?P<off>\d+)"
)

DMA_G2L_RD_RE = re.compile(
  r"(?P<time>\d+)ns: dma_node_tb dma-run G2L rd-req\(dcache\): "
  r"addr=0x(?P<addr>[0-9a-fA-F]+), byte_addr=0x(?P<byte_addr>[0-9a-fA-F]+), "
  r"tag=0x(?P<tag>[0-9a-fA-F]+), out_off=(?P<off>\d+)"
)


def _load_lines(log_path):
  if not os.path.isfile(log_path):
    raise FileNotFoundError(f"log file not found: {log_path}")
  with open(log_path, "r", encoding="utf-8", errors="replace") as f:
    return f.read().splitlines()


def _collect_section_lines(lines, marker):
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


def _parse_hex_tokens(section_lines, section_name):
  vals = []
  for line in section_lines:
    for tok in line.split():
      if "x" in tok.lower():
        raise ValueError(f"unknown-value token in {section_name}: {tok}")
      vals.append(int(tok, 16))
  return vals


def _u16_list_to_le_bytes(vals):
  out = bytearray()
  for v in vals:
    out.append(v & 0xFF)
    out.append((v >> 8) & 0xFF)
  return out


def _pack_int4_rowmajor(weights, n_cols):
  if n_cols % 2 != 0:
    raise ValueError(f"weight column count must be even, got {n_cols}")
  out = bytearray()
  for i in range(0, len(weights), n_cols):
    row = weights[i:i+n_cols]
    for n in range(0, n_cols, 2):
      lo = row[n] & 0xF
      hi = row[n + 1] & 0xF
      out.append((hi << 4) | lo)
  return out


def parse_test_tensors(log_path):
  lines = _load_lines(log_path)

  in_lines = _collect_section_lines(lines, "Test Inputs:")
  w_lines  = _collect_section_lines(lines, "Test Weights:")
  sc_lines = _collect_section_lines(lines, "Test Scales:")
  zp_lines = _collect_section_lines(lines, "Test ZPs:")

  input_vals  = _parse_hex_tokens(in_lines, "Test Inputs")
  weight_vals = _parse_hex_tokens(w_lines, "Test Weights")
  scale_vals  = _parse_hex_tokens(sc_lines, "Test Scales")
  zp_vals     = _parse_hex_tokens(zp_lines, "Test ZPs")

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


def parse_dma_transactions(log_path):
  lines = _load_lines(log_path)
  starts = []
  wr_reqs = []
  rd_reqs = []

  for ln, line in enumerate(lines, start=1):
    m = DMA_START_RE.search(line)
    if m:
      starts.append({
        "line": ln,
        "time": int(m.group("time")),
        "entry_id": int(m.group("entry")),
        "dir": int(m.group("dir")),
        "src_base": int(m.group("src"), 16),
        "dst_base": int(m.group("dst"), 16),
        "seg_size": int(m.group("seg")),
        "padding": int(m.group("pad")),
        "bound0": int(m.group("b0")),
        "bound1": int(m.group("b1")),
        "bound2": int(m.group("b2")),
      })
      continue

    m = DMA_G2L_WR_RE.search(line)
    if m:
      wr_reqs.append({
        "line": ln,
        "time": int(m.group("time")),
        "addr": int(m.group("addr"), 16),
        "byte_addr": int(m.group("byte_addr"), 16),
        "byteen": int(m.group("byteen"), 16),
        "data": int(m.group("data"), 16),
        "tag": int(m.group("tag"), 16),
        "out_off": int(m.group("off")),
      })
      continue

    m = DMA_G2L_RD_RE.search(line)
    if m:
      rd_reqs.append({
        "line": ln,
        "time": int(m.group("time")),
        "addr": int(m.group("addr"), 16),
        "byte_addr": int(m.group("byte_addr"), 16),
        "tag": int(m.group("tag"), 16),
        "out_off": int(m.group("off")),
      })

  return {
    "starts": starts,
    "wr_reqs": wr_reqs,
    "rd_reqs": rd_reqs,
  }


def _data_to_bytes_le(data_word):
  return [(data_word >> (8 * i)) & 0xFF for i in range(BEAT_BYTES)]


def _expected_beat(src_bytes, src_row_bytes, row_idx, inrow_off):
  exp = [0] * BEAT_BYTES
  src_off = row_idx * src_row_bytes + inrow_off
  for b in range(BEAT_BYTES):
    idx = src_off + b
    if idx < len(src_bytes):
      exp[b] = src_bytes[idx]
  return exp


def check_dma_transactions(log_path):
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
          check["mismatches"].append({
            "line": wr["line"],
            "reason": f"unexpected byteen=0x{wr['byteen']:x}",
          })
        continue

      dst_off = wr["byte_addr"] - dst_base
      row_idx = dst_off // seg_size
      inrow_off = dst_off % seg_size

      if row_idx >= bound0:
        check["mismatch_count"] += 1
        if len(check["mismatches"]) < 16:
          check["mismatches"].append({
            "line": wr["line"],
            "reason": f"dst row out of range (row={row_idx}, bound0={bound0})",
          })
        continue

      if inrow_off < expected_src_row:
        exp = _expected_beat(src_bytes, expected_src_row, row_idx, inrow_off)
      else:
        exp = [0] * BEAT_BYTES
      obs = _data_to_bytes_le(wr["data"])

      if obs != exp:
        check["mismatch_count"] += 1
        if len(check["mismatches"]) < 16:
          check["mismatches"].append({
            "line": wr["line"],
            "byte_addr": f"0x{wr['byte_addr']:x}",
            "row": row_idx,
            "inrow_off": inrow_off,
            "obs": [f"0x{x:02x}" for x in obs],
            "exp": [f"0x{x:02x}" for x in exp],
          })

    if check["mismatch_count"] != 0:
      failures.append(
        f"start@line{start['line']}: data mismatches={check['mismatch_count']}"
      )

    checks.append(check)

  if not checks:
    failures.append("no eligible G2L->LMEM DMA starts found for validation")

  report = {
    "log_path": log_path,
    "shape": tensors["shape"],
    "num_dma_starts": len(starts),
    "num_checked_starts": len(checks),
    "checks": checks,
    "failures": failures,
    "pass": len(failures) == 0,
  }

  return report

if __name__ == "__main__":
  parser = argparse.ArgumentParser(description="GEMM node log analyzer")
  default_log = os.path.join(os.path.dirname(__file__), "..", "logs", "sim.log")
  parser.add_argument("--log", default=default_log, help="Path to sim.log")
  parser.add_argument("--check-dma", action="store_true", help="Check DMA transactions")
  parser.add_argument("--json", action="store_true", help="Print full JSON report")
  args = parser.parse_args()


  if args.check_dma:
    try:
      report = check_dma_transactions(args.log)
    except Exception as e:
      print(f"[FAIL] analyzer error: {e}")
      sys.exit(1)

    if args.json:
      print(json.dumps(report, indent=2))
    else:
      print(f"log: {report['log_path']}")
      print(
        f"shape: M={report['shape']['M']} "
        f"N={report['shape']['N']} K={report['shape']['K']}"
      )
      print(
        f"checked starts: {report['num_checked_starts']} / "
        f"total starts: {report['num_dma_starts']}"
      )
      for c in report["checks"]:
        print(
          f"- start@line{c['start_line']} "
          f"src={c['src_base']} dst={c['dst_base']} "
          f"wr {c['observed_wr']}/{c['expected_wr']} "
          f"rd {c['observed_rd']}/{c['expected_rd']} "
          f"mism={c['mismatch_count']}"
        )
      if report["pass"]:
        print("[PASS] GMEM->LMEM DMA data check passed")
      else:
        print("[FAIL] GMEM->LMEM DMA data check failed")
        for f in report["failures"]:
          print(f"  - {f}")
      sys.exit(0 if report["pass"] else 1)
