# Resident attention validation

Prepare fixtures with the existing independent C4 CPU generator. This step
does not launch simulation or use an FPGA:

```bash
repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
build="$repo/build_c4_sram_fusion"
tvm_env=/home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
bash "$repo/tests/regression/llama_decoder_C4/prepare_resident_fixtures.sh" "$build" "$tvm_env"
```

The preparation uses the rev8 C4 manifest at
`/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_cc4901d20c/manifest.json`.
It creates eleven fixtures under `fixtures/resident_attention`: nine test
cases below and two Llama2 prefill fixtures used as decode history. Every
fixture records its seed, configuration, manifest, and tensor hashes. These
are full model dimensions, not reduced decoder substitutes.

| Model | Stage | Query length | Past KV | Capacity | Attention rows | Coverage |
|---|---|---:|---:|---:|---:|---|
| Llama3 | prefill | 16 | 0 | 16 | 16 | K and V input padding |
| Llama3 | prefill | 128 | 0 | 128 | 128 | Direct full tile |
| Llama3 | prefill | 144 | 0 | 144 | 128 + 16 | Query chunks, causal offset, KV tail |
| Llama2 | decode | 1 | 16 | 32 | 1 | Eight-row pitch, both input adapters |
| Llama3 | decode | 1 | 16 | 32 | 4 | GQA and both input adapters |
| Llama2 | decode | 1 | 128 | 160 | 1 | KV length 129, K input padding |
| Llama3 | decode | 1 | 128 | 160 | 4 | GQA and KV length 129 |
| Llama2 | decode | 1 | 128 | 256 | 1 | Direct storage tiles, masked unused cache |
| Llama3 | decode | 1 | 128 | 256 | 4 | GQA and direct storage tiles |

There are eighteen full decoder runs for `legacy` and `resident`. Adding
`resident-fp32` uses the same nine fixtures and brings the total to twenty-seven. The
capacity-32 cases are the smallest starting point. Existing hardware profiles
for full Llama3 S32 and decode P1024 contain approximately 91.8 million and
10.8 million core cycles respectively; these are reference workload sizes,
not estimates of VCS throughput or the new backend's speed. Full prefill
simulation can therefore be expensive. Measure the first run before estimating
wall time for the remaining matrix.

Run one pair after the active verifier releases the configured build. Source
the SRAM config after the TVM environment because that environment selects
the legacy config. Replace the case arguments together when selecting another
row from the table:

```bash
set -e
source "$tvm_env"
source "$repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
cd "$build"
case_name=llama3-8b_decode_p16_c32
fixture="$build/fixtures/resident_attention/$case_name"
case_args="--model llama3-8b --batch 1 --seq-len 1 --stage decode --past-kv-len 16 --cache-capacity 32"
results="$build/results/resident_attention/$case_name"
mkdir -p "$results"
backends="legacy resident" # Add resident-fp32 to validate optional FP32 export.
for backend in $backends; do
  ./ci/run_black.sh xrt-vcs-sim --app llama_decoder_C4 \
    --args "$case_args --mode verify --attention-backend $backend --fixture $fixture --output $results/$backend" \
    > "$results/$backend.log" 2>&1
  "$py" "$repo/tests/regression/llama_decoder_C4/reference.py" compare \
    --fixture "$fixture" --output "$results/$backend" \
    > "$results/$backend.compare.log" 2>&1
done
"$py" "$repo/tests/regression/llama_decoder_C4/compare_attention_backends.py" \
  --legacy "$results/legacy" --resident "$results/resident"
# After a resident-fp32 run, use the same comparator and limits:
# "$py" "$repo/tests/regression/llama_decoder_C4/compare_attention_backends.py" \
#   --legacy "$results/legacy" --resident "$results/resident-fp32"
```

For prefill, use `case_name=llama3-8b_prefill16` (or 128/144) and
`case_args="--model llama3-8b --batch 1 --seq-len 16 --stage prefill"`.
For other decode rows, change model, past length, and capacity in both the
fixture name and arguments. Each command's nonzero exit is a failed gate;
the example commands must not be interpreted as passing merely because later
commands finish. Do not use `--diagnostic-timing` or `--stop-after` to claim a
full-decoder pass.

The CPU comparison retains the existing chain and same-input checks. If
scores/probabilities are absent, it diagnoses context using its existing CPU
QK and softmax replay on actual Q/K/V inputs. It does not synthesize missing
device dumps. The final output remains an independent CPU-reference gate.
The backend comparison additionally requires identical query and packed KV
inputs, compares context with `LOCAL_THRESHOLDS`, and compares final output
with `OUTPUT_THRESHOLDS`. It writes `attention_backend_comparison.json`.
The numerical limits remain 0.002 local and 0.005 final with the existing
magnitude split, violation fraction, relative L2, cosine, and nonfinite guards.

Resident `profile.csv` and `isolated.csv` append aggregated
`attention_total_cycles`, `gemm_submit_cycles`, `gemm_wait_cycles`,
`sram_copy_cycles`, and `simd_cycles`. The GEMM wait interval includes HBM
loads and compute; it is not pure compute latency. The wrapper's input padding
and dispatch costs are included in operation cycles but outside the shared
attention kernel's total interval. All non-attention rows have zero phase
columns. These counters are measurements only after a device run; compilation
and fixture generation do not produce performance results.

FP32 export is selected only by `--attention-backend resident-fp32`; `legacy`
remains the default and `resident` retains FP16 GEMM export. The same CPU and
backend comparison commands accept its context/output dumps without changes
to the numerical gates. Its TMEM output occupies 64 KiB instead of 32 KiB,
using the union of the allocation helper's two existing output slots. No
other TMEM allocation moves. LMEM work plus separate probability storage
adds 64 KiB at M=128 (4 KiB at padded M=8). The complete LMEM arena at M=128
is 165376 bytes versus 99840 bytes for FP16, within the reserved lower 512 KiB
of C4 LMEM.

Let `P = padded_query_rows * 128 * 2` bytes and `T` be the KV tile count.
Resident FP16 copies `(3*T+1)*P` bytes. FP32 copies `(5*T+2)*P` bytes, with
exactly `3*T+1` bridge commands in both modes. The added payload and FPGA
serialization can increase copy and GEMM wait cycles; compare the recorded
phase counters rather than assuming FP32 is free. Final context format and
its HBM traffic remain unchanged.

## Hardware matrix execution

`agent-tasks/c4-sram-flash-attention/run_hardware_matrix.py` runs all nine
cases with `legacy`, `resident`, and `resident-fp32`. For each case it first
runs full verification, the existing CPU comparator for all three backends,
and both resident-versus-legacy boundary comparisons. Only then does it run
three timing repetitions per backend, using the existing timing mode's
preflight and final-output checks plus separate counter-measurement passes.
It stops on a failed command and preserves all logs. Results must use a new
output directory; prior results are never overwritten.

The separate `build_c4_sram_hardware` directory is configured and its kernel,
runtime stub, decoder, and standalone attention applications compile. No FPGA
image or hardware result is implied by those builds. The proposed alias
`c4_sram_fusion_r2` must first be registered against the completed, timing-checked
revision2 image. The runner refuses an alias selecting any configuration other
than `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`, including the older generic `C4` alias.

Using the repository and TVM environment paths defined above:

```bash
source "$tvm_env"
source "$repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
"$py" "$repo/agent-tasks/c4-sram-flash-attention/run_hardware_matrix.py" \
  --build "$repo/build_c4_sram_hardware" \
  --fixtures "$repo/build_c4_sram_fusion/fixtures/resident_attention" \
  --fpga-bin c4_sram_fusion_r2 \
  --output "$repo/build_c4_sram_hardware/results/resident_matrix_r2" \
  --repetitions 3
```

Append `--dry-run` to review all 99 commands without accessing hardware or
creating results. `--case` can select a diagnostic subset; the report then
explicitly marks that the full matrix was not run. All device commands use
`ci/run_black.sh hw --fpga-bin ...` with managed Slurm execution and no extra
hardware defines. The runner pins the source alias map because generated build
copies can predate a newly registered alias.

`matrix.json` records command exits, image/configuration hashes, wall-time
samples, and mean per-operation cycle counters. It also records final-output
hashes and numerical reports. PASS requires successful final-output checks in
both verify and timing modes, a complete passing CPU decoder comparison for
each verify run, and passing legacy/resident boundary comparisons. A successful
process exit with a partial CPU comparison does not satisfy this gate.
GEMM wait still includes input
loads and polling. Its PASS covers the requested hardware matrix only; it does
not replace the simulation traffic audits, pure-compute trace analysis, or FPGA
timing report required by the implementation plan.
