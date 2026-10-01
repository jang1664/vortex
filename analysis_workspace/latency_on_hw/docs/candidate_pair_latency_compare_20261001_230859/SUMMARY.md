# C1/C3/C4 기존 alias config와 v2 config의 RTL latency 비교

**C3 completed follow-up (2026-10-02):** Fresh old/v2 runs after the reorder correction and static assertion both PASS. C3 rows below use the corrected rerun; original failing logs and `results.json` remain historical records. Details: [C3_COMPLETED_COMPARISON.md](C3_COMPLETED_COMPARISON.md).

총 8회 모두 `ci/run_black.sh xrt-vcs-sim`에서 실행했다. CPU reference 검증은 7/8회 통과했다.
각 pair는 같은 source snapshot, app variant, shape, 입력 생성 방법을 사용했다.
측정값은 한 번의 cold kernel launch에 대한 `vx_dump_perf` core cycles이다.
GEMM 값은 DMA, job 제출·완료 polling 등을 포함하는 전체 kernel cycles이며, MXU 연산 구간만의 cycle이 아니다.
기존 FPGA xclbin의 hardware latency를 재측정한 결과가 아니라, 현재 branch RTL에 각 config를 적용한 비교이다.

## Config 매핑

| Candidate | 기존 FPGA alias | alias가 가리키는 config | 새 config |
| --- | --- | --- | --- |
| C1 | `tcu_th16_c1_v2` | `configs/tcu_th16_c1.sh` | `configs/tcu_th16_c1_v2.sh` |
| C3 | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr` | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh` | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh` |
| C4 | `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread` | `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh` | `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh` |

**주의:** alias `tcu_th16_c1_v2`는 `configs/tcu_th16_c1.sh`에 연결되어 있다.
동일한 이름의 파일 `configs/tcu_th16_c1_v2.sh`와 다른 설정이다. alias map은 source snapshot에 함께 보존했다.

## Workload

| Candidate | App / variant | Shape / 조건 | Arguments |
| --- | --- | --- | --- |
| C1 | `softmax` / `rev2_shuffle_grouped` | batch=1, heads=1, Q=K=256; FP16 input/output; causal; scale=0.125 | `-batch 1 -heads 1 -seqq 256 -seqk 256 -seqk-stride 256 -mask 1` |
| C1 | `sgemm_tcu` / `b_colmajor` | M=128, N=128, K=256; dense FP16 inputs/output, FP32 accumulation | `-m 128 -n 128 -k 256` |
| C3 | `fpint_gemm_ffn_hw_naive` | M=128, N=256, K=256; FP16×INT4; QBLK=32, WTRANS=0, QDIR=0, REPS=1 | `-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1` |
| C4 | `fpint_gemm_ffn_hw` | M=128, N=256, K=256; FP16×INT4; QBLK=32, WTRANS=0, QDIR=0, REPS=1 | `-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1` |

## Pair별 결과

Delta = v2 − 기존. 음수는 v2의 cycle 감소를 뜻한다.

| Candidate | Workload | 기존 cycles | v2 cycles | 검증 (기존/v2) | Delta cycles | 변화율 | 기존/v2 speedup |
| --- | --- | ---: | ---: | --- | ---: | ---: | ---: |
| C1 | softmax | 947,342 | 942,559 | PASS/PASS | -4,783 | -0.505% | 1.0051× |
| C1 | tcu | 479,926 | 459,100 | PASS/PASS | -20,826 | -4.339% | 1.0454× |
| C3 | gemm_naive | 47,981 | 47,446 | PASS/PASS | -535 | -1.115% | 1.0113× |
| C4 | gemm_improve | 46,848 | 46,848 | PASS/PASS | +0 | +0.000% | 1.0000× |

**Original-run failure history:** The following failures describe v2 before enabling reorder. The passing rerun above completes the performance comparison.
C3 v2의 기본 WTRANS=0 case는 job completion까지 진행했지만 32,768개 출력 중 1,024개가 reference와 달랐다. 기존 C3는 같은 case에서 PASS했다.
compile error, simulator timeout, Fatal이 아닌 numerical mismatch이다. config·RTL은 비교 중 수정하지 않았다.

### C3 completed follow-up: WTRANS=1

같은 M=128, N=256, K=256, QBLK=32, QDIR=0에서 weight layout만 WTRANS=1로 바꿨다.

| Version | Cycles | Instructions | 검증 |
| --- | ---: | ---: | --- |
| old | 48,206 | 9,635 | PASS |
| corrected v2 | 47,671 | 9,593 | PASS |

The corrected rerun passes: v2 saves 535 cycles (-1.110%, 1.0112× speedup). The uncorrected WTRANS=1 run failed at the same observed cycle count.

### C3 historical diagnosis: DMA cache ports restored to 1

C3 v2의 LMEM 1.25 MiB, D-cache 2 banks, HBM 4 ports 등은 유지하고, 진단용 config 복사본에서 `DMA_DCACHE_PORTS=2`만 `1`로 바꿨다.
결과: PASS, 48,348 cycles. 요청한 원본 v2 config의 결과와 구분해야 한다.
같은 non-power-of-two LMEM 용량 및 offset=0에서 통과했으므로, 용량 또는 offset 그 자체가 모든 경우에 실패를 유발하는 상황은 아니다.
이 실험은 DMA port 설정과 numerical failure의 관련성을 확인한다. 어느 RTL 내부 신호가 잘못되는지까지 확정한 것은 아니다.

### C3 historical diagnosis: uncorrected v2, offset=1 MiB

원본 C3 v2 config 그대로 `--lmem-offset 1048576`을 추가했다. 결과: FAIL, 47,446 cycles.
기본 offset=0의 scratch 범위는 [0, 184320), offset=1 MiB에서는 [1048576, 1232896)이며 모두 1.25 MiB=1310720 바이트 안에 들어간다.
상세 bank/offset 검증은 [LMEM_OFFSET_AND_BANK_CHECK.md](LMEM_OFFSET_AND_BANK_CHECK.md)에 기록했다.

## 주요 config 차이

- C1: L2 on→off; I/D-cache 각각 16→32 KiB; LMEM 1→1.5 MiB; HBM 연결 포트 8→4.
- C3: D-cache banks 4→2; DMA cache ports 1→2 (cache-side aggregate beat 64→128 B); LMEM 1→1.25 MiB; HBM 연결 포트·DMA channels 8→4. LMEM은 두 설정 모두 16 ports/16 banks, ACC는 256 KiB.
- C4: TMEM bank size 32→64 KiB, 8 banks이므로 합계 256→512 KiB; ACC depth 1024→2048, 합계 256→512 KiB. 그 외 compile-time define은 동일하다.

이 비교는 config 변경 묶음 전체의 효과를 측정한다. C1의 L2 제거 또는 C3의 DMA 폭 확대 하나만의 효과로 분리할 수 없다.
Softmax는 DMA를 호출하지 않는다. LMEM 크기는 compile-time scratch partition 상수도 바꾸므로, 같은 source variant라도 binary가 달라질 수 있다.

## 검증 및 실행 근거

- Snapshot HEAD: `786f929ac10cb3709404fb097317b12bfecf86c6`; dirty working-tree source 내용은 `source_sha256.json`에 기록.
- Source snapshot: `/tmp/vortex_candidate_pair__k9ghv_g/source`
- config마다 독립 configured build 사용. 같은 C1 build의 softmax와 TCU는 순차 실행.
- configure 명령: `../configure --xlen=64 --tooldir=/opt/vortex --prefix=/home/jaeyongjang/tools/vortex`.
- 각 run은 config를 source한 다음 wrapper를 호출. 추가 hardware define은 넣지 않았다.
- `MAKEFLAGS="FSDB_DUMP= CXX=/usr/bin/g++"`로 waveform dump를 끄고 host compiler를 지정.
- Xilinx simulation library와 생성된 IP는 기존 캐시를 사용하고 simv/runtime/kernel은 각 build에서 별도로 생성.
- 아래 log와 manifest에서 PASS, instruction count, cycles, clock 및 연결 geometry를 확인할 수 있다.
- 1회 측정이며, 다른 shape나 실물 FPGA의 nanosecond latency로 일반화하지 않는다.

| Candidate / version | Workload | Instructions | Core cycles | Kernel SHA256 | Log |
| --- | --- | ---: | ---: | --- | --- |
| C1_old | softmax | 3,906,203 | 947,342 | `678edd317ad38e82cbc6927b2cf46caac86888007cf3fed5b54665d3308bcdbb` | [C1_old/softmax/run.log](C1_old/softmax/run.log) |
| C1_old | tcu | 2,898,334 | 479,926 | `edb4b3e0732a5d9f062ef6dbcf4ff22e69a6d74435d9f47ecad00b1e4b160103` | [C1_old/tcu/run.log](C1_old/tcu/run.log) |
| C1_v2 | softmax | 3,914,395 | 942,559 | `9e1e458fa5dd3d937b62bb6633109fcb6727d69c6aa08e576d32618611678d82` | [C1_v2/softmax/run.log](C1_v2/softmax/run.log) |
| C1_v2 | tcu | 2,898,334 | 459,100 | `edb4b3e0732a5d9f062ef6dbcf4ff22e69a6d74435d9f47ecad00b1e4b160103` | [C1_v2/tcu/run.log](C1_v2/tcu/run.log) |
| C3_old | gemm_naive | 9,617 | 47,981 | `e02e64ff8a4e42ca33c0fe4d43dba867ee7e03c803c2c6206dc038715fd62ed2` | [C3_old/gemm/run.log](../../../../agent-tasks/c3-static-assert-cycle-compare-20261001_235906/C3_old/gemm/run.log) |
| C3_v2 | gemm_naive | 9,575 | 47,446 | `e02e64ff8a4e42ca33c0fe4d43dba867ee7e03c803c2c6206dc038715fd62ed2` | [C3_v2_fixed/gemm/run.log](../../../../agent-tasks/c3-static-assert-cycle-compare-20261001_235906/C3_v2_fixed/gemm/run.log) |
| C4_old | gemm_improve | 9,523 | 46,848 | `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177` | [C4_old/gemm_improve/run.log](C4_old/gemm_improve/run.log) |
| C4_v2 | gemm_improve | 9,523 | 46,848 | `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177` | [C4_v2/gemm_improve/run.log](C4_v2/gemm_improve/run.log) |

각 workload 폴더에 `command.sh`, `run.log`, `simv.log`, `compile.log`, `u55c_model_manifest.json`, `result.json`을 보존했다.
원본 설정은 `C1_old`, `C1_v2`, `C3_old`, `C3_v2`, `C4_old`, `C4_v2` 폴더에 보존했다.
