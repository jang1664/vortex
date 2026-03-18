#!/usr/bin/env python3
"""Generate ILA probe width parameters for package_kernel.tcl.

Computes config-dependent ILA probe widths and writes a TCL variable file
that package_kernel.tcl sources at build time.

Usage:
    gen_ila_params.py -o <output_file> [options]

Options:
    -o FILE              Output TCL file path (required)
    --xlen N             XLEN value (default: 64)
    --configs STR        Raw CONFIGS string with -D flags
    --scope / --no-scope Scope enabled (default: disabled)
"""

import argparse
import sys


def clog2(n):
    return (n - 1).bit_length() if n > 1 else 0


def up(n):
    return max(n, 1)


def cdiv(a, b):
    return (a + b - 1) // b


def parse_configs(configs_str):
    """Parse -D flags from CONFIGS string."""
    cfg = {
        "num_warps": 4,
        "num_threads": 4,
        "simd_width": 4,
        "fpu": True,       # EXT_F enabled by default (ifndef EXT_F_DISABLE)
        "tcu": False,      # TCU disabled by default (ifdef EXT_TCU_ENABLE)
        "lmem": True,      # LMEM enabled by default (ifndef LMEM_DISABLE)
    }
    for token in configs_str.split():
        if token.startswith("-D"):
            define = token[2:]
            if "=" in define:
                key, val = define.split("=", 1)
                key = key.strip()
                val = val.strip()
            else:
                key, val = define.strip(), None

            if key == "NUM_WARPS":
                cfg["num_warps"] = int(val)
            elif key == "NUM_THREADS":
                cfg["num_threads"] = int(val)
            elif key == "SIMD_WIDTH":
                cfg["simd_width"] = int(val)
            elif key == "EXT_F_DISABLE":
                cfg["fpu"] = False
            elif key == "EXT_TCU_ENABLE":
                cfg["tcu"] = True
            elif key == "LMEM_DISABLE":
                cfg["lmem"] = False
    return cfg


def compute_params(args):
    """Compute all ILA probe widths from config parameters."""
    cfg = parse_configs(args.configs)
    XLEN = args.xlen
    NUM_WARPS = cfg["num_warps"]
    NUM_THREADS = cfg["num_threads"]
    SIMD_WIDTH = cfg["simd_width"]
    FPU = cfg["fpu"]
    TCU = cfg["tcu"]
    LMEM = cfg["lmem"]
    SCOPE = args.scope

    # Derived parameters
    PC_BITS = XLEN - 2
    UUID_WIDTH = 44 if SCOPE else 1
    NW_WIDTH = up(clog2(NUM_WARPS))
    ISSUE_WIDTH = up(cdiv(NUM_WARPS, 16))
    PER_ISSUE_WARPS = NUM_WARPS // ISSUE_WIDTH
    ISSUE_WIS_W = up(clog2(PER_ISSUE_WARPS))

    NUM_EX_UNITS = 2 + 1 + int(FPU) + int(TCU)  # ALU+LSU+SFU+FPU?+TCU?
    EX_BITS = up(clog2(NUM_EX_UNITS))
    NUM_REGS = 32 * (1 + int(FPU))
    NUM_REGS_BITS = clog2(NUM_REGS)

    INST_OP_BITS = 4
    INST_ALU_BITS = 4
    ALU_TYPE_BITS = 2
    INST_ARGS_BITS = ALU_TYPE_BITS + XLEN + 3

    MEM_ADDR_WIDTH = 34 if XLEN == 64 else 32
    ICACHE_WORD_SIZE = 4
    ICACHE_TAG_WIDTH = UUID_WIDTH + NW_WIDTH

    NUM_LSU_LANES = SIMD_WIDTH
    LSU_WORD_SIZE = XLEN // 8
    LSU_ADDR_WIDTH = MEM_ADDR_WIDTH - clog2(LSU_WORD_SIZE)
    L1_LINE_SIZE = 64
    LSU_LINE_SIZE = min(NUM_LSU_LANES * LSU_WORD_SIZE, L1_LINE_SIZE)
    LSU_MEM_BATCHES = up(cdiv(NUM_LSU_LANES * LSU_WORD_SIZE, LSU_LINE_SIZE))
    LSUQ_IN_SIZE = 2 * up(cdiv(SIMD_WIDTH, NUM_LSU_LANES))
    LSU_TAG_ID_BITS = up(clog2(LSUQ_IN_SIZE)) + up(clog2(LSU_MEM_BATCHES))
    LSU_TAG_WIDTH = UUID_WIDTH + LSU_TAG_ID_BITS
    MEM_FLAGS_WIDTH = 1 + int(LMEM)
    PID_WIDTH_LSU = up(clog2(max(NUM_THREADS // NUM_LSU_LANES, 1)))

    # AFU constants
    PENDING_WR_SIZEW = 12
    VX_DCR_ADDR_BITS = 12
    VX_DCR_DATA_WIDTH = 32

    # Build result dict: { "ILA_name": [(probe_idx, width, comment), ...] }
    probes = {}

    # ila_afu
    probes["AFU"] = [
        (0, 10,
         "ap_reset+ap_start+ap_done+ap_done_base+ap_done_wait_cache+ap_idle+vx_cache_drain+state(2)+interrupt"),
        (1, PENDING_WR_SIZEW + 1 + 1 + 1 + VX_DCR_ADDR_BITS + VX_DCR_DATA_WIDTH,
         f"PENDING_WR_SIZEW({PENDING_WR_SIZEW})+vx_busy(1)+vx_reset(1)+dcr_wr_valid(1)"
         f"+VX_DCR_ADDR_BITS({VX_DCR_ADDR_BITS})+VX_DCR_DATA_WIDTH({VX_DCR_DATA_WIDTH})"),
    ]

    # ila_sched
    probes["SCHED"] = [
        (0, 3 * NUM_WARPS + 3,
         f"3*NUM_WARPS({NUM_WARPS})+valid+ready+busy"),
    ]

    # ila_ibuffer
    probes["IBUFFER"] = [
        (0, ISSUE_WIS_W + 3 * PER_ISSUE_WARPS + 4,
         f"ISSUE_WIS_W({ISSUE_WIS_W})+3*PER_ISSUE_WARPS({PER_ISSUE_WARPS})+4"),
    ]

    # ila_scoreboard
    probes["SCOREBOARD"] = [
        (0, 4 * PER_ISSUE_WARPS + ISSUE_WIS_W + 3,
         f"4*PER_ISSUE_WARPS({PER_ISSUE_WARPS})+ISSUE_WIS_W({ISSUE_WIS_W})+3"),
    ]

    # ila_dispatch
    probes["DISPATCH"] = [
        (0, 2 * NUM_EX_UNITS + EX_BITS + 2,
         f"2*NUM_EX_UNITS({NUM_EX_UNITS})+EX_BITS({EX_BITS})+2"),
    ]

    # ila_fpu
    probes["FPU"] = [
        (0, 9, "fpu_probe0"),
    ]

    # ila_fetch
    probes["FETCH"] = [
        (0, 6, "fetch handshakes"),
        (1, NW_WIDTH + PC_BITS + NUM_THREADS,
         f"NW_WIDTH({NW_WIDTH})+PC_BITS({PC_BITS})+NUM_THREADS({NUM_THREADS})"),
        (2, ICACHE_TAG_WIDTH + ICACHE_WORD_SIZE * 8,
         f"ICACHE_TAG_WIDTH({ICACHE_TAG_WIDTH})+ICACHE_WORD_SIZE*8({ICACHE_WORD_SIZE * 8})"),
    ]

    # ila_issue
    probes["ISSUE"] = [
        (0, 7, "issue handshakes"),
        (1, EX_BITS + INST_OP_BITS + NW_WIDTH + PC_BITS + 1 + NUM_REGS_BITS + NUM_THREADS,
         f"EX_BITS({EX_BITS})+INST_OP_BITS({INST_OP_BITS})+NW_WIDTH({NW_WIDTH})"
         f"+PC_BITS({PC_BITS})+wb(1)+NUM_REGS_BITS({NUM_REGS_BITS})+NUM_THREADS({NUM_THREADS})"),
        (2, EX_BITS + INST_OP_BITS + ISSUE_WIS_W + PC_BITS + 1 + NUM_REGS_BITS + SIMD_WIDTH + 2,
         f"EX_BITS({EX_BITS})+INST_OP_BITS({INST_OP_BITS})+ISSUE_WIS_W({ISSUE_WIS_W})"
         f"+PC_BITS({PC_BITS})+wb(1)+NUM_REGS_BITS({NUM_REGS_BITS})+SIMD_WIDTH({SIMD_WIDTH})+2"),
        (3, ISSUE_WIS_W + NUM_REGS_BITS + SIMD_WIDTH + 1,
         f"ISSUE_WIS_W({ISSUE_WIS_W})+NUM_REGS_BITS({NUM_REGS_BITS})+SIMD_WIDTH({SIMD_WIDTH})+1"),
    ]

    # ila_commit
    probes["COMMIT"] = [
        (0, 2 * NUM_EX_UNITS * ISSUE_WIDTH + 5,
         f"2*NUM_EX_UNITS({NUM_EX_UNITS})*ISSUE_WIDTH({ISSUE_WIDTH})+5"),
    ]

    # ila_gather
    probes["GATHER"] = [
        (0, 4, "gather_probe0"),
    ]

    # ila_memsched
    probes["MEMSCHED"] = [
        (0, 12, "memsched_probe0"),
    ]

    # ila_lsu
    probes["LSU"] = [
        (0, 25, "lsu handshakes"),
        (1, 2 + UUID_WIDTH + NW_WIDTH + NUM_LSU_LANES + PC_BITS
            + INST_ALU_BITS + INST_ARGS_BITS + 1 + NUM_REGS_BITS
            + 3 * NUM_LSU_LANES * XLEN + PID_WIDTH_LSU + 2,
         f"2+UUID_WIDTH({UUID_WIDTH})+NW_WIDTH({NW_WIDTH})+NUM_LSU_LANES({NUM_LSU_LANES})"
         f"+PC_BITS({PC_BITS})+INST_ALU_BITS({INST_ALU_BITS})+INST_ARGS_BITS({INST_ARGS_BITS})"
         f"+1+NUM_REGS_BITS({NUM_REGS_BITS})+3*NUM_LSU_LANES*XLEN({3 * NUM_LSU_LANES * XLEN})"
         f"+PID_WIDTH_LSU({PID_WIDTH_LSU})+2"),
        (2, 2 + NUM_LSU_LANES + 1
            + NUM_LSU_LANES * LSU_ADDR_WIDTH
            + NUM_LSU_LANES * LSU_WORD_SIZE * 8
            + NUM_LSU_LANES * LSU_WORD_SIZE
            + NUM_LSU_LANES * MEM_FLAGS_WIDTH
            + LSU_TAG_WIDTH,
         f"2+NUM_LSU_LANES({NUM_LSU_LANES})+1"
         f"+lanes*LSU_ADDR_WIDTH({NUM_LSU_LANES}*{LSU_ADDR_WIDTH})"
         f"+lanes*LSU_WORD_SIZE*8({NUM_LSU_LANES}*{LSU_WORD_SIZE * 8})"
         f"+lanes*LSU_WORD_SIZE({NUM_LSU_LANES}*{LSU_WORD_SIZE})"
         f"+lanes*MEM_FLAGS_WIDTH({NUM_LSU_LANES}*{MEM_FLAGS_WIDTH})"
         f"+LSU_TAG_WIDTH({LSU_TAG_WIDTH})"),
        (3, 2 + NUM_LSU_LANES
            + NUM_LSU_LANES * LSU_WORD_SIZE * 8
            + LSU_TAG_WIDTH,
         f"2+NUM_LSU_LANES({NUM_LSU_LANES})"
         f"+lanes*LSU_WORD_SIZE*8({NUM_LSU_LANES}*{LSU_WORD_SIZE * 8})"
         f"+LSU_TAG_WIDTH({LSU_TAG_WIDTH})"),
    ]

    return probes


def write_tcl(probes, args, path):
    """Write TCL variable file with ILA probe widths."""
    cfg = parse_configs(args.configs)
    lines = []
    lines.append("# Auto-generated by gen_ila_params.py — do not edit manually")
    lines.append(f"# Config: XLEN={args.xlen} NUM_WARPS={cfg['num_warps']} "
                 f"NUM_THREADS={cfg['num_threads']} SIMD_WIDTH={cfg['simd_width']} "
                 f"FPU={int(cfg['fpu'])} TCU={int(cfg['tcu'])} "
                 f"LMEM={int(cfg['lmem'])} SCOPE={int(args.scope)}")
    lines.append("")

    for ila_name, probe_list in probes.items():
        num_probes = len(probe_list)
        lines.append(f"set ILA_{ila_name}_NUM_PROBES {num_probes}")
        for probe_idx, width, comment in probe_list:
            lines.append(f"# {ila_name} probe{probe_idx}: {comment} = {width}")
            lines.append(f"set ILA_{ila_name}_PROBE{probe_idx}_WIDTH {width}")
        lines.append("")

    content = "\n".join(lines)

    # Only overwrite if content changed (avoid unnecessary rebuilds).
    try:
        with open(path, "r") as f:
            if f.read() == content:
                return
    except FileNotFoundError:
        pass

    with open(path, "w") as f:
        f.write(content)
    print(f"Generated: {path}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate ILA probe width parameters for package_kernel.tcl")
    parser.add_argument("-o", required=True, metavar="FILE",
                        help="Output TCL file path")
    parser.add_argument("--xlen", type=int, default=64,
                        help="XLEN value (default: 64)")
    parser.add_argument("--configs", default="",
                        help="Raw CONFIGS string with -D flags")
    parser.add_argument("--scope", action="store_true", default=False,
                        help="Enable scope")
    parser.add_argument("--no-scope", action="store_false", dest="scope",
                        help="Disable scope (default)")
    args = parser.parse_args()

    probes = compute_params(args)
    write_tcl(probes, args, args.o)


if __name__ == "__main__":
    main()
