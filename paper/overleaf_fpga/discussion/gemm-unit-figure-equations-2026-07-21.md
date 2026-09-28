# GEMM Unit Figure Equations, 2026-07-21

대상 figure: `figures/gemm_engine.png`

목적: GEMM unit figure의 네 연산 블록에 직접 삽입할 compact 최종 수식을 정리한다. 모든 식은 하나의 tile과 quantization group에 대한 연산을 나타낸다. Q-ROW에서는 하나의 MXU tile 안에서 `h`가 고정되어 있다고 가정한다.

## 1. Input Scaler and Prealigner

$$
\widehat{A}=\operatorname{PreAlign}\!\left(A s_{\mathrm{in}}\right),
\qquad
s_{\mathrm{in}}=
\begin{cases}
1, & \mathrm{Q\text{-}COL},\\
S, & \mathrm{Q\text{-}ROW}.
\end{cases}
$$

Q-COL은 activation을 그대로 prealign하고, Q-ROW는 scale을 activation에 먼저 fold한다.

## 2. ZP Multiplier and Activation Reduce Tree

$$
D=
\begin{cases}
-Z\displaystyle\sum_k\widehat{A}_k,
& \mathrm{Q\text{-}COL},\\[5pt]
\displaystyle\sum_k\left(-Z_k\widehat{A}_k\right),
& \mathrm{Q\text{-}ROW}.
\end{cases}
$$

Q-COL은 reduce-then-multiply, Q-ROW는 multiply-then-reduce를 수행한다.

## 3. Merger, INT2FP, and Output Scaler

$$
I=P+D,
\qquad
C\mathrel{+}=s_{\mathrm{out}}\operatorname{Int2FP}\!\left(I;e_{\max}\right),
\qquad
s_{\mathrm{out}}=
\begin{cases}
S, & \mathrm{Q\text{-}COL},\\
1, & \mathrm{Q\text{-}ROW}.
\end{cases}
$$

Q-COL은 output scale을 적용하고, Q-ROW는 output scaler를 bypass한다. `\mathrel{+}=`는 tile/group 결과의 accumulator 누적을 나타낸다.

## 4. Transposable MXU

$$
B^{\mathrm{int}}_{\mathrm{load}}=
\begin{cases}
B^{\mathrm{int}}, & \mathrm{Linear/PV},\\
\left(K^{\mathrm{int}}\right)^T, & QK^T,
\end{cases}
\qquad
P=\sum_k\widehat{A}_k B^{\mathrm{int}}_{\mathrm{load},k}.
$$

동일한 MXU가 standard RHS load와 transposed RHS load를 지원한다.
