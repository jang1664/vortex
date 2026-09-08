"""Compile and exercise the production AXI guard using VCS, not another simulator."""
import argparse
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    vcs = shutil.which("vcs")
    if not vcs:
        parser.error("VCS is required")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parent
    with (output / "compile.log").open("w") as log:
        subprocess.run([vcs, "-full64", "-sverilog", "-timescale=1ns/1ps", str(source / "VX_hbm_axi_guard.sv"),
                        str(source / "tb_hbm_axi_guard.sv"), "-top", "tb_hbm_axi_guard", "-o", "simv"],
                       cwd=output, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    cases = {"valid": None, "ar_size": "AR", "ar_burst": "AR", "ar_boundary": "AR",
             "aw_size": "AW", "aw_align": "AW", "r_stall": "R", "b_stall": "B"}
    for case, channel in cases.items():
        result = subprocess.run([str(output / "simv"), f"+case={case}"], cwd=output,
                                capture_output=True, text=True, timeout=30)
        text = result.stdout + result.stderr
        (output / f"{case}.log").write_text(text)
        if channel:
            assert f"HBM_GUARD_{channel}:" in text and "HBM_GUARD_PASS" not in text, text
        else:
            assert result.returncode == 0 and "HBM_GUARD_PASS" in text and "Fatal" not in text, text
    print(f"VCS AXI guard: {len(cases)} directed cases passed")


if __name__ == "__main__":
    main()
