# rev8 naive GEMM: FSDB로 확인한 HBM 포트 분포

2026-10-19. HEAD `d20c6b6b67dc59bce8a24be3a2a54f8b0c4372be`의 현재 작업 트리 RTL, xrt-vcs-sim, perf 3. 데이터 경로 RTL은 수정하지 않고 testbench의 선택적 파형 캡처만 추가했다.

## 결론

- FPINT의 weight DMA는 N14336에서 tile당 한 HBM AXI 포트에 집중된다. 실제 M1 K4096 N14336의 초기 두 tile에서 확인했다.
- N11008에서는 두 포트를 사용한다. FPFP는 행마다 256B를 읽어 네 포트를 사용한다.
- **편중의 존재와 성능 역전의 원인은 별개다.** 초기 tile의 read 시간은 N14336과 N11008이 거의 같다. 이 결과만으로 rev8 C2/C3가 C1보다 느린 원인을 포트 편중으로 확정할 수 없다.

## 실행 조건

| 경로 | Config | App |
|---|---|---|
| C3 FPINT | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh` | `fpint_gemm_ffn_hw_naive` |
| C1 FPFP | `configs/fpfp_th16_m16_n16_wload4_all_bram_acc.sh` | `fpfp_gemm_ffn_hw_naive` |

FPFP config의 실제 값은 ROW8/COL16/WLOAD1이다. 파일 이름의 m16/wload4는 실제 define과 다르다. C2의 FPINT 경로는 이번에 별도로 시뮬레이션하지 않았다. rev8 집계에서 C2 linear는 C3 측정값을 공유한다.

빌드는 `build_rev8_port_fpint`, `build_rev8_port_fpfp`로 분리했다. 각각 configure 후 config를 source하고 `CONFIGS`에 `-DFSDB_PORT_PROFILE`을 추가했다. 캡처는 네 외부 AXI 포트와 naive DMA executor에 한정했다.

## 파형에서 센 항목

`ap_clk` 상승 직전의 값으로 `ARVALID && ARREADY`, `RVALID && RREADY`를 계산했다. 물리 HBM 주소를 소프트웨어 주소로 역변환하고 weight 주소 범위를 골라, 128×128 DMA tile별로 분류했다. 응답은 포트·AXI ID·ARLEN으로 요청과 대응시켰다. 표의 read 수는 64B beat 수다.

전체 실행에서 포트 합계가 균등해도 tile별 편중은 있을 수 있다. 작은 FPINT case는 N tile이 바뀔 때 포트 0→1→2→3으로 이동했다. 큰 case에서 캡처한 두 tile은 N tile이 같고 K tile이 달라 둘 다 port 0을 사용했다.

## 전체 실행을 완료한 작은 case

M1 K128 N512, 기능 검증 모두 PASS.

| 경로 | kernel cycles | weight tile별 포트 0/1/2/3 read 수 | 첫 tile read window |
|---|---:|---|---:|
| FPINT | 12,377 | `[128,0,0,0]`, `[0,128,0,0]`, `[0,0,128,0]`, `[0,0,0,128]` | 480 cycles |
| FPFP | 14,583 | 네 tile 모두 `[128,128,128,128]` | 980 cycles |

FPINT는 한 tile당 8 KiB, FPFP는 32 KiB를 읽는다. 이 작은 case에서는 포트 편중이 있어도 FPINT가 더 빠르다. 전체 weight 수신량은 각각 32,768B/131,072B로 기대값과 일치했다.

## 실제 FFN stride의 초기 tile

FPINT는 원래 K4096을 사용했다. FPFP K4096은 약 6분 실행 후 관심 구간 캡처가 끝나지 않아 중단했으며, weight 주소 패턴을 결정하는 N14336을 유지하고 K256으로 줄였다. WTRANS=0에서 weight stride는 N으로 결정되므로 첫 두 K tile의 weight 주소·전송량은 같다. 다만 전체 GEMM 실행 비교는 아니다.

부분 캡처는 `VCS_SIMV_FLAGS="+port_profile_weight_tiles=2"`로 세 번째 weight descriptor가 보이는 순간 flush 후 종료했다. 따라서 **전체 GEMM PASS 및 전체 latency 측정이 아니다.** 이 의도적인 종료 때문에 host wrapper의 exit code는 2이고 transport/wait 오류가 남는다. `simv.log`의 `[PORT_PROFILE] bounded capture complete`가 정상적인 캡처 종료 표식이다.

| 경로 / shape | tile (K,N) | Port 0 | Port 1 | Port 2 | Port 3 | Read window (cycles) | 동시 2포트 이상 응답 cycle |
|---|---|---:|---:|---:|---:|---:|---:|
| FPINT M1 K4096 N14336 | k0_n0 | 128 | 0 | 0 | 0 | 485 | 0 |
| FPINT M1 K4096 N14336 | k1_n0 | 128 | 0 | 0 | 0 | 487 | 0 |
| FPINT M1 K4096 N11008 | k0_n0 | 64 | 0 | 64 | 0 | 491 | 3 |
| FPINT M1 K4096 N11008 | k1_n0 | 64 | 0 | 64 | 0 | 493 | 0 |
| FPFP M1 K256 N14336 | k0_n0 | 128 | 128 | 128 | 128 | 1050 | 131 |
| FPFP M1 K256 N14336 | k1_n0 | 128 | 128 | 128 | 128 | 1052 | 132 |

모든 캡처에서 AR backpressure는 0 cycle이고 요청·응답 불일치는 없었다. FPINT N14336의 R backpressure는 tile별 3/4 cycle, N11008 및 FPFP는 0이었다. FPFP는 tile당 131/132 cycle에서 실제로 여러 포트의 응답을 동시에 수락했다.

같은 INT4 데이터량에서 두 포트 case가 한 포트 case보다 빠르지 않았다(491/493 vs 485/487 cycles). FPFP는 4배의 데이터를 약 2.16배 시간에 읽었으므로 유효 전송률은 높지만, tile 전체 read 시간 자체가 FPINT보다 짧지는 않았다.

Read window는 첫 weight AR 수락부터 마지막 R 수락까지이며, 전체 DMA 작업이나 GEMM 실행 시간이 아니다. 초기 두 tile만 관측했으므로 정상 상태의 긴 실행에서 생기는 cache 충돌이나 연산과 DMA의 overlap까지 검증한 것은 아니다.

## 주소 패턴

`VX_axi_adapter.sv`는 64B line 주소의 하위 2bit로 4개 포트를 선택한다. WTRANS=0의 FPINT는 128열 tile 한 행당 64B, FPFP는 256B를 전송한다.

| shape / format | DRAM 행 stride | 64B line 단위 stride | 한 weight tile의 포트 |
|---|---:|---:|---|
| N14336 INT4 | 7,168B | 112 ≡ 0 (mod 4) | 1개 |
| N11008 INT4 | 5,504B | 86 ≡ 2 (mod 4) | 2개 |
| N14336 FP16 | 28,672B | 448 ≡ 0 (mod 4) | 행 자체가 4개 포트를 모두 사용 |

관련 RTL은 `hw/rtl/core/gemm/VX_naive_external_dma_executor.sv`의 T_WEIGHT와 `hw/rtl/libs/VX_axi_adapter.sv`의 req_hbm_sel이다.

## rev8 결과를 해석할 때의 한계

기존 HW 측정의 Llama3 Gate/Up M1 K4096 N14336은 C1 54.7714 ms, C3 79.15709 ms였다. 이번 실험은 같은 config의 **현재 소스 RTL 시뮬레이션**이며 과거 bitstream 자체의 파형이 아니다. 초기 tile 관측과 작은 case의 완주 결과는 포트 편중을 확인하지만, HW의 44.5% 차이를 그 편중 하나로 설명하지는 못한다. 원인을 확정하려면 긴 실행의 정상 상태에서 DMA 대기, cache miss/conflict, compute starvation을 함께 분리해야 한다.

## 재현 및 결과 파일

작은 case, 각 build directory에서 config source 후:

```bash
export CONFIGS="$CONFIGS -DFSDB_PORT_PROFILE"
./ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive \
  --args "-M 1 -K 128 -N 512" --perf 3
```

FPFP는 app을 `fpfp_gemm_ffn_hw_naive`로 변경한다. 큰 stride case는 FPINT `-K 4096 -N 14336` / `-K 4096 -N 11008`, FPFP `-K 256 -N 14336`을 사용하고 위 bounded capture plusarg를 설정한다.

파형은 각 build의 `captures/<shape>/vcs_cosim.fsdb`, 실행 로그는 `run_<shape>.log`에 보존했다. 분석기는 [analyze_fsdb.py](analyze_fsdb.py), 원시 집계 결과는 이 디렉터리의 JSON이다. 큰 shape 분석에는 `--partial`이 필요하다. 분석기는 요청/응답 누락 및 RLAST 불일치를 검사하고, 작은 완주 case에서는 전체 weight byte 수까지 검사한다.
