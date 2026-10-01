"""Replay the production TB AXI adapter with FSDB off/on and compare timestamps."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from gen_hbm_config import resolve


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    for tool in ("vcs", "make"):
        if not shutil.which(tool): parser.error(f"{tool} is required")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parent
    expected = resolve(os.environ)
    traces = []
    for fsdb in (False, True):
        label = "fsdb" if fsdb else "no_fsdb"
        with (output / f"build_{label}.log").open("w") as log:
            subprocess.run(["make", "-f", str(source / "Makefile"), "hbm-adapter-build",
                            f"DESTDIR={output.parent}", f"FSDB_DUMP={'1' if fsdb else ''}",
                            f"CONFIGS={os.environ['U55C_INPUT_DEFINES']}",
                            f"LOGIC_FREQ_HZ={expected['logic_freq_hz']}",
                            f"HBM_AXI_FREQ_HZ={expected['hbm_axi_freq_hz']}",
                            f"XRT_VCS_PLATFORM={expected['platform']}"],
                           check=True, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        built = json.loads((output.parent / "u55c_model_manifest.json").read_text())
        built.pop("sha256")
        assert built == expected, "Nested build changed requested model configuration"
        result = subprocess.run([str(output / "simv")], cwd=output, capture_output=True,
                                text=True, timeout=60)
        text = result.stdout + result.stderr
        (output / f"replay_{label}.log").write_text(text)
        assert result.returncode == 0 and "HBM_SELFTEST_PASS" in text, text
        assert "Fatal:" not in text and "Error:" not in text, text
        assert "HBM_CREDIT_PASS" in text, text
        assert "HBM_WRITE_CREDIT_PASS" in text, text
        assert "HBM_RESET_PASS" in text, text
        assert "HBM_STROBE_PASS" in text, text
        assert "HBM_PARTIAL_RESET_PASS" in text, text
        assert "HBM_OUTSTANDING_SHUTDOWN_PASS" in text, text
        if fsdb:
            assert "*Verdi* : Create FSDB file" in text, text
            assert (output / "vcs_cosim.fsdb").stat().st_size > 0
        traces.append([line for line in text.splitlines() if line.startswith("HBM_REPLAY ")])
    manifest = json.loads((output.parent / "u55c_model_manifest.json").read_text())
    assert len(traces[0]) == 37 * manifest["kernel_ports"] + 512
    assert traces[0] == traces[1], "FSDB changed accepted AXI timestamps"
    print(f"Production AXI adapter FSDB replay passed: {len(traces[0])} identical handshakes")


if __name__ == "__main__":
    main()
