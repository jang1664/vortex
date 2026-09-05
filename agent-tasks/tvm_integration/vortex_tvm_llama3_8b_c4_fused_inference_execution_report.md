# Vortex TVM Llama3-8B C4/Fused Inference Execution Report

## 1. 결론

C4 `fused` synthetic Llama3-8B correctness 목표를 pinned U55C에서 달성했다.

- S1-S4 모두 asymmetric W4/K4/V4 package를 `fused` policy로 생성하고 reload했다.
- 네 case 모두 prefill과 연속 decode 3회를 한 process에서 완료했다.
- 총 128 decoder-layer call/case를 retry 없이 수행했고 NaN/inf가 발생하지 않았다.
- 32개 layer의 cache length가 각 case의 prompt length에서 매 decode마다 정확히 1씩 증가했다.
- S2와 S4의 마지막 free-running top-1 차이는 canonical hidden/KV를 넣은 decode 3
  단독 실행에서 사라졌다. 두 경우 모두 32 layers와 top-1 comparison을 통과했다.
- 기존 generic Relax attention mask/softmax 표현에서 나타난 multi-token causal-mask 오류를
  `vortex::causal_softmax` logical op와 단일 physical TIR kernel로 치환했다.
- Hadamard는 `alone`/`fused`, width 128/14336, one-row/multi-row 모두 logical call당 physical
  kernel 하나를 유지한다.
- RTL, hardware FSM, driver protocol, xclbin은 변경하지 않았다.

정확성 결과는 accept할 수 있다. 다만 현재 성능 자료는 old `alone`과 new `fused`의 단일
sample뿐이므로 fused speedup 주장은 보류한다. 동일 소스 package의 warmup + 3회 반복 비교는
후속 성능 측정으로 남긴다.

## 2. 고정 실행 계약

- Vortex base revision: `3c47d2df252e5848b5e944d95ae697aa6e04861d`
- TVM base revision: `14745feddaaba655ed0c5de838508b8ad434f4e9`
- 두 repository 모두 위 revision 위의 working-tree 변경으로 검증했다.
- XCLBIN:
  `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin`
- Profile fingerprint:
  `62540fb747aa762d5cfab874e36d1daac7119d8cff3e32d659a104b460383256`
- Config: `configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`
- Model: 32 layers, hidden 4096, intermediate 14336, Q heads 32, KV heads 8,
  head dimension 128, vocabulary 128256
- Quantization: `signed_all_asymmetric_wkv4_v1`; W group 32, K/V group 128,
  FP16 scales, INT16 zero points
- Seed: parameters `20260831`, boundary inputs `20260902`
- Runtime: XRT, device-copy state transport, persistent process, zero diagnostic retries

## 3. 구현 내용

### 3.1 PyTorch/Vortex export

`pytorch/spinquant/spinquant_inference/vortex_export_ops.py`에
`vortex::causal_softmax`를 추가했다. 입력/출력 계약은 다음과 같다.

- scores: rank-5 FP16 `[B, KVH, G, Q, capacity]`
- position IDs: rank-2 INT64 `[B, Q]`
- valid length: scalar INT64
- output 0: scaled and causally masked FP32 scores
- output 1: FP16 probabilities

`llama3_c4_export.py`의 scale, valid mask, causal mask, `where`, softmax 조합을 이 logical op
한 개로 바꿨다. eager reference와 fake implementation은 동일 shape/dtype/causal semantics를
검증한다.

### 3.2 TVM import와 lowering

- ExportedProgram importer가 `causal_softmax.default`를
  `relax.vortex.causal_softmax`로 one-to-one import한다.
- Vortex lowering은 rank-5 shape, position shape, scalar valid length, positive head dimension을
  확인한다.
- 한 physical TIR kernel이 각 attention row의 maximum, denominator, probability를 순차 계산한다.
  invalid/future key는 masked score `-inf`, probability `0`으로 기록한다.
- module attr `vortex.causal_softmax.lowered`로 lowering 개수를 남긴다.
- fused compiler test는 prefill/decode 각각 Hadamard 3개와 causal softmax 1개가 정확히 한
  `call_tir`씩 생성됨을 검사한다.
- 기존 tiled-A reuse는 유지되어 one-layer의 `gemm_a_tiled` count가 `alone` 15에서 `fused`
  12로 감소하고, reused-A attr은 3이다.

### 3.3 Hadamard multi-row 안정성

공유 work buffer를 다음 row에서 재사용하기 전에 모든 thread가 현재 row read를 끝내도록
row 끝에 shared synchronization을 추가했다. width 14336의 prompt-length 7 및 batch case에서도
logical Hadamard 하나가 physical kernel 하나로 lowering된다.

### 3.4 Runner diagnostics와 runtime lifetime

- embedding VM output에 불필요한 device-to-device copy를 하지 않고 producer VM lifetime을
  보존한다. 큰 multi-token embedding에서 관찰된 copy corruption을 피한다.
- canonical comparison은 실제 reference가 있을 때만 enforce한다.
- `--diagnostic-reference-decode-inputs`가 live state 접근보다 먼저 canonical hidden/KV를
  선택하도록 순서를 고쳤다.
- `--diagnostic-start-phase N`을 추가하여 prefill부터 장시간 반복하지 않고 특정 decode
  phase를 identical-input으로 직접 검증할 수 있게 했다.
- layer checkpoint reproducer는 layer 0을 포함한 0..31을 지원하고 선택한 두 layer의
  parameter만 upload한다.
- FP16 검사는 작은 reference 값에 absolute error, 큰 값에 relative error를 적용한다.
  S2 multi-token cache의 sparse scale/code boundary 이동을 허용하되 relative-L2, cosine,
  code mismatch, dequantized-cache guard를 함께 유지한다.

## 4. Package 결과

| Case | Shape `(B,Q,capacity)` | Package SHA256 | Archive manifest SHA256 |
| --- | --- | --- | --- |
| S1 | `(1,1,8)` | `007295a0fe0169732ef580922fcc189c14eb8356788139b013baa7174c9b8e0a` | `d02ca1d2cc87f2c92669d1981b019e1d559219d6b56067571223522f4a8520c7` |
| S2 | `(1,7,16)` | `f97068b28a46ca5e34170af61bc9a5b636108cb53dad851e636efc708f7b612c` | same |
| S3 | `(2,1,8)` | `7ffc49f884d977b0b509ed72b60083f29b54ccc7fb8646bac790666a6c5360c4` | same |
| S4 | `(2,7,16)` | `ab5b98ba2561e2908d4a7ccc6c673f888ac8f1c44fd61b3010926407f4d401c5` | same |

각 `package.json`은 `layout_policy=fused`, model `llama3-8b`, quantization
`signed_all_asymmetric_wkv4_v1`, 위 pinned fingerprint를 기록한다. parameter archive는 네
static shape package가 동일한 검증된 synthetic parameters를 공유한다.

Artifact directories:

- `/home/jaeyongjang/project.local/tvm/build/llama3_synthetic_s1_fused_causal_softmax_v1`
- `/home/jaeyongjang/project.local/tvm/build/llama3_synthetic_s2_fused_causal_softmax_v1`
- `/home/jaeyongjang/project.local/tvm/build/llama3_synthetic_s3_fused_causal_softmax_v1`
- `/home/jaeyongjang/project.local/tvm/build/llama3_synthetic_s4_fused_causal_softmax_v1`

## 5. U55C free-running 결과

| Case | Cache lengths | Generated tokens by batch | Phase latency seconds | Launches `(prefill, decode)` | Retry |
| --- | --- | --- | --- | --- | ---: |
| S1 | `1,2,3,4` | `[89754,29229,89754]` | `77.919,81.904,80.812,82.175` | `75966,77950` | 0 |
| S2 | `7,8,9,10` | `[89754,29229,89754]` | `160.090,84.644,85.286,85.952` | `81152,77886` | 0 |
| S3 | `1,2,3,4` | B0 `[89754,29229,89754]`; B1 `[29229,29229,89754]` | `146.421,149.688,151.390,151.902` | `141502,143422` | 0 |
| S4 | `7,8,9,10` | B0/B1 `[89754,29229,89754]` | `308.125,156.213,154.961,157.201` | `144640,143358` | 0 |

모든 case는 한 process에서 32-layer prefill과 32-layer decode 세 번, 총 128 layer call을
완료했다. cache length는 32개 layer 모두 동일하게 위 값을 기록했다.

Primary traces:

- S1: `hardware_s1_free_trace.json`
- S2: `hardware_s2_rerun_trace.json`
- S3: `hardware_s3_free_trace.json`
- S4: `hardware_s4_free_trace.json`

각 파일은 위 artifact directory 아래에 있다.

## 6. Canonical-input 수치 검증

### 6.1 S1 full chain

`hardware_s1_canonical_inputs_trace.json`은 prefill/decode 1/decode 2의 32 layers를 strict하게
검증했고, decode 3도 동일 reference input으로 comparison을 기록했다.

| Phase | Normalized relative-L2 | Logits relative-L2 | Top-1 | Validated layers |
| --- | ---: | ---: | ---: | ---: |
| prefill | `8.611e-4` | `2.727e-4` | `1.0` | 32 |
| decode 1 | `3.237e-5` | `5.097e-5` | `1.0` | 32 |
| decode 2 | `1.343e-4` | `1.057e-4` | `1.0` | 32 |
| decode 3 | `8.344e-5` | `8.404e-5` | `1.0` | diagnostic/non-enforced |

### 6.2 S2/S4 final top-1 branch

Free-running S2와 S4는 decode 3 결과가 eager canonical token과 일부 달랐다. decode 3은 더
이상 다음 phase의 input으로 사용되지 않지만, 원인을 구분하기 위해 reference의 phase-3
hidden과 이전-phase KV를 직접 넣어 독립 실행했다.

| Case | Selected token | Cache | Normalized relative-L2 | Logits relative-L2 | Top-1 | Layers | Retry |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| S2 decode 3 | `[29229]` | 10 | `2.643e-5` | `4.716e-5` | `1.0` | 32 | 0 |
| S4 decode 3 | `[29229,29229]` | 10 | `7.965e-5` | `7.668e-5` | `1.0` | 32 | 0 |

S2 trace는 `hardware_s2_phase3_canonical_trace.json`, S4 trace는
`hardware_s4_phase3_canonical_trace.json`이다. 두 결과 모두 small-value maximum absolute
error `4.8828125e-4`, large-value maximum relative error 약 `9.75e-4` 이하였고 exceed
fraction은 0이었다.

따라서 free-running 마지막 token 차이는 fused kernel이 동일 입력에서 다른 답을 내는 문제가
아니다. 앞 decode 단계의 허용된 FP16/W4/K4/V4 quantization 차이가 hidden/cache에 누적되어
argmax 경계를 넘은 autoregressive branch이다.

### 6.3 S2 장시간 strict-run 관찰

S2의 prefill부터 모든 phase를 한 번에 strict checkpointing한 일부 실행은 layer 10 또는 20
이후 U55C device poison으로 중단됐다. 같은 layer 10은 fresh process 단독 실행에서 hidden
relative-L2 `1.60e-4`로 통과했고, S2 full free-running과 phase-3 독립 strict run도 retry 없이
통과했다. 따라서 이 현상을 특정 tensor 또는 fused 계산 오류로 분류하지 않았다. 장시간
checkpoint 실행 안정성 문제는 별도 runtime/infrastructure 조사 대상으로 남긴다.

## 7. 발견한 최초 multi-token 오류와 수정 근거

초기 S2 fused 실행의 첫 큰 mismatch는 attention probability였다. 동일 shape의 GEMM과
Hadamard는 통과했지만 generic Relax mask/softmax decomposition이 만든 hardware mask의 valid
pattern이 causal reference와 달랐다. 이를 RTL K-tail 문제로 확대하지 않고, causal semantics를
한 logical op로 보존하여 TVM이 한 physical kernel로 내리도록 했다.

수정 후 S2 layer 0 checkpoint의 hidden relative-L2는 약 `1.23e-2`이고 expected maximum
`17.234`에 대해 hardware maximum `17.1875`였으며 stage-aware guard를 통과했다. 이어서 S2
전체 free-running과 phase-3 identical-input 32-layer 검증이 모두 통과했다. 이 결과는 RTL/FSM
변경이 필요하지 않음을 뒷받침한다.

## 8. 성능 및 launch 관찰

현재 new fused S1 single sample과 이전 accepted alone S1 single sample을 단순 비교하면:

| Metric | Old alone | New fused | Delta |
| --- | ---: | ---: | ---: |
| Total four-phase latency | `335.834 s` | `322.810 s` | `-3.88%` |
| Total instrumented launches | `311,992` | `309,816` | `-2,176` |
| Per-phase launch delta | — | — | `-544` |

이 비교에는 새 causal-softmax lowering과 runner lifetime 수정까지 함께 포함되고 각 policy가
한 sample뿐이므로 fused speedup 근거로 사용할 수 없다. compiler-level로 확정할 수 있는 것은
one-layer `gemm_a_tiled` 15 -> 12와 reused tiled-A 3개뿐이다. Hadamard layout boundary를 더
최적화하는 작업은 profile에서 반복 비용이 확인된 뒤에만 수행한다.

## 9. Regression 결과

- `pytorch/test/test_vortex_export_ops.py`: **6 passed**
- `pytorch/test/test_llama3_c4_export.py`: **21 passed**
- TVM focused import/lowering/layout/Hadamard/cache tests: **16 passed**
- `python -m py_compile apps/vortex_llama3/run_synthetic_inference.py`: passed
- Vortex/TVM `git diff --check`: passed

Llama export test의 과거 private `_dense_hadamard`/`_sylvester_hadamard` 참조는 현재 public
logical-op 계약인 `torch.ops.vortex.hadamard` 호출로 갱신했다.

## 10. Milestone 판정

| Milestone | Result | Evidence |
| --- | --- | --- |
| A: host compile/source/reload | PASS | four fused packages, pinned metadata, 15 -> 12 tiled-A, 3 reused layouts, single-kernel assertions |
| B: focused U55C correctness | PASS | isolated Hadamard coverage, layer checkpoint comparisons, no non-finite/retry |
| C: full S1 | PASS | 128 calls, cache 1/2/3/4, strict canonical trace and free trace |
| D: S2-S4 | PASS | four full free runs; S2/S4 divergent final branch passes phase-3 identical-input rerun |
| E: performance | PARTIAL | launch/latency observations recorded; fair 3-repeat policy comparison not yet run, no speedup claim |
| F: regression/docs | PASS, commit pending | 6 + 21 + 16 tests and this report |

## 11. 남은 작업

1. 같은 source revision으로 S1 `alone`과 `fused` package를 다시 만들고, 각각 warmup 후 최소
   3회 same-process inference를 수행해 median/range를 비교한다.
2. 필요하면 physical kernel class별 launch counter를 추가해 `gemm_a_tiled`, detile,
   causal-softmax, Hadamard 비용을 분리한다.
3. S2 장시간 strict checkpoint run의 간헐적 device poison은 별도 runtime/infrastructure
   reproducer로 조사한다. correctness acceptance에 retry를 도입하지 않는다.
4. 실제 Llama3-8B checkpoint conversion, tokenizer, language-quality/perplexity 검증은 기존
   계획대로 후속 과제로 유지한다.

현재 결과만으로 RTL/FSM 변경이나 새 xclbin을 정당화하는 identical-input hardware mismatch는
없다.
