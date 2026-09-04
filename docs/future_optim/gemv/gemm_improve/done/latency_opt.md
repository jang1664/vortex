# 문제점

M=4 테스트에서 `gemm_unit_v2.i_lmem_bus_if.req_valid`는 한 input command마다
4개의 request를 1 cycle 간격으로 연속 발행한다. 그러나 일반적인 두 burst
사이에는 14 cycle의 빈 구간이 반복된다. 이 간격은 GEMM input interface의
backpressure가 아니라 다음 두 latency가 직렬로 더해져 발생한다.

## 1. Scale/ZP 완료가 다음 input command의 시작을 지연함

`S_MXU_ARM_GEMM`에서 발행되는 input command는 현재 MXU buffer의 weight와
scale/ZP가 모두 준비될 때까지 기다린다. Scale과 ZP는 별도의 command이지만
동일한 quant-parameter LDMA에서 순차 실행되며, scale/ZP 준비 완료를 나타내는
`RID_SZ`는 마지막 ZP register write가 발생한 뒤에야 갱신된다. 따라서 input
DMA가 먼저 idle 상태가 되더라도 ZP write가 끝나기 전에는 다음 input command를
시작할 수 없다.

예를 들어 FSDB의 57,295 ns 부근에서는 다음 순서가 관찰된다.

- 57,295 ns: 이전 4-request input burst 종료
- 57,325 ns: 이전 input DMA가 idle이 되고 weight 및 이전 GEMM dependency가 완료됨
- 57,335 ns: 다음 ZP LDMA command 시작
- 57,385 ns: ZP register write와 함께 `RID_SZ1` dependency가 만족됨
- 57,385 ns: 같은 cycle에 다음 input command 시작

즉 이전 burst가 끝난 뒤 다음 input command를 시작하기까지 9 cycle을
scale/ZP 경로의 완료가 지연시킨다. 대부분의 반복 구간에서 ZP register write가
다음 input command를 해제하는 마지막 dependency이다.

## 2. Input LDMA command 시작부터 첫 request까지 5 cycle이 필요함

Scale/ZP dependency가 해제되어 input command가 시작된 뒤에도
`i_lmem_bus_if.req_valid`가 즉시 발생하지 않는다. Input LDMA가 command를
수락하고 TMEM read를 발행한 뒤, read response를 내부 slot/write 경로로 전달하여
GEMM 입력 request로 변환하는 데 고정적으로 5 cycle이 걸린다.

같은 구간의 예시는 다음과 같다.

- 57,385 ns: input LDMA command 시작
- 57,405 ns: TMEM read request 시작 (`+2 cycles`)
- 57,415 ns: TMEM read response 도착 (`+3 cycles`)
- 57,435 ns: 다음 `i_lmem_bus_if.req_valid` burst 시작 (`+5 cycles`)

M=4에서는 유효한 input request가 4 cycle 동안만 발행되므로, command마다
추가되는 5-cycle 기동 latency가 실제 전송 시간보다 길다. 결과적으로 일반적인
burst 간격은 scale/ZP 완료 대기 9 cycle과 input LDMA 기동 5 cycle이 합쳐진
14 cycle이 된다.

# 해결책

## 우선순위 1. Scale과 ZP를 독립된 두 LDMA로 병렬 적재

현재 scale command와 ZP command는 같은 quant child queue와 quant LDMA를
공유하므로 반드시 순차적으로 실행된다. Quant 경로를 scale 전용
child queue/LDMA와 ZP 전용 child queue/LDMA로 분리하여 두 command가 서로
다른 executor에서 동시에 시작될 수 있게 한다.

단순히 child queue만 추가하고 기존 quant LDMA나 단일 `sz_lmem_bus_if`를
공유하면 실제 data transfer는 여전히 직렬화된다. 따라서 다음 경로를
함께 분리한다.

- `OP_SC_LDMA_MXU`와 `OP_ZP_LDMA_MXU`를 별도 opcode/child route로 분리
- GEMM child queue와 completion inflight slot을 5개에서 6개로 확장
- TMEM local DMA와 bank switch port를 input/weight/scale/ZP/output 경로로 확장
- GEMM unit의 qparam ingress를 scale write port와 ZP write port로 분리

독립 LDMA가 같은 TMEM bank를 동시에 읽으면 bank
arbiter에서 직렬화될 수 있으므로, scale과 ZP base에 서로 다른 bank
color를 부여하거나 최소한 두 command의 request/response pipeline이 실제로
overlap되는지 검증해야 한다.

Scale과 ZP가 서로 다른 cycle에 완료되므로, input command에 단순히
두 wait dependency를 추가하면 현재 4-entry `waits[]`를 초과한다. 기존
`RID_SZ` contract를 유지하기 위해 scale과 ZP의 준비 sequence를 각각
추적하고 두 값의 join을 qparam readiness로 사용한다.

```text
RID_SC[buf] = 마지막으로 완료된 scale sequence
RID_ZP[buf] = 마지막으로 완료된 ZP sequence
RID_SZ[buf] = min(RID_SC[buf], RID_ZP[buf])
```

Scale과 ZP completion은 서로 다른 RID를 update하므로 같은 cycle에 끝나도
sync update collision이 발생하지 않는다. Input command는 기존처럼 단일
`RID_SZ[buf] >= sequence`만 wait하면 되며, scale과 ZP 모두 완료되기 전에
시작될 수 없다. Scheduler에서는 same-cycle completion을 반영한
`effective_sync` view의 SC/ZP 값에 `min` join을 적용하여 `RID_SZ`를 판정한다.

QROW의 현재 회귀 범위인 `QBLK=32/64/128`에서는 scale과 ZP가
각각 64B one-beat이다. 성공 기준은 두 LDMA start가 동일한 준비
window에서 발생하고, scale/ZP register write가 병렬 또는 인접한 cycle에
완료되며, `RID_SZ` join이 마지막 completion과 같은 cycle에 갱신되는
것이다.

## 우선순위 2. Command-compatible pure-load prepare/release prefetch

Command의 기존 dependency를 제거하거나 command를 조기 issue하지
않는다. Prefetch는 immutable source에 대한 read만 미리 수행하는
non-architectural `prepare`로 정의하고, destination write나 consumer 전달은 기존
dependency가 모두 해제된 후의 `release`에서만 수행한다.

이 기준에서 현재 command의 prefetch 허용 범위는 다음과 같다.

| 경로 | Command | Prefetch | Prepare 대상 | Release 조건/동작 |
|---|---|---:|---|---|
| Local input | `OP_I_LDMA_ARM` | 허용 | TMEM input read | W/SC/ZP, prior GEMM, ACC free 후 GEMM으로 전달 |
| Local weight | `OP_W_LDMA_MXU` | 허용 | TMEM weight read | target weight register가 free인 후 write |
| Local scale | `OP_SC_LDMA_MXU` | 허용 | TMEM scale read | target scale register가 free인 후 write |
| Local ZP | `OP_ZP_LDMA_MXU` | 허용 | TMEM ZP read | target ZP register가 free인 후 write |
| Local output/psum | `OP_O_ACC2LMEM` | 금지 | - | GEMM/ACC completion 후에만 psum read 및 TMEM write |
| Tile input/weight/scale/ZP | `OP_DMA_LD`, `rd=0..3` | 허용 | DRAM source read | target TMEM buffer ownership 확보 후 TMEM write |
| Tile output | `OP_DMA_ST`, `rd=4` | 금지 | - | output 생성 후 TMEM read 및 DRAM write |

따라서 현재 **모든 local LDMA load**인 input/weight/scale/ZP와, 모든
**tile DMA load**인 input/weight/scale/ZP는 prefetchable이다. 반면 psum을 읽는
`OP_O_ACC2LMEM`과 외부에 side effect를 만드는 `OP_DMA_ST`는 prefetchable로
표시하지 않는다. 향후 opcode가 추가되어도 단순히 `LOAD`라는 이름으로
허용하지 않고, source read가 side-effect-free인지와 destination commit을
분리할 수 있는지를 기준으로 판정한다.

```text
child queue head의 prefetchable command
  -> prepare: source read를 미리 발행하여 bounded buffer에 저장
  -> wait: 기존 command dependency는 그대로 유지
  -> release: 모든 dependency가 해제된 뒤 normal issue_fire
  -> prepared beat를 command destination으로 commit
```

이 구조에서 command의 기존 `waits[]`는 **release dependency**다. Scheduler는
모든 release dependency가 만족되기 전에는 child queue를 pop하지 않고,
executor inflight metadata나 notify state도 시작하지 않는다. 따라서 기존
command-level correctness contract가 변하지 않는다.

Prepared state는 child queue head의 sequence와 묶어 둔다. 같은 command의
`issue_fire`가 발생하면 executor는 새 DMA를 중복 시작하지 않고 prepared
transaction을 release한다. Release 시점에 prepared beat가 없는 prefetch miss는
기존 normal-start path로 fallback하여 성능만 느려지고 동작은 바뀌지 않게 한다.

Prepare에도 source data가 TMEM에 준비되었다는 최소 dependency가 필요하다.
이를 위해 prefetch를 지원하는 command에 다음 sidecar metadata를 추가한다.

```text
prepare = {
    valid,
    mode,          // NONE 또는 SOURCE_READ
    waits[],       // source residency와 overwrite safety만 표현
    max_beats      // release 전에 미리 읽을 최대 beat 수
}
```

Input command의 구체적인 dependency 분리는 다음과 같다.

```text
prepare wait:
  RID_TILE[buf] >= tile_ready_target

release waits (기존 waits[] 유지):
  RID_W[mxu_buf]      >= sequence
  RID_SZ[mxu_buf]     >= sequence
  prior RID_G         >= target, if valid
  RID_ACC_FREE[group] >= reuse_target
```

Weight/scale/ZP local LDMA에서는 `RID_TILE`을 prepare wait로 사용하고,
target register의 이전 user인 `prior RID_G`를 release wait로 사용한다. 이러면
TMEM read는 먼저 시작할 수 있지만 live weight/scale/ZP register를 조기에
덮어쓰지 않는다.

Tile DMA load에서는 DRAM source가 invocation 동안 immutable이므로 별도
source-ready wait 없이 read request를 prepare할 수 있다. 단, response를 TMEM에
write하는 시점은 대응하는 ping-pong buffer의 이전 consumer가 끝나 ownership이
반환된 후여야 한다. Buffer가 아직 free가 아니면 HBM response를 bounded
prefetch slot에만 보관하고 TMEM commit을 release까지 막는다.

Prefetch buffer는 전체 `M` command를 담을 크기로 만들지 않고, 기존
input LDMA outstanding/prefetch slot을 재사용하는 bounded credit 구조로 만든다.
Release가 늦어지면 `max_beats`까지만 TMEM response를 받고 추가 read를
중지한다. Release 후에는 prepared beat를 먼저 drain하면서 나머지 read를
계속하므로, 적은 buffer로도 첫 request의 5-cycle 기동 latency를 숨길 수
있다.

`max_beats`는 command 종류별 compile-time knob로 독립 설정한다. 기본값은
input LDMA=4, weight LDMA=4, scale LDMA=1, zero-point LDMA=1이며, tile DMA는
active channel별 4다. 실제 선행 read 수는 이 credit, command descriptor의 남은
beat 수, executor의 available outstanding slot 중 최솟값으로 제한한다.

이 concept을 input 전용 특수 case로 만들지 않고 local LDMA와 tile DMA
executor가 공통으로 사용하는 선택적
2-phase contract로 정의한다.

```text
prefetchable=0: 기존처럼 waits 해제 후 issue/execute
prefetchable=1: prepare_waits 해제 후 prepare, 기존 waits 해제 후 release
```

Prepare는 consumer interface `valid`, register write, accumulator state, command notify에
아무런 변화를 주지 않아야 한다. Queue head가 바뀌거나 reset/cancel이
발생하면 해당 sequence의 prepared data를 invalidate한다. 초기 구현은 각 child
queue의 head command 하나만 prepare하여 command tag와 data buffer의 불일치를
막는다.

성공 기준은 다음과 같다.

- 모든 command의 normal `issue_fire`와 destination commit은 기존 release dependency가
  전부 만족된 cycle에만 발생한다.
- Input command release 시점에 첫 beat가 이미 prepared 상태이어서 기존
  5-cycle LDMA 기동 latency를 숨긴다.
- Weight/scale/ZP register와 TMEM ping-pong buffer를 이전 consumer가 사용 중일 때
  prefetch data가 해당 destination을 덮어쓰지 않는다.
- `OP_O_ACC2LMEM`과 `OP_DMA_ST`에서 prepare event가 절대 발생하지 않는다.

# 검증 계획

## 1. VCS unittest

모든 unittest는 configure된 `build` tree에서 system GCC/G++와 VCS를 사용한다.
실행 전에 target GEMM과 동일한 config를 source한다.

```bash
source configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh

make -C build/hw/unittest/gemm_ctrl SIM_EXEC=vcs run
make -C build/hw/unittest/lmem_dma_misal SIM_EXEC=vcs run
make -C build/hw/unittest/gemm_unit_v2 SIM_EXEC=vcs run
make -C build/hw/unittest/gemm_tmem_dma_ctrl SIM_EXEC=vcs run
make -C build/hw/unittest/gemm_node_improve SIM_EXEC=vcs run
```

각 unittest에 다음 directed case를 추가한다.

### Scheduler/FSM: `gemm_ctrl`

- SC와 ZP command가 서로 다른 child queue로 route되고 동시에 inflight가 될 수
  있는지 확인한다.
- SC/ZP가 SC-first, ZP-first, same-cycle 순서로 완료되는 경우를 모두 만들고,
  `RID_SZ=min(RID_SC,RID_ZP)`가 두 completion 중 느린 쪽의 sequence를
  따르는지 확인한다.
- `prepare_waits` 충족 후에도 기존 `waits[]`가 미해제이면 normal
  `issue_fire`, child queue pop, inflight push, notify가 발생하지 않아야 한다.
- `OP_O_ACC2LMEM`과 `OP_DMA_ST`는 prepare 대상으로 decode되지 않아야 한다.

### Local DMA: `lmem_dma_misal`

- Release를 막은 상태에서 TMEM read response를 `max_beats`까지 미리 받고,
  consumer-facing `req_valid`와 destination write는 발생하지 않는지 확인한다.
- Release cycle에 prepared first beat가 same-cycle 또는 next-cycle에 전달되고, 나머지
  beat가 순서와 `last` metadata를 보존하며 연속 전송되어야 한다.
- Prefetch miss에서는 기존 normal-start path로 fallback하고, backpressure 중
  data/tag/byte-enable이 변하지 않아야 한다.
- Reset/cancel 시 prepared sequence를 invalidate하고 다음 command에 이전 data가
  release되지 않아야 한다.

### Scale/ZP write ports: `gemm_unit_v2`

- Scale과 ZP 64B beat가 같은 cycle에 도착해도 각각 선택된 REG0/REG1에
  정확히 write되어야 한다.
- 한 qparam port의 backpressure가 다른 port를 불필요하게 막지 않아야 하며,
  live register는 `prior RID_G` 해제 전에 덮어쓰지 않아야 한다.

### Tile DMA: `gemm_tmem_dma_ctrl`

- `OP_DMA_LD`의 `rd=0..3`은 bounded DRAM read prepare를 허용하되, target TMEM
  buffer ownership이 해제되기 전에는 TMEM write를 막아야 한다.
- `OP_DMA_ST`/`rd=4`는 prepare request를 발생시키지 않아야 한다.
- Prepared load와 output store가 겹치는 경우에도 store priority, command tag,
  logical completion 순서가 유지되어야 한다.

### Node integration: `gemm_node_improve`

- Scale/ZP LDMA가 실제로 overlap되고 단일 qparam port에서 재직렬화되지 않는지
  확인한다.
- Input/weight/scale/ZP prepare가 시작된 후 release dependency를 인위적으로 늦춰도
  consumer-visible request나 register/TMEM write가 조기에 발생하지 않아야 한다.
- QCOL/QROW 모두에서 output data와 completion/notify count가 baseline과 동일해야 한다.

## 2. XRT-VCS functional regression

`ci/run_target_gemm.sh`는 내부에서 target config를 source하고
`ci/run_black.sh xrt-vcs-sim`을 호출한다. `N=256`, `K=256`, `QBLK=32`,
`WTRANS=0`, `WLOAD=8`을 고정하고 `M={4,256} x QDIR={0,1}`의 4개
조합을 검증한다.

```bash
ci/run_target_gemm.sh run --m 4   --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8 --rebuild
ci/run_target_gemm.sh run --m 4   --n 256 --k 256 --qblk 32 --qdir 1 --wtrans 0 --wload 8
ci/run_target_gemm.sh run --m 256 --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8 --timeout 3600
ci/run_target_gemm.sh run --m 256 --n 256 --k 256 --qblk 32 --qdir 1 --wtrans 0 --wload 8 --timeout 3600
```

4개 run 모두 application output verification이 PASS해야 하며, VCS
fatal/assertion, timeout, command count mismatch, stale prefetch data, register/TMEM overwrite가
없어야 한다. `M=4`는 짧은 input burst의 latency 개선을, `M=256`은
multi-tile/long burst에서 buffer credit, ping-pong reuse, backpressure 및 deadlock 없음을
검증한다.

## 3. FSDB latency verification

Full-design FSDB의 크기를 제한하기 위해 latency 측정은 `M=4`의 QCOL/QROW
두 case에서 GEMM node-only FSDB로 수행한다.

```bash
ci/run_target_gemm.sh fsdb-gemm --m 4 --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8
ci/run_target_gemm.sh fsdb-gemm --m 4 --n 256 --k 256 --qblk 32 --qdir 1 --wtrans 0 --wload 8
```

`tools/fsdb_cli` 로 다음 cycle을 추출하여 변경 전 baseline과 비교한다.

- Scale LDMA start/first request/last register write
- ZP LDMA start/first request/last register write
- `RID_SC`, `RID_ZP`, derived `RID_SZ` update
- Input prepare start/first TMEM request/first buffered response
- Input normal `issue_fire`/release/first `i_lmem_bus_if.req_valid`
- M=4의 4-request burst 종료에서 다음 burst 시작까지의 간격

성능 통과 기준은 다음과 같다.

- Scale과 ZP LDMA의 active window가 overlap되고, 두 completion을 join한
  `RID_SZ`가 마지막 completion과 같은 cycle에 충족되어야 한다.
- Input release 시점에 first beat가 prepared되어 있는 경우
  `issue_fire -> first req_valid`이 same-cycle 또는 1 cycle이어야 한다.
- Prefetch miss/backpressure case를 제외한 steady state에서 기존 5-cycle input LDMA
  기동 latency가 나타나지 않아야 한다.
- QCOL/QROW 모두에서 M=4 burst 간격이 기존 14 cycle보다 감소해야 하며,
  남은 gap은 dependency wait, TMEM bank conflict, prefetch miss로 분류할 수 있어야 한다.

# 실행 결과

2026-08-10 기준으로 두 우선순위의 RTL 구현과 계획된 검증을 완료했다.
VCS directed unittest와 `M={4,256} x QDIR={QCOL,QROW}` XRT-VCS 네 조합은
모두 numerical check, assertion, timeout 없이 통과했다.

`tools/fsdb_cli`로 기존 QROW baseline과 새 QCOL/QROW M=4 파형을 비교한
결과는 다음과 같다.

- SC/ZP 64쌍 모두 active window가 overlap했다. 63쌍은 같은 cycle에 시작하고
  1쌍은 인접 cycle에 시작했으며, 61쌍은 같은 cycle에 완료하고 3쌍은 인접
  cycle에 완료했다.
- `RID_SZ0/1`은 각각 32번 갱신되었고, 매번 같은 stored-state edge의
  `RID_SC/RID_ZP` minimum과 일치했다.
- Input prepare에서 첫 TMEM source request까지는 2 cycles, response까지는
  3 cycles였다. Release 전에 response가 저장된 6개 command는 release 후
  1 cycle에 첫 `req_valid`가 발생했다.
- 전체 64개 input command의 release-to-first-request 분포는
  1 cycle 6개, 2 cycles 52개, 3 cycles 6개로, 기존의 고정 5-cycle 기동
  latency가 사라졌다.
- 일반적인 M=4 burst 사이의 idle gap은 기존 14 cycles에서 8 cycles로
  감소했다(QCOL/QROW 각각 59/63 경계). 나머지 4개 경계는 weight completion
  dependency가 input release를 늦춘 경우였다.

현재 tile-major layout에서는 scale과 ZP base의 TMEM bank color가 같아
one-beat source request 자체는 보통 인접 cycle에 grant된다. 그러나 두 독립
LDMA의 active window와 register-write 경로는 overlap하며, 이를 위해 layout이나
ownership contract를 변경할 필요는 없었다.

# Hard Rule

구현 중 이 계획의 **핵심 RTL concept, 구조 또는 correctness invariant**를
유지할 수 없는 문제가 발견되면 즉시 구현을 멈추고 문제를 보고한다.
예를 들어 계획과 다른 architectural signal/handshake, dependency model, buffer
ownership 규칙 또는 datapath 구조가 필요하면 임의로 변경하지 않고 해결책을
먼저 논의한다.

반면 핵심 설계와 불변식을 바꾸지 않는 사소한 구현 상세는 진행 중에
수정해도 된다. Makefile/bash script 조정, build 문제 수정, unittest 추가,
SystemVerilog testbench bug 수정 등은 중단 조건이 아니다. 단, 이러한 문제가
핵심 RTL 설계의 전제가 틀렸음을 드러내면 즉시 중단·보고한다.
