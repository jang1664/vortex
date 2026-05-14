#!/usr/bin/env python3
"""
Verdi Signal Preference (.rc) File Generator for tb_vcs_xrtsim

Generates a .rc file that adds VX_tmem_subsystem AXI master port signals
(axi_m[0..7]) to the Verdi nWave session. Signals are grouped by AXI
channel (AW / W / B / AR / R) and, within each channel, all 8 port
instances of the same signal are placed consecutively
(e.g. 8x aw_valid, then 8x aw_ready, ...).

Usage:
    python gen_verdi_rc.py -o signals.rc --fsdb path/to/file.fsdb

===============================================================================
Verdi .rc File Syntax Reference
===============================================================================

  Magic 271485                          ; Required magic number
  Revision Verdi_R-2020.12-SP1
  openDirFile -d / "" "path/to.fsdb"    ; Open waveform database
  activeDirFile "" "path/to.fsdb"       ; Set active file
  viewPort <x> <y> <w> <h> <sigW> <valW>
  signalSpacing <px>
  zoom <start> <end>
  cursor <time>
  marker <time>

  addGroup "<name>" -c <color> -e FALSE     ; Collapsed group with color
  addSubGroup "<name>" -e FALSE             ; Collapsed sub-group
  endSubGroup "<name>"

  addSignal -h 15 /full/hier/sig            ; Sets the current scope
  addSignal -h 15 -holdScope sig            ; Reuses previous scope
  addSignal -h 15 -UNSIGNED -holdScope sig  ; Display as unsigned
  addSignal -h 15 -UNSIGNED -HEX -holdScope sig  ; Hex display
"""

import argparse


# ============================================================================
# Hierarchy
# ============================================================================
TB_PREFIX = (
    "/tb_vcs_xrtsim/dut/vortex_axi/vortex"
    "/g_clusters[0]/cluster"
    "/g_sockets[0]/socket"
    "/g_cores[0]/core"
    "/gemm_node"
)

TMEM_BASE = f"{TB_PREFIX}/u_tmem_subsystem"
NUM_AXI_PORTS = 8


# ============================================================================
# AXI signal definitions (per AXI_BUS interface)
# ============================================================================
# Each entry: (sub_field_name, fmt)
#   fmt: None  -> 1-bit, default display
#        "HEX" -> multi-bit, display as -UNSIGNED -HEX
#
# AXI_USER_WIDTH = 1 in VX_tmem_subsystem, so *_user signals are 1-bit.

AW_SIGNALS = [
    ("aw_valid",  None),
    ("aw_ready",  None),
    ("aw_id",     "HEX"),
    ("aw_addr",   "HEX"),
    ("aw_len",    "HEX"),
    ("aw_size",   "HEX"),
    ("aw_burst",  "HEX"),
    ("aw_lock",   None),
    ("aw_cache",  "HEX"),
    ("aw_prot",   "HEX"),
    ("aw_qos",    "HEX"),
    ("aw_region", "HEX"),
    ("aw_atop",   "HEX"),
    ("aw_user",   None),
]

W_SIGNALS = [
    ("w_valid", None),
    ("w_ready", None),
    ("w_data",  "HEX"),
    ("w_strb",  "HEX"),
    ("w_last",  None),
    ("w_user",  None),
]

B_SIGNALS = [
    ("b_valid", None),
    ("b_ready", None),
    ("b_id",    "HEX"),
    ("b_resp",  "HEX"),
    ("b_user",  None),
]

AR_SIGNALS = [
    ("ar_valid",  None),
    ("ar_ready",  None),
    ("ar_id",     "HEX"),
    ("ar_addr",   "HEX"),
    ("ar_len",    "HEX"),
    ("ar_size",   "HEX"),
    ("ar_burst",  "HEX"),
    ("ar_lock",   None),
    ("ar_cache",  "HEX"),
    ("ar_prot",   "HEX"),
    ("ar_qos",    "HEX"),
    ("ar_region", "HEX"),
    ("ar_user",   None),
]

R_SIGNALS = [
    ("r_valid", None),
    ("r_ready", None),
    ("r_id",    "HEX"),
    ("r_data",  "HEX"),
    ("r_resp",  "HEX"),
    ("r_last",  None),
    ("r_user",  None),
]

AXI_CHANNELS = [
    ("AW channel", AW_SIGNALS),
    ("W channel",  W_SIGNALS),
    ("B channel",  B_SIGNALS),
    ("AR channel", AR_SIGNALS),
    ("R channel",  R_SIGNALS),
]


# ============================================================================
# RC file generation
# ============================================================================

def addsignal_line(path, fmt, height=15):
    """Format an addSignal line for a full hierarchical path."""
    flags = ""
    if fmt == "HEX":
        flags = " -UNSIGNED -HEX"
    elif fmt == "UNSIGNED":
        flags = " -UNSIGNED"
    return f"addSignal -h {height}{flags} {path}"


def emit_axi_signals(lines):
    """Emit the tmem_subsystem AXI master signal group."""
    lines.append('addGroup "tmem_subsystem axi_m[0..7]" -c ID_BLUE4 -e FALSE')

    for ch_name, sig_list in AXI_CHANNELS:
        lines.append(f'addSubGroup "{ch_name}" -e FALSE')
        for sig_name, fmt in sig_list:
            # 8 ports grouped consecutively for each signal
            for i in range(NUM_AXI_PORTS):
                path = f"{TMEM_BASE}/axi_m[{i}]/{sig_name}"
                lines.append(addsignal_line(path, fmt))
        lines.append(f'endSubGroup "{ch_name}"')


def generate_rc(fsdb_path: str) -> str:
    """Generate the full .rc file content."""
    lines = []

    # Header
    lines.append("Magic 271485")
    lines.append("Revision Verdi_R-2020.12-SP1")
    lines.append("")
    lines.append("; Window Layout <x> <y> <width> <height> <signalwidth> <valuewidth>")
    lines.append("viewPort 0 25 2560 1250 350 330")
    lines.append("")
    lines.append("; File list:")
    lines.append(f'openDirFile -d / "" "{fsdb_path}"')
    lines.append("")
    lines.append("; signal spacing:")
    lines.append("signalSpacing 5")
    lines.append("")
    lines.append("; waveform viewport range")
    lines.append("zoom 0.000000 1000000.000000")
    lines.append("cursor 0.000000")
    lines.append("marker 0.000000")
    lines.append("")
    lines.append("COMPLEX_EVENT_BEGIN")
    lines.append("COMPLEX_EVENT_END")
    lines.append("")
    lines.append("curSTATUS ByChange")
    lines.append("")

    # Active file
    lines.append(f'activeDirFile "" "{fsdb_path}"')
    lines.append("")

    # Signals
    emit_axi_signals(lines)
    lines.append("")

    # Footer
    lines.append("")
    lines.append("GETSIGNALFORM_SCOPE_HIERARCHY_BEGIN")
    lines.append('getSignalForm close')
    lines.append("GETSIGNALFORM_SCOPE_HIERARCHY_END")
    lines.append("")
    lines.append("FILTER_SIGNAL_BEGIN")
    lines.append('""')
    lines.append("FILTER_STRING_LIST_BEGIN")
    lines.append("FILTER_STRING_LIST_END")
    lines.append("FILTER_TYPE_LIST_BEGIN")
    lines.append('"All"')
    lines.append('"Input"')
    lines.append('"Output"')
    lines.append('"Inout"')
    lines.append('"Net"')
    lines.append('"Register"')
    lines.append("FILTER_TYPE_LIST_END")
    lines.append("FILTER_SIGNAL_END")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Generate Verdi .rc file with VX_tmem_subsystem AXI master signals",
    )
    parser.add_argument("-o", "--output", required=True, help="Output .rc file path")
    parser.add_argument("--fsdb", default="REPLACE_WITH_FSDB_PATH.fsdb",
                        help="Path to FSDB file (default: placeholder)")

    args = parser.parse_args()

    content = generate_rc(fsdb_path=args.fsdb)

    with open(args.output, "w") as f:
        f.write(content)

    print(f"Generated {args.output}")
    print(f"  FSDB: {args.fsdb}")
    print(f"  Base: {TMEM_BASE}")
    print(f"  Ports: axi_m[0..{NUM_AXI_PORTS - 1}]")
    return 0


if __name__ == "__main__":
    exit(main())
