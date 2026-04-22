#!/usr/bin/env python3
"""Generate vitis.ini dynamically based on build configuration.

Usage:
    gen_vitis_ini.py -o <output_file> [options]

Options:
    -o FILE          Output file path (required)
    --target TARGET  Build target: hw or hw_emu (default: hw)
    --debug LEVEL    Debug level (omit for off, 1=on, etc.)
    --profile        Enable profiling
    --sp SPEC        Memory connectivity (repeatable)
    --hook-dir DIR   Directory containing hook TCL scripts
    --clock-freq MHZ  Kernel clock frequency in MHz (optional)
"""

import argparse
import sys
from collections import OrderedDict


def build_ini(args):
    """Build ini sections as an ordered dict of {section: [lines]}.

    Top-level (section-less) lines use the key None.
    """
    sections = OrderedDict()

    # --- top-level (no section) ---
    # kernel_frequency is a top-level option for PCIe/Alveo platforms.
    # [clock] freqHz is for SoC/embedded platforms and doesn't work on Alveo.
    toplevel = []
    if args.clock_freq:
        toplevel.append(f"kernel_frequency=0:{args.clock_freq}")
    sections[None] = toplevel

    # --- [connectivity] ---
    conn = ["nk=vortex_afu:1:vortex_afu_1"]
    for sp in args.sp:
        conn.append(f"sp={sp}")
    sections["connectivity"] = conn

    # --- [vivado] ---
    vivado = []
    if args.hook_dir:
        hooks = [
            ("INIT_DESIGN", "POST", "post_init_hook.tcl"),
            ("OPT_DESIGN",  "PRE",  "pre_opt_hook.tcl"),
            ("ROUTE_DESIGN", "POST", "post_route_hook.tcl"),
            ("POST_ROUTE_PHYS_OPT_DESIGN", "POST", "post_physopt_hook.tcl"),
        ]
        for step, when, tcl in hooks:
            vivado.append(f"prop=run.impl_1.STEPS.{step}.TCL.{when}={args.hook_dir}/{tcl}")
    if args.target == "hw_emu":
        if args.simulator == "xsim":
            if args.debug:
                vivado.append("prop=fileset.sim_1.xsim.elaborate.debug_level=all")
            vivado.append("prop=fileset.sim_1.xsim.compile.xvlog.more_options={-d XSIM}")
        elif args.simulator == "vcs":
            # VCS tool paths — required by Vitis to locate vlogan/vcs/fsdb PLI.
            if args.vcs_install_dir:
                vivado.append(f"prop=project.__CURRENT__.simulator.vcs_install_dir={args.vcs_install_dir}")
            if args.vcs_simlib_dir:
                vivado.append(f"prop=project.__CURRENT__.compxlib.vcs_compiled_library_dir={args.vcs_simlib_dir}")
            if args.vcs_gcc_dir:
                vivado.append(f"prop=project.__CURRENT__.simulator.vcs_gcc_install_dir={args.vcs_gcc_dir}")
            # vlogan options:
            # - Keep XSIM define for the RTL path that expects Vivado simulation context
            #   (selects native Xilinx FP IP instead of DPI emulation).
            # - -timescale=1ns/1ps prevents LRM 1364-2001 §19.8 (error ITSFM) from
            #   VCS's strict mixed-timescale check.
            # - +v2k is added automatically by Vivado's generated compile.sh.
            # - +define+VCS_FSDB_DUMP (DEBUG only) arms the FSDB dump initializer
            #   in runtime/xrt/vcs_fsdb_init.sv. That SV file is pulled into the
            #   kernel source list by Makefile's SIM_FSDB_SOURCES and packaged
            #   into the kernel .xo; because it binds to vortex_afu (kernel top)
            #   rather than pfm_top_wrapper (platform top), the IP packager
            #   keeps it and vlogan compiles it during sim.
            vlogan_defs = "+define+XSIM"
            if args.debug:
                vlogan_defs += " +define+VCS_FSDB_DUMP"
            vivado.append(f"prop=fileset.sim_1.vcs.compile.vlogan.more_options={{-timescale=1ns/1ps {vlogan_defs}}}")
            if args.debug:
                # -debug_access+all links Verdi PLI into simv so $fsdbDump* system
                # tasks resolve at runtime. -kdb / -lca are intentionally omitted:
                # they require every prior compile stage (vlogan, vhdlan,
                # compile_simlib) to also use -kdb, which Vivado's generated
                # compile.sh does not do. Mixing triggers Error-[ANA-KDB-ICS]
                # "Incompatible VHDL database". -kdb only speeds up Verdi
                # interactive loading; post-sim FSDB analysis works without it.
                vivado.append("prop=fileset.sim_1.vcs.elaborate.vcs.more_options={-debug_access+all}")
    sections["vivado"] = vivado

    # --- [debug] ---
    debug = ["protocol=all"]
    if args.debug and args.target == "hw":
        debug.append("chipscope=vortex_afu_1")
    sections["debug"] = debug

    # --- [profile] ---
    profile = []
    if args.profile:
        profile.append("data=all:all:all")
        profile.append("stall=all:all:all")
    sections["profile"] = profile

    # --- [advanced] ---
    advanced = []
    if args.target == "hw_emu" and args.debug:
        advanced.append("param=hw_emu.enableProtocolChecker=true")
        advanced.append("param=hw_emu.scDebugLevel=waveform_and_log")
    if args.target == "hw_emu" and args.simulator == "vcs":
        # Officially supported since Vitis 2024.1 (UG1393 "Working with Simulators
        # in Hardware Emulation"); selects Synopsys VCS as the RTL simulator for
        # v++ hw_emu builds instead of the default xsim.
        advanced.append("param=hw_emu.simulator=VCS")
        advanced.append("param=project.alignLibraryPathEnvForVCS=true")
    sections["advanced"] = advanced

    return sections


def write_ini(sections, path):
    """Write sections dict to an ini file.

    Entries under the None key are written as top-level lines (no section header).
    """
    lines = []
    for section, entries in sections.items():
        if not entries:
            continue
        if section is not None:
            lines.append(f"[{section}]")
        for entry in entries:
            lines.append(entry)
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
    parser = argparse.ArgumentParser(description="Generate vitis.ini for v++ link")
    parser.add_argument("-o", required=True, metavar="FILE", help="Output file path")
    parser.add_argument("--target", default="hw", choices=["hw", "hw_emu"])
    parser.add_argument("--debug", default=None, nargs="?", const="1",
                        help="Debug level (omit for off)")
    parser.add_argument("--profile", action="store_true")
    parser.add_argument("--sp", action="append", default=[], metavar="SPEC",
                        help="Memory connectivity spec (repeatable)")
    parser.add_argument("--hook-dir", default=None, metavar="DIR")
    parser.add_argument("--clock-freq", default=None, metavar="MHZ",
                        help="Kernel clock frequency in MHz")
    parser.add_argument("--simulator", default="xsim", choices=["xsim", "vcs"],
                        help="RTL simulator for hw_emu (default: xsim)")
    parser.add_argument("--vcs-install-dir", default=None, metavar="DIR",
                        help="VCS bin/ directory (required when --simulator=vcs)")
    parser.add_argument("--vcs-simlib-dir", default=None, metavar="DIR",
                        help="Output of compile_simlib -simulator vcs (required when --simulator=vcs)")
    parser.add_argument("--vcs-gcc-dir", default=None, metavar="DIR",
                        help="GCC bin/ directory compatible with VCS (required when --simulator=vcs)")
    args = parser.parse_args()

    sections = build_ini(args)
    write_ini(sections, args.o)


if __name__ == "__main__":
    main()
