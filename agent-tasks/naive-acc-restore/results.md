# Selectable naive ACC memory

Implementation and verification completed on 2026-09-29. All six functional
cases and C2 compile/elaboration passed.

## Implementation

Restored the naive internal-ACC path from `f4c65cc86b47c428d5e42526dfbdfa52d1c81a4f`
on top of the current naive RTL. `GEMM_NAIVE_USE_ACC_MEM` selects internal
FP32 accumulation and an explicit FP16 ACC-to-LMEM output copy. With the macro
absent, the current LMEM PSUM and direct FP16 final-output path remains selected.
C2/C3 select ACC ON, with 256 KiB ACC RAM and 2 MiB LMEM.

The restored path retains current bank decoding, effective edge-tile dimensions,
NT-padded output rows, descriptor latching, PSUM tags, and software ABI. ACC
source strides use historical FP32 byte addresses and the naive unit's existing
64-byte output-bus address decoding.

Output completion now waits for actual LMEM RAM writes, not just DMA request
acceptance. The node counts narrow output request handshakes and per-bank write
commits returned through local memory, mem unit, and core. Completion requires
DMA completion, empty split lanes, and zero pending writes. Simulation assertions
check counter accounting, address bounds/alignment, and output-buffer reuse.

## Verification

All functional cases use `fpint_gemm_ffn_hw_naive`, K=N=256, QBLK=32,
and the `ci/run_black.sh xrt-vcs-sim` wrapper in separate configured builds.
PASS requires exit zero, the application's PASS marker, and no RTL assertion
or error lines. C2 compile includes TCU and its normal NDEBUG configuration.

| Configuration | M | Result | Evidence |
|---|---:|---|---|
| C3 ACC ON | 1 | PASS | [application log](../../build_naive_acc_on_vcs/verification/iter05_m1/run.log) |
| C3 ACC ON | 16 | PASS | [application log](../../build_naive_acc_on_vcs/verification/iter05_m16/run.log) |
| C3 ACC ON | 256 | PASS | [application log](../../build_naive_acc_on_vcs/verification/iter06_m256/run.log) |
| C3 ACC OFF | 1 | PASS | [application log](../../build_naive_acc_off_vcs/verification/iter05_m1/run.log) |
| C3 ACC OFF | 16 | PASS | [application log](../../build_naive_acc_off_vcs/verification/iter05_m16/run.log) |
| C3 ACC OFF | 256 | PASS | [application log](../../build_naive_acc_off_vcs/verification/iter06_m256/run.log) |
| C2 ACC ON | compile/elaboration | PASS | [build log](../../build_naive_acc_c2_vcs/verification/iter03_m0/stdout.log) |

Each case directory preserves configuration, command, RTL hashes, source diff,
application/simulator logs, and deterministic verification reports. Earlier
M256 attempts reached the 300-second deadline while making forward progress;
only those cases were retried with 1800 seconds. Earlier verbose-trace attempts
and the initial declaration-order compile error are recorded in [STATUS.yaml](STATUS.yaml).
All seven archived RTL hash maps match the completed source. M256 finished in
382.75 seconds (ON) and 428.11 seconds (OFF), with no assertion/error lines;
these are simulator wall times, not hardware performance measurements.
The [machine-readable summary](../../build_naive_acc_on_vcs/verification/summary.json)
contains per-case hashes and marker counts.

## Reproduction

Use a distinct build directory per ON/OFF/C2 variant. Source the proper config
before configuring and running. For C3 ON, from its build directory:

```bash
source ../configs/th32_c1_naive_m32_tcol32.sh
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export CONFIGS="$CONFIGS -DDBG_TRACE_GEMM -DDEBUG_LEVEL=1"
export VCS_CPPFLAGS=-DDEBUG_LEVEL=1
# This verification reused the existing compiled Xilinx libraries and generated IP.
export SIMLIB_DIR="$PWD/../build/vcs_simlib"
export XILINX_IP_DIR="$PWD/../build/sim/xrtsim_vcs/xilinx_ip"
for m in 1 16 256; do
    ../ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive \
        --args "-m $m -k 256 -n 256 -q 32 -t 0 -d 0 -r 1" --debug 1
done
```

For OFF, remove only `-DGEMM_NAIVE_USE_ACC_MEM` from CONFIGS after sourcing
the same C3 configuration. Use a separately compiled simulator. For C2, source
`th32_c1_tcu_naive_m32_tcol32.sh`, configure a separate build, generate headers
with `make -C hw`, then run `make -C sim/xrtsim_vcs simv` with the same Xilinx
library/IP locations. C2 uses no verification debug defines.

## Scheduling evidence and limits

The FSM emits STORE notification then advances tiles without an explicit wait
for that STORE. Before the next ACC-to-LMEM copy, RID_O waits for the previous
STORE; the final job also waits for all stores. Copy completion notification
follows actual LMEM write drain.

The M256 ON trace contains four alternating COPY_DRAINED/STORE_START pairs:
157235000/157285000, 249905000/249955000, 342555000/342605000, and
434185000/434235000 ps. No compute-during-STORE marker was observed. OFF
traces contain no ACC markers. See the
[trace summary](../../build_naive_acc_on_vcs/verification/summary.md).

This preserves historical naive scheduling; it does not guarantee useful
compute/STORE overlap. If another tile needs prefetch, STORE NOTIFY plus
prefetch I/W/SC can fill the existing depth-four DMA child FIFO. ZP and its
notification then block later compute commands in the ordered parent queue
until STORE releases the DMA. Relevant code is `VX_gemm_fsm_naive.sv:1592`,
`:1622`, `:1651`, `VX_gemm_ctrl_naive.sv:140`, `:202`, `:214`, and
`VX_gemm_dma_ctrl_naive.sv:507`. This behavior also exists in the historical
reference and was not redesigned here. STORE completion and the diagnostic
overlap marker use the existing cache-path DMA descriptor completion signal,
not final physical HBM write completion.

Verification covers RTL functional simulation and C2 elaboration. It does not
establish FPGA timing, resource use, hardware performance, or general edge-shape
coverage beyond the requested cases.
