# HPCA Reviewer Report

**Paper:** *FINISH: An End-to-End FP–INT LLM Inference System with Quantized Weights and KV Cache*  
**Recommendation:** Weak Reject  
**Score:** 3/6  
**Confidence:** 4/5

## Summary

This paper proposes FINISH, an end-to-end accelerator for LLM inference in which both model weights and the KV cache are quantized. Its main components are:

- A common FP–INT MXU for linear layers, $QK^T$, and $PV$.
- Support for Q-COL/Q-ROW quantization directions and standard/transposed operand loading.
- Dedicated tensor memory, accumulator memory, DMA engines, and a restricted interconnect.
- Tile-major layouts, alignment-aware allocation, and fused layout transformation.
- A Vortex-based FPGA prototype and 28 nm synthesis evaluation.

The problem is important, and extending native FP–INT execution beyond linear layers to quantized attention is relevant to HPCA. The attempt to connect arithmetic-unit efficiency to a full hardware/software stack is also valuable. However, serious problems in the evaluation methodology and result reporting currently make the paper's central conclusions difficult to trust.

## Strengths

1. **Important and timely problem.**

   Moving beyond weight-only acceleration to native FP–INT execution of KV-cache-quantized attention is well motivated. The observation that leaving attention on an FP path can become a bottleneck at long context lengths is convincing.

2. **Interesting unified Q-COL/Q-ROW datapath.**

   Folding the scale into the FP input for Q-ROW execution and reconfiguring the zero-point correction order is technically clean. Sharing 32 FP multipliers across the columns, instead of placing a multiplier in each of the 1024 PEs, is also a sensible implementation choice.

3. **Full-stack scope.**

   The paper considers TMEM, DMA, the interconnect, layouts, and runtime allocation rather than proposing only a compute unit. The placed-and-routed FPGA implementation and ASIC synthesis are stronger than a simulation-only study.

4. **Useful incremental configurations.**

   The C1–C4 configurations are a good framework for separating linear-only FP–INT execution, native FP–INT attention, and tensor-memory optimizations.

## Major Concerns

### 1. The baseline is unrealistically weak, and it dominates the headline energy result

C1 and C2 completely dequantize INT operands on the SIMT path before executing the FP TCU. During decode, they dequantize the entire KV cache again at every step. The introduction itself explains that software kernels such as Marlin and BitDecoding fuse dequantization into GEMM, yet the evaluation does not use such a fused baseline.

Consequently, the reported 97.44× geometric-mean and 201.91× maximum decode-energy reductions appear to arise primarily from repeated, materialized KV-cache dequantization rather than from the efficiency of native FP–INT arithmetic. The paper explicitly states that these large reductions occur because C1 and C2 dequantize the entire KV cache at every step.

At minimum, the evaluation should include:

- Tile-level or on-the-fly fused KV dequantization followed by the FP TCU.
- Fused weight-dequantization baselines.
- An FP baseline with a comparable memory hierarchy.
- Marlin/BitDecoding or an equivalent optimized implementation where applicable.
- Quantitative comparisons with AxCore and the most closely related FP–INT attention accelerators.

Without these comparisons, the primary speedup and especially the energy claims are likely overstated.

### 2. The central performance numbers are internally inconsistent

The abstract and conclusion report the following area-normalized end-to-end latency improvements:

- Prefill geometric mean: 3.24×.
- Decode geometric mean: 4.73×.
- Maximum: 4.31× and 7.96×.

Section VII-C and the discussion of Figure 13 instead report:

- Prefill geometric mean: 2.05×.
- Decode geometric mean: 5.20×.
- Maximum: 2.35× and 7.87×.

These are not rounding differences. The headline result appears to have been generated from different experiments or normalization methods. All figures, prose, the abstract, and the conclusion must be regenerated from one authoritative dataset.

### 3. The area-normalized latency methodology is insufficiently defined and potentially unfair

The paper combines latency measured on an FPGA with block areas synthesized in a 28 nm ASIC flow. The normalization includes the FP TCU, FP–INT engine, DMA engines, and some interconnect/control logic, but excludes the SIMT datapath and on-chip SRAM. Figure 16 indicates that the excluded SIMT and memory structures constitute more than half of total system area.

Specific problems include:

- The physical interpretation of multiplying FPGA latency by ASIC block area is unclear.
- The study does not construct an actual iso-area system or model replication and bandwidth scaling.
- C1–C3 use LMEM, whereas C4 partitions storage into LMEM, TMEM, and ACC MEM with different port and banking structures. Equal aggregate capacity does not imply equal SRAM area.
- C1 and C4 have substantially different raw compute capacities, but it is unclear whether replication, bandwidth, and total system budgets are matched.
- The paper sometimes describes an area–latency product as a latency reduction.

The paper should report candidate-specific absolute areas, SRAM-compiler results, whole-system area-normalized results, the exact metric formula, and preferably a true iso-area replication analysis.

### 4. The attention schedule is not representative of modern LLM inference

The evaluation materializes the $QK^T$ scores in HBM, runs softmax as a separate SIMD kernel, writes its output back to HBM, and then executes $PV$. This creates $O(N^2)$ intermediate traffic and is much less efficient than a tiled or fused FlashAttention-style schedule, particularly for long-context prefill.

Using the same schedule for all candidates is useful for an internal ablation, but it does not show that FINISH is competitive with a modern LLM inference system. The authors should evaluate:

- A fused or tiled attention baseline.
- A FINISH implementation that avoids materializing attention intermediates in HBM.
- The sensitivity of the reported speedup to the sequential attention schedule.

### 5. Absolute performance and utilization data are missing

Nearly all results are normalized to C4. The paper does not provide enough absolute information, including:

- End-to-end latency or tokens/s.
- GEMM/MXU utilization.
- Achieved HBM bandwidth.
- TMEM and DMA utilization.
- Stall breakdowns.
- Candidate-specific FPGA LUT, FF, DSP, BRAM, and URAM usage.
- Timing slack and maximum frequency.
- Absolute 28 nm area and power.

With one Vortex core running at 100 MHz, absolute execution time is particularly important. Relative speedup alone cannot establish whether FINISH is fast or whether C1 is simply very slow.

### 6. The meaning of "end-to-end" is unclear

The methodology measures per-kernel latency and power and then sums them to obtain end-to-end latency and energy. This appears to be a constructed result rather than a direct measurement of a complete model inference execution.

The paper should state whether the following costs are included:

- Kernel launch and MMIO descriptor overhead.
- Inter-layer synchronization.
- Host-device orchestration.
- Allocation and runtime bookkeeping.
- Cache flushes and fences.
- DMA startup and tail effects.
- KV-cache quantization, creation, and storage.
- Repetition across every layer of the full model.

An execution timeline and a precise list of included and excluded costs are needed to justify the end-to-end terminology.

### 7. The evaluation scope is narrower than the claims

Support for multiple KV quantization directions is a central contribution, but the end-to-end evaluation covers only SpinQuant W4A16KV4. It does not evaluate an actual channel-wise-K configuration from KIVI or KVQuant at the model level.

The hardware also assumes output group sizes of 32, 64, or 128 and pads dimensions so a 32-column tile does not cross a group boundary. Missing evaluations include:

- Multiple quantization schemes and directions.
- Irregular dimensions and group sizes.
- Padding, fragmentation, and capacity overhead.
- Other bit widths such as INT2 or INT8.
- MQA, GQA, and MLA configurations.
- Larger models or model-parallel configurations.

Analytical support for these cases is not equivalent to end-to-end validation.

### 8. The accuracy evaluation is incomplete

Table IV claims to cover both Llama2-7B and Llama3-8B, but every Llama3-8B entry is missing. The accompanying text also says that both models are compared even though only Llama2-7B results are available.

Mean ULP error alone is also insufficient to characterize worst-case numerical behavior. Maximum or percentile error, overflow frequency, and challenging input distributions would strengthen the analysis.

### 9. Evidence for the tensor-memory contribution is limited

The reported C4-over-C3 end-to-end improvement is only 1.02× for prefill and 1.55× for decode. In prefill, one of the paper's central architectural contributions therefore has almost no end-to-end benefit.

The tensor path needs supporting microbenchmarks and sensitivity analysis, including:

- Bank- and port-count sweeps.
- Restricted-interconnect versus crossbar area, power, and performance.
- Row-major versus tile-major burst counts and achieved bandwidth.
- Padding and capacity overhead caused by alignment constraints.
- TMEM-size sensitivity.
- DMA queue-depth and outstanding-request sensitivity.
- The effect of the hardware-generated GEMM command stream.

The current paper does not sufficiently connect the claimed 8× bandwidth increase and 5.22% area overhead to observed system behavior.

## Questions for the Authors

1. Why do C1 and C2 not use fused on-the-fly dequantization? How much does the 97.44× decode-energy result decrease with such a baseline?
2. Which end-to-end results are correct: the abstract's 3.24×/4.73× or Section VII-C's 2.05×/5.20×?
3. What is the exact formula for area normalization, and why does it exclude most of the system area?
4. Figure 16 suggests that the full C4 design occupies approximately 14 mm². What are the corresponding full-system areas of C1–C3?
5. Are the end-to-end results measured from complete model executions or constructed by adding independently measured kernels?
6. How do the results change when attention scores and probabilities are not materialized in HBM?
7. Has Q-ROW been validated end-to-end with an actual KIVI/KVQuant channel-wise-K model?
8. What are the measured absolute latency, tokens/s, HBM bandwidth, and MXU utilization?
9. Why are all Llama3-8B accuracy results absent?
10. What is the `xrt-smi` sampling interval, and when short kernels are repeated for power measurement, are their DMA and memory transfers also repeated?

## Minor Issues

- The first page shows **"HPCA 2027 Submission #NaN"**, indicating a submission-generation error.
- Table IV should either include the Llama3-8B results or remove that model from the caption and discussion.
- There are typographical errors such as "misalignement."
- Labels in Figures 13 and 14 are too small for comfortable reading in print.
- Absolute values should be provided alongside normalized plots.
- The terms "area-normalized latency" and "area–latency product" should be used consistently and distinguished clearly.

## Final Assessment

The underlying idea is promising. In particular, the unified Q-COL/Q-ROW datapath and full-stack FPGA implementation have the potential to support a strong HPCA paper. In the current version, however, the largest reported gains depend on an unfused dequantization baseline, while the headline latency numbers contradict the evaluation section. The absence of a modern fused-attention comparison, absolute performance data, and a rigorous whole-system iso-area methodology further weakens the conclusions.

I therefore recommend **Weak Reject**. The most important revision priorities are:

1. Add fused-dequantization and tiled-attention baselines.
2. Re-evaluate area, latency, and energy using a consistent whole-system methodology.
3. Correct all result inconsistencies and complete the Llama3-8B accuracy evaluation.

Addressing these issues could move the paper toward the borderline-accept range.
