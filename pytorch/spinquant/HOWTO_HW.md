# Running SpinQuant on the real U55C FPGA

Quick how-to for the helper scripts in this directory. They wrap all the XRT
environment the Vortex path needs and launch through SLURM so you don't collide
with a teammate's board.

## Prerequisites

- Inside the repo (scripts auto-detect the repo root; no path editing needed).
- `conda activate vortex` env with `torch_vortex` installed editable from THIS repo
  (`pip show torch_vortex` → *Editable project location* should point here).
- A free U55C board (`squeue -p fpga` to check; the scripts grab one via `srun`).
- Bitstream: the scripts default to alias `improve_th16_tcol32_hwexp_dcache`
  (`8d9b4939d1`, the "pack16" build with the per-group scale fix). Override with
  `FPGA_BIN_DIR=<dir>` if needed.

## 1. One-shot inference

```bash
./run_spinquant_hw.sh                      # "Once upon a time", 1 token, debug=2
./run_spinquant_hw.sh "Hello there" 8      # custom prompt + max_new_tokens
./run_spinquant_hw.sh "Hello" 1 trace      # + report which ops ran on Vortex vs CPU
```

The model is loaded fresh each run. Loading moves ~4 GB of weights to the board
over XRT and is **slow (~10-15 min)** — this is a known runtime transfer bottleneck,
not your setup.

## 2. Persistent server (load once, many prompts)

Loading is per-process, so to avoid paying it every time, keep one process alive
and feed it prompts:

```bash
./serve_spinquant_hw.sh        # or: ./serve_spinquant_hw.sh 20   (20 tokens/prompt)
```

It loads once, then reads one prompt per line from stdin; blank line / `quit` /
Ctrl-D exits. Every prompt after the first reuses the on-device weights — no reload.
(The board is held for the session; exiting frees it.)

## 3. Verify the kernels / per-group scale fix

```bash
srun -p fpga --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=0:20:00 \
    bash ../run_hw_test.sh mm_w4a16_opt      # W4A16 GEMM, group-varying scales
srun ... bash ../run_hw_test.sh silu         # any native op: silu, rmsnorm, rope, ...
```

Current status on `8d9b4939d1`: `mm_w4a16_opt` = **8/9** (all multi-group cases pass;
one `QBLK=16` edge case still fails).