# C++ decoder stack validation

The stack uses the Llama 3-8B dimensions and distinct synthetic weights for each layer (seed 20260831 + layer index). Only C++ hardware wall times qualify as performance results. TVM and CPU fixture checks run outside the measurement.

## Reproduction

Generate fixtures with the configured TVM Python environment using `tests/regression/llama_decoder_common/generate_stack.py --candidate C4 --manifest <bitstream-manifest> --output <root> --layers 2`. The same generator supports C1–C3. The prefill and decode folders each contain one fixture per layer. After the C++ prefill verify run, use `--stage decode --prefill-hw-output <prefill-verify-output>` to feed the actual per-layer KV into decode while preserving independent reference outputs.

Run the configured build's `ci/run_black.sh hw --fpga-bin <alias> --app llama_decoder_C4 --args "--layers 2 --resident-layers auto --seq-len 1024 --fixture <root>/prefill --mode verify --output <out>"`. For decode, pass `--seq-len 1 --stage decode --past-kv-len 1024 --cache-capacity <physical capacity>` and the decode fixture. The active attention extent is 1056 with 1025 valid positions. C4's physical cache uses 1152 positions, matching its original working decoder experiment. Explicit verify mode dumps intermediate tensors; timing mode checks the final hidden state before admitting measurements.

`--resident-layers 1` forces weight staging between layers. Inter-layer hidden remains on the board. Timed staging uses host-resident data and synchronous uploads. The initial upload and timing checks are outside the wall timer. In `stack_timings.csv`, resident time equals actual wall time less synchronous in-run staging. Normal C++ launch/wait and device memory traffic are included. Only rows passing verification are eligible for comparison.

## Hardware checks

- At C4 B1/S32, the submitted bitstream produced byte-identical two-layer outputs with both layers resident and with one resident slot. Layer 0 standalone passed. The free-running two-layer output exceeded the existing elementwise tolerance for 24023 of 131072 elements. The second layer checked against a reference generated from its actual input exceeded that tolerance for 841 elements. This local diagnostic does not replace the independent final check.
- On the C3 and C4 subnormal-fixed images, B1/S1024 two-layer prefill produced the same final error: 748534 / 4194304 elements outside tolerance, relative L2 0.00221846. C4's same-input second-layer diagnostic reduced the fraction outside tolerance to 1.2800%, versus 17.8464% for the original chain.
- Corrected C3 and C4 single-layer decode passed. With canonical initial KV, two-layer decode failed on both (263 / 4096 outside tolerance). C3 and C4 decode with actual two-layer prefill KV also failed (310 / 4096 each).
- With the subnormal-fixed TCU candidates, single-layer decode passed for both C1 and C2. Two-layer decode with canonical initial KV exceeded tolerance at 166/4096 elements for C1 and 219/4096 for C2. With device-produced prefill KV the counts are 292 / 4096 and 445 / 4096, respectively. Two-layer prefill exceeded tolerance at 853067 / 4194304 elements for C1 and 1258039 / 4194304 for C2.
- The gate allows at most 2% of elements outside the existing tolerance. Failed rows are excluded from performance results. No 32-layer latency is established by these checks.

The submission composition used rev5_v2 for prefill and historical rev5 for decode. The subnormal-fixed TCU/naive/improve candidate mapping is in `candidate_fpga_bins.rev7.yaml`. The similarly named `outputs_llama3_main.rev8_v2` dataset instead uses FPFP hardware for C1 and C2. Preserve the hardware identity when selecting the matched denominator.

The eight stage-specific checks, actual xclbin SHA-256 hashes, submitted 32-layer estimates, and individual verification report paths are in `cpp_stack_gate_results.csv`. Decode rows in this CSV use device-produced KV. Latency fields for 32-layer runs are empty. The output checks above used the independent PyTorch reference. A full-stack TVM check has not been established.

For the final B1/past-1024 decode checks on all four corrected bitstreams, forced one-slot staging and two-slot residency produced byte-identical final hidden buffers using the same device-produced KV. This checks the staging path independently of the floating-point reference tolerance.


## Decode reporting

The submitted workload definition in `paper/overleaf_fpga/main_highlight.tex` averages 128 decode steps per sequence. For the B1/1K stack experiment, start from 1024 prefilled tokens, append one KV entry per layer per step, and advance the logical attention length from 1025 through 1152 inclusive. Preserve KV across the 128 steps and restore the original prefill state before each independent repetition. Report each repetition's summed resident latency divided by 128 and the median of those repetition-level TPOT values. Use the sum of the corresponding 128 kernel compositions divided by 128 as the comparator. Keep staging time and output verification status separately.

The existing single-step runs are first-decode-step diagnostics. Compare those only to the step-1 composition at valid length 1025. They provide no 128-step TPOT measurement.

## Interpreting the C3 prefill comparison

The October 9 manuscript used the corrected rev5_v2 prefill composition. Its C3 estimate of 31.454 s per layer included Q/K/V head reorders executed by that decoder; the corresponding single-layer wall time was 31.832 s (−1.19%). The subsequent decoder optimization folded the reorders into RoPE and KV quantization. Comparing the submission estimate to today’s 32-layer wall time of 955.892 s gives +5.30% across implementations. Using the updated rev7 composition of 29.752777 s per layer instead gives −0.40%. C3 failed final-output verification in the 32-layer prefill run, so both comparisons are diagnostic.
