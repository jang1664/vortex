---
paths: ["hw/unittest/**"]
---

# Testbench Rules

- Test runner: `test.sh` in each test directory. Usage: `./test.sh [mode] [args]`
- Simulator: `SIM_EXEC=vcs` (default) or `SIM_EXEC=vlt` (Verilator)
- GEMM parameters via make: `make run M=32 N=32 K=128 QBLK=32 EXTRA_SIM_ARGS="+WTRANS=0 +QDIR=0"`
- Success criterion: `OUTPUT CHECK PASSED` in simulation log
- New RTL modules must be added to the `RTLS` variable in the test's Makefile
- Test shapes are defined in `test.sh` arrays: QCOL_SHAPES, QROW_SHAPES, QCOL_QBLKS, etc.
- Reference model: `hw/rtl/verification/fpint_emul.sv` (fpint_gemm_ref task)
- FP16 tolerance: ~1.5 LSB (FP16_TOL = 0.01 in testbench)
