"""Run testbench-driven simulation and PrimePower for VX_gemm_unit_top.

Pipeline:
  1. SimConfig: VCS-compile tb_VX_gemm_unit_top.sv + entire RTL closure with
     +define+SIMULATION, dump tb_VX_gemm_unit_top.power.fsdb to sim/reports/.
  2. PwrConfig: PrimePower reads the mapped netlist (under syn_topo.run1)
     and the FSDB to produce a *report_power.report* with realistic activity.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GEMM_DIR = HERE.parent  # vortex/hw/syn/synopsys/gemm_unit_breakdown
DEFAULT_VORTEX_HOME = HERE.parents[4]
BUILD_DIR = DEFAULT_VORTEX_HOME / "build" / "hw" / "syn" / "synopsys" / "gemm_unit_breakdown"
sys.path.insert(0, str(HERE))

from preprocess import preprocess  # noqa: E402
from run import closure_files, _topo_sort_packages, SKIP_FILENAMES  # noqa: E402

from hwexplorer.automation.sim import SimConfig  # noqa: E402
from hwexplorer.automation.pwr import PwrConfig  # noqa: E402


def _vortex_home():
    home = os.environ.get("VORTEX_HOME")
    if not home and (DEFAULT_VORTEX_HOME / "hw" / "rtl").is_dir():
        home = str(DEFAULT_VORTEX_HOME)
        os.environ["VORTEX_HOME"] = home
    return Path(home).resolve() if home else None


def main(design_name: str = "VX_gemm_unit_top",
         syn_subdir: str = "syn_topo.run1",
         sim_subdir: str = "sim",
         pwr_subdir: str = "pwr.run1"):
    """design_name = `VX_gemm_unit_top` (WKV) or `VX_woq_gemm_unit_top` (WoQ).
    The TB / DUT instance names are derived as `tb_<design>` / `u_<design>`."""
    pre = preprocess()
    vortex = _vortex_home()
    patched_fpnew_pkg = vortex / "hw" / "rtl" / "fpu" / "patched_cvfpu" / "fpnew_pkg.sv"

    tb_top = f"tb_{design_name}"
    tb_filename = f"{tb_top}.sv"

    sources = []
    skipped, swapped = [], 0
    for f in pre.files:
        name = Path(f).name
        if name in SKIP_FILENAMES:
            skipped.append(f)
            continue
        if name == "fpnew_pkg.sv" and patched_fpnew_pkg.exists():
            sources.append(str(patched_fpnew_pkg))
            swapped += 1
        else:
            sources.append(f)

    tb_path = vortex / "hw" / "rtl" / "patch" / tb_filename
    if str(tb_path) not in sources:
        sources.append(str(tb_path))

    needed = closure_files(tb_top, sources)
    sources = [f for f in sources if f in needed]

    pkg_files, other_files = [], []
    for f in sources:
        from run import _declares_package
        if Path(f).name.endswith("_pkg.sv") or _declares_package(Path(f)):
            pkg_files.append(f)
        else:
            other_files.append(f)
    pkg_files = _topo_sort_packages(pkg_files)
    sources = pkg_files + other_files
    print(f"[run_sim_power] design={design_name}  {len(sources)} files for sim "
          f"({len(pkg_files)} pkg, {len(other_files)} other)")

    sim_dir = BUILD_DIR / "syn" / "run" / "v0"
    sim = SimConfig(
        target_path=str(sim_dir),
        target_dir=sim_subdir,
        rtl=sources,
        libs=[],
        define_list=[
            ("SYNTHESIS", ""),
            ("FPU_FPNEW", ""),
            ("VIVADO", ""),
            ("NDEBUG", ""),
        ],
        inc_dirs=[str(pre.preproc_dir)] + list(pre.incdirs),
        lib_paths=["/tool/Program/synopsys/syn_vS-2021.06-SP5-2/dw/sim_ver"],
        delay_options=["+delay_mode_zero"],
        rerun=True,
    )
    sim.print()
    sim.run()

    pwr = PwrConfig(
        target_path=str(sim_dir),
        target_dir=pwr_subdir,
        module_name=design_name,
        sim_root=str(sim_dir / sim_subdir),
        fsdb_fname=f"{tb_top}.power.fsdb",
        tb_name=tb_top,
        dut_name=f"u_{design_name}",
        syn_dir=str(sim_dir / syn_subdir),
        new=True,
        rerun=True,
    )
    pwr.print()
    pwr.run()


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--design-name", default="VX_gemm_unit_top",
                    choices=["VX_gemm_unit_top", "VX_woq_gemm_unit_top"])
    args = ap.parse_args()
    is_woq = args.design_name == "VX_woq_gemm_unit_top"
    main(
        design_name=args.design_name,
        syn_subdir="syn_topo_woq.run1" if is_woq else "syn_topo.run1",
        sim_subdir="sim_woq" if is_woq else "sim",
        pwr_subdir="pwr_woq.run1" if is_woq else "pwr.run1",
    )
