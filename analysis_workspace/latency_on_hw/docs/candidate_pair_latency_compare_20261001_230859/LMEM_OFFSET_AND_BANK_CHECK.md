# Naive GEMM의 LMEM bank 선택 및 scratch offset 확인

## 결론

- `main.cpp`의 기본 offset은 0이며, 원래 비교에도 별도 offset 인자를 주지 않아 실제 로그의 값이 0이다.
- 현재 bank 주소 계산은 전체 LMEM 용량이 2의 거듭제곱이라는 조건에 의존하지 않는다. 1.25 MiB / 1.5 MiB를 포함한 직접 RTL 검증을 통과했다.
- Offset을 1 MiB로 옮겨도 원본 C3 v2의 mismatch와 cycle은 동일했다. DMA cache ports만 1로 복원하면 같은 용량·offset=0·kernel binary에서 PASS했다.
- 따라서 이번에 관측한 실패는 잘못된 scratch offset이나 non-power-of-two bank 계산만으로 설명되지 않는다. `DMA_DCACHE_PORTS=2` 경로가 유력하며, 내부 RTL의 정확한 결함 위치까지 찾은 상태는 아니다.

## main.cpp의 실제 배치

`tests/regression/fpint_gemm_ffn_hw_naive/main.cpp:36`에서 `LMEM_OFFSET_BYTES=0`으로 초기화한다. `--lmem-offset`이 있으면 해당 값을 읽고, `compute_lmem_layout()`은 `LMEM_BASE_ADDR + LMEM_OFFSET_BYTES`부터 64 B 단위로 buffer를 배치한다. 실제 device capacity를 `vx_dev_caps(VX_CAPS_LOCAL_MEM_SIZE)`로 읽어 전체 범위를 검사한다.

이번 QBLK=32, QDIR=0의 tile scratch 배치는 아래와 같다. 주소는 LMEM base에 대한 상대값이며 끝 주소는 exclusive이다. GEMM 전체 shape보다 내부 128×128×128 tile 크기를 기준으로 예약한다.

| Buffer | Bytes | offset=0 범위 | offset=1 MiB 범위 |
| --- | ---: | --- | --- |
| ibuf0 | 32,768 | [0, 32,768) | [1,048,576, 1,081,344) |
| ibuf1 | 32,768 | [32,768, 65,536) | [1,081,344, 1,114,112) |
| wbuf0 | 8,192 | [65,536, 73,728) | [1,114,112, 1,122,304) |
| wbuf1 | 8,192 | [73,728, 81,920) | [1,122,304, 1,130,496) |
| scbuf0 | 1,024 | [81,920, 82,944) | [1,130,496, 1,131,520) |
| scbuf1 | 1,024 | [82,944, 83,968) | [1,131,520, 1,132,544) |
| zpbuf0 | 1,024 | [83,968, 84,992) | [1,132,544, 1,133,568) |
| zpbuf1 | 1,024 | [84,992, 86,016) | [1,133,568, 1,134,592) |
| obuf | 32,768 | [86,016, 118,784) | [1,134,592, 1,167,360) |
| psum | 65,536 | [118,784, 184,320) | [1,167,360, 1,232,896) |

합계는 184,320 B = 180 KiB이다. 기본 배치는 [0, 184320), 1 MiB offset 배치는 [1048576, 1232896)으로, C3 v2의 실제 용량 1,310,720 B = 1.25 MiB 이내에 모두 들어간다. 모든 buffer 시작 주소는 두 case에서 128 B에도 정렬되어 있다.

`LMEM_BASE_ADDR=STACK_BASE_ADDR=0x1ffc00000`이지만 scratch와 stack은 반대 방향이다. `kernel/src/vx_start.S:88`은 `sp=STACK_BASE_ADDR-(hart_id << STACK_LOG2_SIZE)`로 설정하고 stack은 아래로 자란다. Scratch는 LMEM base부터 위로 배치되므로 이번 구성에서 서로 겹치지 않는다. `LMEM_STACK_GUARD_BYTES`는 host 코드에 정의되어 있지만 현재 layout에서는 사용되지 않으며, 이 사실만으로 overlap이 생기지는 않는다.

## Bank 주소 계산

`hw/rtl/mem/VX_local_mem.sv:128`은 word address의 하위 `log2(NUM_BANKS)` 비트로 bank를 선택하고, 그 위 비트로 bank 내부 row를 선택한다. 현재 WORD_SIZE=8 B, NUM_BANKS=16이므로:

```text
word_offset = (byte_address - LMEM_BASE_ADDR) / 8
bank        = word_offset & 15
row         = word_offset >> 4
```

`SIZE`는 bank 선택 비트 수가 아니라 각 bank의 RAM depth를 결정한다. Bank의 RAM은 `WORDS_PER_BANK=SIZE/WORD_SIZE/NUM_BANKS`개의 row로 생성되며, ceiling address width로 주소를 표현한다.

| LMEM | Total words | Words per bank | Bank address bits |
| --- | ---: | ---: | ---: |
| 1,048,576 B | 131,072 | 8,192 | 13 |
| 1,310,720 B | 163,840 | 10,240 | 14 |
| 1,572,864 B | 196,608 | 12,288 | 14 |
| 2,097,152 B | 262,144 | 16,384 | 14 |

필요 조건은 bank 수와 word 크기가 각각 2의 거듭제곱이고, 전체 SIZE가 WORD_SIZE×NUM_BANKS의 배수라는 것이다. 현재 config는 모두 만족한다. `LMEM_LOG_SIZE`는 `ceil(log2(LMEM_SIZE))`여야 하고, LMEM base는 그 주소 window에 정렬되어야 한다. 현재 1.25 / 1.5 MiB config의 LMEM_LOG_SIZE=21 및 base 주소도 이 조건을 만족한다.

CPU의 local-memory 판별은 `hw/rtl/core/VX_lsu_slice.sv:78`에서 실제 `LMEM_SIZE`를 더한 끝 주소와 비교하므로, 2 MiB window 전체를 1.25 MiB SRAM으로 오인하지 않는다.

## 검증

- Existing `hw/unittest/lmem_capacity` test를 snapshot으로 복사하고 1.25 MiB case만 추가했다. 저장소 원본 RTL과 test 파일은 수정하지 않았다.
- 독립 `build_bankcheck`를 configure하고 C3 v2 config를 source한 뒤 VCS unit test를 실행했다.
- 첫 row, 마지막 physical row, 1 MiB 경계 전후의 모든 bank, 동일 bank 충돌, response backpressure, 최고 row의 byte-masked write를 검증했다.
- 1 / 1.25 / 1.5 / 2 MiB 모두 PASS. 별도로 네 용량의 유효 word 주소 전체를 열거하여 bank/row 조합의 collision·gap·범위 초과가 없는 것을 확인했다.
- 증거: [RTL log](lmem_bankcheck/sim.log), [테스트 source](lmem_bankcheck/tb_lmem_capacity.sv), [주소 mapping 검사](lmem_bankcheck/mapping_check.json).

## 같은 C3 v2에서 원인 분리

Workload: `-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1`.

| DMA cache ports | LMEM | Offset | Cycles | 검증 |
| ---: | --- | ---: | ---: | --- |
| 2 | 1.25 MiB | 0 B | 47,446 | FAIL (1,024 mismatches) |
| 2 | 1.25 MiB | 1,048,576 B | 47,446 | FAIL (1,024 mismatches) |
| 1 | 1.25 MiB | 0 B | 48,348 | PASS |

세 run의 kernel SHA256은 모두 `e02e64ff8a4e42ca33c0fe4d43dba867ee7e03c803c2c6206dc038715fd62ed2`로 동일하다. DMA cache ports를 1로 바꾼 run은 진단용 config 복사본을 사용했으며 원본 v2 config를 바꾼 것은 아니다.

진단용 override를 `--configs-extra -DDMA_DCACHE_PORTS=1`로 중복 지정한 초기 시도는 HBM config generator가 conflicting define으로 거부하여 시뮬레이션되지 않았다. 이후 중복 define 없이 config 복사본에서 해당 값 한 개만 바꾸어 위의 PASS 결과를 얻었다. 초기 실패 로그는 `C3_v2/gemm_naive_dma1_diagnostic`에 보존했다.

전체 candidate pair latency 결과는 [SUMMARY.md](SUMMARY.md)에 있다.
