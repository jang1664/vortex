#!/usr/bin/env python3
"""Check adapter parameter rejection from a configured VCS build directory.

A valid control is compiled and simulated first. Every negative case must
either fail elaboration or emit its expected static assertion. Logs are kept.
"""
import pathlib
import subprocess
import sys


def run_case(k, h, expected=None, *, name=None, defines="",
             allow_elaboration_failure=True):
    name = name or f"geometry_k{k}_h{h}"
    log = pathlib.Path("logs") / f"{name}.log"
    compile_log = pathlib.Path("logs") / f"{name}_compile.log"
    binary = f"simv_{name}"
    command = [
        "make", "compile", "SIM_EXEC=vcs",
        "TOP_MODULE=tb_VX_axi_adapter_geometry",
        f"EXTRA_DEFINES=+define+PROBE_K={k}+PROBE_H={h}{defines}",
        f"SIMV={binary}", f"COMPILE_LOG={compile_log}",
    ]
    with log.open("w") as stream:
        compiled = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                  timeout=300, check=False)
        if compiled.returncode == 0:
            result = subprocess.run([f"./{binary}"], stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=30, check=False)
        else:
            result = None
    output = log.read_text()
    if expected is None:
        passed = (result is not None and result.returncode == 0
                  and "GEOMETRY_PROBE_REACHED_END" in output
                  and "Error-" not in output and "Error:" not in output)
    else:
        passed = ((allow_elaboration_failure and compiled.returncode != 0)
                  or (compiled.returncode == 0
                      and any(message in output for message in expected)))
    if not passed:
        print(f"FAIL: {name}; inspect {log}")
        return False
    kind = "valid control" if expected is None else (
        "rejected during elaboration" if compiled.returncode else "rejected by static assertion")
    print(f"CHECK PASSED: {name}: {kind}; log={log}")
    return True


def main():
    if not pathlib.Path("../../../config.mk").is_file():
        sys.exit("Run from hw/unittest/axi_adapter inside a configured build directory")
    pathlib.Path("logs").mkdir(exist_ok=True)
    if not run_case(2, 8):
        return 1
    cases = [
        (3, 8, ["NUM_BANKS_OUT must be a positive power of two", "invalid transport/HBM geometry"]),
        (16, 8, ["invalid transport/HBM geometry"]),
        (1, 3, ["NUM_HBM_PORTS must be a positive power of two", "invalid physical bank/HBM geometry"]),
    ]
    results = [run_case(*case) for case in cases]
    # These formerly accepted shapes elaborate normally. Require the intended
    # assertion explicitly, rather than treating an unrelated compile error as
    # evidence of rejection.
    results.append(run_case(
        2, 8, ["output address width cannot represent the physical HBM map"],
        name="geometry_truncated_physical_address",
        defines="+PROBE_ADDR_IN=26+PROBE_ADDR_OUT=32",
        allow_elaboration_failure=False,
    ))
    results.append(run_case(
        2, 8, ["grouped AXI requires a 64-byte cache line and AXI beat"],
        name="geometry_inconsistent_data_size",
        defines="+PROBE_DATA_WIDTH=1024+PROBE_DATA_SIZE=64",
        allow_elaboration_failure=False,
    ))
    if all(results):
        print("TEST PASSED: invalid grouped AXI geometries rejected")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
