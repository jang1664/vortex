# GEMM Node Nonuniform QDIR Debug Report

Date: 2026-08-08
Baseline commit: `e1b2188ff2bdae8d2a46186ebd7c9effaa19cb78`
Result: complete; simple testbench coding error corrected; no production RTL fix

## Executive Summary

`gemm_node_improve` did **not** use
`tests/regression/fpint_gemm_ffn_hw/main.cpp`. It used the independent
SystemVerilog testbench
`hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`. The XRT-VCS
blackbox flow is the flow that compiled and ran `main.cpp`.

The existing SystemVerilog type-3 vectors were nonuniform in input, weight,
and scale, but they did not represent the application's full quantization
parameter dependence. QCOL scale/zero were replicated across K groups and
QROW scale/zero were replicated across K rows. A named
`+MAIN_CPP_NONUNIFORM` profile was added with the exact application formulas,
full QDIR-specific arrays, and the QDIR=1 FP16-RNE arithmetic boundary.

That work exposed one simple testbench coding bug: QCOL scale and zero-point
data were serialized as `[group][cur_n]`, while the application and FSM
contract is `[nb][group][MXU_NT]`. The writer loop order was corrected. No
production RTL was changed for this task, and no architectural incompatibility
was found.

Both focused directions, all 54 existing QCOL/QROW regression cases, and all
four XRT-VCS application workloads passed.

## Exact Vector Contract

```text
A[m,k] = fp16_rne(1 + ((m+k)%3)/100)
W[k,n] = ((k*N+n)%7)-3

QDIR=0:
  scale[kg,n] = fp16_rne(1 + ((n+kg)%3)/100)
  zero[kg,n]  = ((n+kg)%7)-3
  sum += A * (W-zero) * scale

QDIR=1:
  scale[k,ng] = fp16_rne(1 + ((ng+k)%3)/100)
  zero[k,ng]  = ((ng+k)%7)-3
  sum += fp16_rne(A*scale) * (W-zero)
```

The testbench emits `MAIN_CPP_NONUNIFORM_PROFILE`, `SOURCE_PASS`,
`TILED_PASS`, and `OUTPUT_PASS` markers. A negative test proved that a focused
`TEST=MAINCPP_NONUNIFORM_*` name without the profile plusarg fails at time 0,
before job allocation.

## Root Cause and Classification

Classification: **simple coding error in test-only QCOL serialization**.

For `cur_k=128`, `QBLK=32`, `cur_n=128`, the QCOL slot contains four K groups
and four 32-column `nb` blocks. The consumer contract is:

```text
nb0: group0 n0..31, group1 n0..31, group2 n0..31, group3 n0..31
nb1: group0 n32..63, group1 n32..63, ...
```

The old writer emitted:

```text
group0 n0..127, group1 n0..127, group2 n0..127, group3 n0..127
```

At byte offset 64, the consumer therefore expects `(nb0,kg1,n0)`. Under the
application formula that value is scale `0x3c0a` and zero `-2`. The old writer
instead placed `(kg0,n32)`, scale `0x3c14` and zero `1`.

The existing type-3 profile masked this because its scale depends only on
`n % 4`, is replicated across K groups, and its zero-point is always zero.
Both flattened orders consequently produced the same repeating bytes. The
application's `(n+kg)` dependence made the two coordinates distinguishable.

This required only a writer loop-order correction. The XRT-VCS QDIR=0
application passed without any production change, independently confirming
that the production application/FSM contract was already correct.

The other test-only gap was reference fidelity: the legacy generic reference
uses one common multiplication expression, whereas `main.cpp` and QROW RTL
round `A*scale` to FP16 before applying `W-zero`. The new named profile uses a
local RNE conversion and preserves all legacy reference behavior.

## Changed Files

- `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`
  - added explicit application-matching vector/reference profile;
  - added source, INT4, tiled-layout, footprint, slot, and output sentinels;
  - corrected QCOL scale/zero writer order universally to
    `[nb][group][MXU_NT]`;
  - added profile activation negative guard.
- `docs/future_optim/gemv/gemm_improve/gemm_node_nonuniform_debug.md`
  - authoritative execution plan.
- `agent-tasks/gemm-node-nonuniform-debug/`
  - confirmed spec, STATUS ledger, this report, and preserved evidence.

No production RTL file was changed by this task. Existing unrelated DMA
worktree changes were preserved. `VX_dma_unit_misal.sv` remained at SHA-256
`1fcf0015b791779e6a5fc94f0b3db4791f1bd2d3bcdc41ae435455971ae53f57`.

## VCS Results

### Existing type-3 baseline

| QDIR | Shape | Result | Compared | Job done |
|---:|---|---|---:|---:|
| 0 | M4 N256 K256 Q32 WT0 | pass | 1024/1024 | 18335ns |
| 1 | M4 N256 K256 Q32 WT0 | pass | 1024/1024 | 18335ns |

These baselines establish current legacy behavior only; they do not claim
application-profile coverage.

### Focused application-matching profile

| QDIR | Source refs `[0,0]`, `[0,9]` | Tiled evidence | Result |
|---:|---|---|---|
| 0 | `0x55f7`, `0x5001` | input/qparam/output 4096B; slot 1024B; INT4[0] `0xed` | 1024/1024, 0 mismatch |
| 1 | `0x4405`, `0x4523` | input/qparam/output 4096B; slot 1024B; INT4[0] `0xed` | 1024/1024, 0 mismatch |

Focused commands:

```bash
source configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh
CC=/usr/bin/gcc CXX=/usr/bin/g++ /usr/bin/python3 tools/verify_rtl.py unittest \
  --path build/hw/unittest/gemm_node_improve --sim vcs --timeout 1200 \
  --params "TEST=MAINCPP_NONUNIFORM_QCOL M=4 N=256 K=256 QBLK=32" \
  --extra-sim-args "+WTRANS=0 +QDIR=0 +MAIN_CPP_NONUNIFORM +NO_WAVE"

CC=/usr/bin/gcc CXX=/usr/bin/g++ /usr/bin/python3 tools/verify_rtl.py unittest \
  --path build/hw/unittest/gemm_node_improve --sim vcs --timeout 1200 \
  --params "TEST=MAINCPP_NONUNIFORM_QROW M=4 N=256 K=256 QBLK=32" \
  --extra-sim-args "+WTRANS=0 +QDIR=1 +MAIN_CPP_NONUNIFORM +NO_WAVE"
```

### Existing regression matrix

| Suite | Shapes | QBLK | WTRANS | Result |
|---|---:|---|---|---|
| QCOL | 5 | 32, 64, 128 | 0, 1 | 30/30 pass |
| QROW | 4 | 32, 64, 128 | 0, 1 | 24/24 pass |

No mismatch, fatal, error, or failed marker was found in the 54 case logs.

## XRT-VCS Application Results

Every run compiled and executed `fpint_gemm_ffn_hw/main.cpp`, completed the
host comparison, printed `PASSED`, and recorded `exit_status=0`.

| M | QDIR | Reference `[0,0]`, `[0,32]` | Jobs | Total/busy cycles | DMA+MXU overlap | Sim time |
|---:|---:|---|---:|---:|---:|---:|
| 4 | 0 | `0x55f7`, `0xcff3` | 256 | 1705 / 8034 | 72.805% | 87,840,000ps |
| 4 | 1 | `0x4405`, `0x400a` | 256 | 1704 / 8035 | 72.850% | 88,160,000ps |
| 256 | 0 | `0x55f7`, `0xcff3` | 16384 | 20729 / 27096 | 92.861% | 285,760,000ps |
| 256 | 1 | `0x4405`, `0x400a` | 16384 | 20730 / 27098 | 92.856% | 292,320,000ps |

Commands:

```bash
ci/run_target_gemm.sh run --wload 8 --m 4   --n 256 --k 256 --qdir 0
ci/run_target_gemm.sh run --wload 8 --m 4   --n 256 --k 256 --qdir 1
ci/run_target_gemm.sh run --wload 8 --m 256 --n 256 --k 256 --qdir 0
ci/run_target_gemm.sh run --wload 8 --m 256 --n 256 --k 256 --qdir 1
```

The first run rebuilt `simv` because RTL/simulator inputs were newer. The
remaining three reused the matching compile fingerprint
`694f87f827364e63ce518c6e993e128f432346682530e2643af1bbe1adde36c1`.

## Evidence Index

- Focused QDIR=0: `evidence/focused-qdir0-iter2/`
- Focused QDIR=1: `evidence/focused-qdir1-iter2/`
- QCOL regression: `evidence/regress-qcol-iter3/`
- QROW regression: `evidence/regress-qrow-iter3/`
- Negative guard: `evidence/profile-guard-iter5/`
- XRT-VCS: `evidence/xrt-*-iter4/`

The evidence tree contains 327 files totaling approximately 3.4 MiB.

## Remaining Risks

- The explicit application-matching profile is intentionally constrained to
  the requested `M=4,N=256,K=256,QBLK=32,WTRANS=0` sentinel shape. The existing
  suites provide broader shape/QBLK/WTRANS regression with their legacy
  vectors, not the exact `main.cpp` profile.
- The profile-local FP16 RNE helper mirrors the current application converter.
  Future changes to one side should update the shared contract or add a direct
  converter equivalence test.
- This task proves correctness, not a performance comparison against a clean
  production-RTL baseline; the worktree already contained separate DMA
  optimization changes.
