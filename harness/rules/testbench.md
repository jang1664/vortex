---
paths: ["hw/unittest/**"]
---

# Testbench Rules

- New RTL modules must be added to the `RTLS` variable in the test's Makefile
- All waveform analysis must use **FST format** and the **pywellen** Python library — do NOT parse VCD/FSDB directly
- Before using external tools (`vcd2fst`, `fsdb2vcd`), verify they exist with `which`
