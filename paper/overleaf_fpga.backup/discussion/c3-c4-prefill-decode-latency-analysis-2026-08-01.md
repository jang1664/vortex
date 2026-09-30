# C3 Prefill/Decode GEMM--Vector Latency: Complexity and MXU Utilization

## Summary

Complexity alone does **not** predict a large difference between the GEMM/vector ratios of prefill and decode. After factoring out the number of processed query rows, both stages have the same two terms:

1. token-local work for projections, MLPs, and vector kernels; and
2. attention work proportional to the number of query--key pairs.

The measured difference---GEMMs occupy 19.80% of C3 prefill latency but 64.81% of C3 decode latency---appears after converting operation counts into latency. Prefill exposes large GEMMs and uses the MXU efficiently. Decode presents skinny projection and attention GEMMs, so low MXU utilization makes their latency disproportionately large. Vector kernels, including R4 Hadamard, still run in decode.

## Notation

The equations are per model and include all $L$ decoder layers.

| Symbol | Meaning |
|---|---|
| $B$ | Batch size |
| $P$ | Prefill sequence length or initial decode KV-cache length |
| $T$ | Number of generated tokens; $T=128$ in the evaluation |
| $d$ | Hidden dimension |
| $f$ | MLP intermediate dimension |
| $H_q,H_{kv}$ | Query-head and KV-head counts |
| $r$ | Head dimension; $d=H_qr$ and $d_{kv}=H_{kv}r$ |
| $A$ | Token-local GEMM MACs per query row |
| $C_{tok}$ | Token-local vector work per query row |
| $c_{sm}$ | Effective vector work per attention score for softmax |

The Q/K/V/O projections and three MLP GEMMs give

$$
A = 2d^2 + 2dd_{kv} + 3df.
$$

Here, $2d^2$ is Q plus O, $2dd_{kv}$ is K plus V, and $3df$ is gate, up, and down. Biases and small constant terms are omitted.

$C_{tok}$ combines the vector kernels whose work follows the newly processed query rows: RMSNorm, RoPE, residual operations, SiLU, elementwise multiplication, R3/R4 Hadamard, KV update/quantization, and head concatenation. Its exact constants depend on the kernel implementation. A useful form is

$$
C_{tok}=\Theta\!\left(d+f+C_{R4}(f)+(H_q+H_{kv})r\log r\right).
$$

## Complexity-Only Model

It is useful to define two counts for each stage:

- $Q_s$: number of newly processed query rows;
- $S_s$: number of query--key pairs processed by attention.

The GEMM and vector work can then be written in one common form:

$$
G_s = L\left(Q_sA+2dS_s\right),
$$

$$
V_s = L\left(Q_sC_{tok}+c_{sm}H_qS_s\right).
$$

The first term is token-local. The second is attention: QK$^T$ and PV together require approximately $2d$ MACs per query--key pair, while softmax performs vector work on $H_q$ scores per token pair.

### Prefill

Prefill processes all $BP$ prompt rows and constructs a $P\times P$ score matrix:

$$
Q_{pf}=BP, \qquad S_{pf}=BP^2.
$$

Therefore,

$$
G_{pf}=LB\left(PA+2P^2d\right),
$$

$$
V_{pf}=LB\left(PC_{tok}+c_{sm}H_qP^2\right).
$$

After canceling $LBP$, the operation-count ratio is

$$
\frac{G_{pf}}{V_{pf}}
=\frac{A+2Pd}{C_{tok}+c_{sm}H_qP}.
$$

### Decode

At decode step $t$, each sequence produces one new query and attends to approximately $P+t$ cached positions. Across $T$ steps,

$$
Q_{dec}=BT,
$$

$$
S_{dec}=B\sum_{t=1}^{T}(P+t)
=B\left(TP+\frac{T(T+1)}{2}\right).
$$

Let the average attended length be

$$
\bar P=P+\frac{T+1}{2}.
$$

Then

$$
G_{dec}=LBT\left(A+2\bar P d\right),
$$

$$
V_{dec}=LBT\left(C_{tok}+c_{sm}H_q\bar P\right),
$$

and

$$
\frac{G_{dec}}{V_{dec}}
=\frac{A+2\bar P d}{C_{tok}+c_{sm}H_q\bar P}.
$$

### What the complexity equations say

The prefill and decode ratios have the same structure; decode merely replaces $P$ with the average cache length $\bar P$. Batch size, layer count, and the number of generated tokens cancel from the ratio. In the attention-dominated limit, both ratios approach

$$
\frac{2d}{c_{sm}H_q}=\frac{2r}{c_{sm}}.
$$

Thus, operation complexity alone cannot explain why the measured C3 GEMM latency fraction changes from 19.80% in prefill to 64.81% in decode. A hardware-efficiency term is required.

## Adding MXU Utilization

Separate GEMM work into token-local and attention terms:

$$
G_s^{lin}=LQ_sA, \qquad G_s^{attn}=2LdS_s.
$$

Let $R_M$ be peak MXU MAC throughput and let $u_{lin,s}$ and $u_{attn,s}$ be the achieved utilization for the two shape classes. The GEMM time is

$$
t_{G,s}
=\frac{G_s^{lin}}{R_Mu_{lin,s}}
+\frac{G_s^{attn}}{R_Mu_{attn,s}}.
$$

Define a work-weighted effective utilization $u_s$ by

$$
\frac{1}{u_s}
=\frac{G_s^{lin}}{G_s}\frac{1}{u_{lin,s}}
+\frac{G_s^{attn}}{G_s}\frac{1}{u_{attn,s}}.
$$

This gives the simplified GEMM time

$$
t_{G,s}=\frac{G_s}{R_Mu_s}.
$$

Let $R_{V,s}$ be the effective vector throughput, including the costs of reductions, exponentials, memory access, and vector-kernel shape efficiency:

$$
t_{V,s}=\frac{V_s}{R_{V,s}}.
$$

The GEMM fraction of end-to-end compute latency is therefore

$$
F_{G,s}
=\frac{t_{G,s}}{t_{G,s}+t_{V,s}}
=\frac{1}
{1+\dfrac{V_s}{G_s}\dfrac{R_Mu_s}{R_{V,s}}}.
$$

This equation captures the measured direction:

- Large prefill GEMMs have high $u_{pf}$. Their many MACs complete quickly, reducing their latency fraction $F_{G,pf}$.
- Skinny decode GEMMs have low $u_{dec}$. Their effective throughput $R_Mu_{dec}$ falls, increasing $F_{G,dec}$ even if $G_{dec}/V_{dec}$ is similar at the operation-count level.

Fixed launch, tiling, padding, and operand-delivery costs can be folded into the empirical $u_s$. If vector efficiency also changes strongly by stage, that effect remains in $R_{V,s}$; the simplified first-order explanation assumes the dominant stage-dependent change is MXU utilization.

## Why Decode Underutilizes the C3 MXU

The generated workload shapes make the utilization difference explicit:

- Prefill projection/MLP GEMMs use $M=BP=P$ in this evaluation, with $P=1{,}024\ldots32{,}768$.
- Decode projection/MLP GEMMs use only $M=B=1,4,64$.
- Prefill QK$^T$/PV GEMMs use query dimension $M=P$.
- Decode QK$^T$/PV use $M=H_q/H_{kv}$ per grouped attention call because `seq_q=1`; this is a small fixed dimension, while separate calls cover the batch and KV heads.

These skinny decode shapes leave rows or columns of the fixed-size MXU idle and make fixed overheads harder to amortize. The measured batch trend supports this interpretation: C3 GEMMs occupy 78.50% of decode latency at batch 1 but 49.94% at batch 64. Increasing batch supplies more independent projection rows and improves amortization, so the vector fraction rises.

Longer context produces a second effect inside decode. From 1K to 32K, the C3 GEMM fraction rises from 57.62% to 71.92%, and the PV fraction rises from 8.51% to 37.00%. R4 and other token-local vector work remain proportional to $TB$, whereas cache-scanning attention work grows with $TB\bar P$.

## R4 Hadamard in Both Stages

R4 Hadamard runs after the MLP elementwise multiplication and before the down projection in both stages. The generator sets

$$
R=B\,\texttt{seq\_q},
$$

so its row counts per layer are

$$
R_{pf}=BP, \qquad R_{dec,total}=BT.
$$

The default C3 implementation factorizes the non-power-of-two intermediate dimension as $f=KW$, with power-of-two $W$. Per row it performs a Walsh--Hadamard butterfly and a dense $K\times K$ base transform:

$$
C_{R4}(f)
=\Theta(f\log_2W)+\Theta(WK^2)
=\Theta\!\left(f(\log_2W+K)\right).
$$

| Model | $f=KW$ | Per-row order |
|---|---:|---:|
| Llama 2 7B | $11{,}008=172\times64$ | $\Theta(f(6+172))$ |
| Llama 3 8B | $14{,}336=28\times512$ | $\Theta(f(9+28))$ |

For $T=128$, decode processes 128, 512, and 8,192 R4 rows per layer at batches 1, 4, and 64. Prefill processes 1,024--32,768 rows per layer. R4 is therefore much smaller in small-batch decode, but it is not absent and can exceed short-context prefill at batch 64.

The measured R4 fractions are consistent with these counts:

- Prefill: 32.83% on average, decreasing from 46.37% at 1K to 14.84% at 32K.
- Decode: 6.95% on average, decreasing from 10.78% at 1K to 2.70% at 32K.

The decode fraction decreases with context because $BT$ is independent of cache length, while QK$^T$, PV, and softmax grow with $BT\bar P$.

## Connection to the C3--C4 Results

The workload-level measurements contain 12 prefill cases and 36 decode cases across Llama 2 7B and Llama 3 8B.

| Metric | Prefill | Decode |
|---|---:|---:|
| C3 GEMM latency fraction | 19.80% | 64.81% |
| C3 vector latency fraction | 80.20% | 35.19% |
| GEMM-only C3/C4 | 1.759x | 2.231x |
| End-to-end C3/C4 | 1.055x | 1.537x |

Prefill's vector fraction is dominated by softmax and R4 Hadamard, averaging 38.08% and 32.83% of C3 latency. Decode still executes both kernels, but their average fractions are 11.46% and 6.95%; underutilized GEMMs occupy more of the latency denominator. C4 consequently removes a much larger exposed latency component in decode.

`Layout` is separate from this C3 complexity model. In the plotted breakdown it is the positive incremental cost of each C4 layout-fused vector kernel relative to its C3 counterpart:

$$
\text{Layout}=\sum_k\max\left(0,t_{C4,k}^{fused}-t_{C3,k}^{base}\right).
$$

It averages 4.72% of C4 prefill latency and 3.01% of C4 decode latency, so it does not drive the stage difference.

## Concise Paper Explanation

> Although prefill and decode have similar GEMM-to-vector operation-count ratios, their realized latency ratios differ because decode presents skinny GEMMs that underutilize the C3 MXU. GEMMs therefore account for 64.81% of C3 decode latency but only 19.80% in prefill, where efficiently executed GEMMs expose softmax and R4 Hadamard as the dominant bottlenecks. C4 accelerates this larger exposed GEMM component, yielding a larger end-to-end gain in decode.

## Data Sources

The values were recomputed from the `figure_prepare.C3_C4_v3` name/backend-stacked E2E CSVs for Llama 2 7B and Llama 3 8B and cross-checked against:

- `/home/jaeyongjang/project.local/vortex_fpint/analysis_workspace/latency_on_hw/outputs_llama2_main.C3_C4_v3/`
- `/home/jaeyongjang/project.local/vortex_fpint/analysis_workspace/latency_on_hw/outputs_llama3_main.C3_C4_v3/`

All rows in the principal C3/C4 `raw_db.csv` files have `status=pass`. The complexity shapes follow `tools/workload/gen_kernel_cfgs.py`, and the R4 operation structure follows `tests/regression/hadamard/kernel.cpp`.
