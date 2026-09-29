# BRAM/URAM selection port results

Ported the numeric RAM selectors from feat/gemv commit `72045e5a2` onto
current base `5745b94cd`. The source patch does not apply cleanly: this
branch has no `VX_gemm_acc_internal`, different config context, and a
different TMEM implementation. Only the relevant four RTL files were adapted;
no source-branch DMA, ACC architecture, profile or floorplan changes were imported.

| Selector | Default | SRAM instance |
|---|---:|---|
| LMEM_USE_URAM | 0 | VX_local_mem local-memory banks |
| GEMM_ACC_USE_URAM | 0 | VX_gemm_unit internal ACC banks |
| TMEM_USE_URAM | 0 | VX_tensor_mem_bank.sp_ram (bank parameter override supported) |

Values are numeric: 0 requests BRAM, 1 requests URAM. All three memories
default to BRAM following the user's subsequent request. Override individual
selectors with `=1` to request URAM. Geometry, read
latency, byte enables and read-first behavior are unchanged. The existing
VX_sp_ram implementation is already identical between branches.

## Verification

Port validation: **9/9 PASS** before the subsequent default-only change.
The captured hashes identify that tested revision. The new all-BRAM defaults
match the explicit all-BRAM configuration already tested above; simulations
were not repeated for the two default-definition edits. Explicit overrides
and memory behavior are unchanged, and `git diff --check` passes.

| Test | Result | Evidence |
|---|---|---|
| final_unit_improve_default | PASS | [log](results/final_unit_improve_default/attempt1.log) |
| final_unit_improve_0 | PASS | [log](results/final_unit_improve_0/attempt1.log) |
| final_unit_improve_1 | PASS | [log](results/final_unit_improve_1/attempt1.log) |
| final_unit_improve_0_synth | PASS | [log](results/final_unit_improve_0_synth/attempt1.log) |
| final_unit_improve_1_synth | PASS | [log](results/final_unit_improve_1_synth/attempt1.log) |
| kernel_improve_0 | PASS | [log](results/kernel_improve_0/attempt1.log) |
| kernel_improve_1 | PASS | [log](results/kernel_improve_1/attempt1.log) |
| kernel_naive_0 | PASS | [log](results/kernel_naive_0/attempt1.log) |
| kernel_naive_1 | PASS | [log](results/kernel_naive_1/attempt1.log) |

The five unit runs cover the default, explicit BRAM/URAM behavioral models,
and BRAM/URAM synthesis RTL arms. Assertions check macro-to-parameter
propagation and USE_URAM_FINAL in synthesis mode; existing transaction tests
cover byte enables, arbitration, tags and response backpressure. The test
Makefile now forwards CONFIGS, matching the source commit.

Four fresh xrt-vcs-sim builds run M=K=N=256, q32, t0, d0, r1:
improve and naive internal ACC, each with all-BRAM and all-URAM settings.
All use GEMM_SLR_PIPELINE to check the previously ported transport together
with the memory selectors. Every application reports PASSED with no fatal
or assertion diagnostic. All four finished within the first 300-second limit.

## Reproduction and preserved failures

Runner: [run_tests.py](run_tests.py). Exact commands/configs/hashes:
[summary.yaml](summary.yaml). It sources captured committed configurations,
configures independent XLEN64 build directories, uses system GCC/G++,
and calls tools/verify_rtl.py for units and ci/run_black.sh xrt-vcs-sim
for kernels. Existing dirty configs with Omega options were preserved.

The first five unit builds failed because the preexisting VCS recipe lacked
an explicit top and elaborated an unused compiled-SRAM unsupported-shape
sentinel as a root. Adding -top $(TOP_MODULE) and explicit system compilers
fixed that harness issue. The kernel top was already explicit and unaffected.
Initial logs remain under results/unit_*; fresh final unit logs are under
results/final_unit_*. The initial campaign exits 1 due to those five archived
failures; the unit rerun exits 0, and the final audit accepts all nine cases.

Use a fresh label when rerunning to preserve previous builds and evidence:

```sh
python3 agent-tasks/memory-ram-selection/run_tests.py --label rerun1
```

No Vivado synthesis/PnR was run. Synthesis-arm RTL simulation establishes
branch selection and behavior, not final BRAM/URAM primitive mapping.
