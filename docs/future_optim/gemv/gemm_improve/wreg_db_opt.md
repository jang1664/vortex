# 문제점

현재 W/S/Z register는 하나의 1-bit `mxu_buf_q`를 공유하며 두 physical buffer를
같이 번갈아 사용한다. 그러나 세 resource의 실제 lifetime은 서로 다르다. Scale/ZP는
input admission에서 immutable snapshot으로 복사되면 원본 register의 lifetime이
끝나지만, Weight는 같은 input이 GEMM tree 입력에 도달하여 마지막 multiply가 old
weight를 읽을 때까지 원본 register를 유지해야 한다. 따라서 W/S/Z를 같은 pointer와
같은 bank 수로 묶는 것은 불필요한 coupling이다.

Resource별 last-consumer event를 추가하면 inactive register를 안전하게 더 일찍
reuse할 수 있다. 또한 Weight LDMA executor에 두 command context와 8개의 shared
response slot을 두면 CMD N의 destination write와 CMD N+1의 source read를 overlap할
수 있다. 그러나 Weight command의 consume dependency를 child issue 조건으로 사용하면
consume 전에는 command가 executor에 들어가지 못하므로, 추가한 context와 slot이
비어 있는 상태로 남는다. 결과적으로 register double buffering은 동작하지만
Weight source pipeline을 미리 채우지 못해 burst 간격이 계속 발생한다.

## GEMM completion과 W/S/Z last-consumer completion의 불일치

`prior_g_wait`는 register별 마지막 consumer가 아니라 직전에 ARM된 GEMM의
완료 RID/target을 저장하는 전역 dependency다. 이를 Current/Next W/SC/Z
LOAD에 사용하면 target register가 이미 free인 경우에도 다른 buffer를
사용하는 GEMM 완료까지 기다릴 수 있다.

반대로 `prior_g_wait`를 단순히 destination buffer별 `RID_G` dependency로
바꾸는 것도 안전하지 않다. Non-final I_LDMA command는 input packet을 GEMM
unit으로 보낸 후 완료되지만, packet은 아직 내부 pipeline의 resource consumer
stage에 도달하지 않았을 수 있다.

- Weight는 input이 GEMM tree 입력인 `PREALIGN_CTRL_IDX`에 도달할 때 consume됨
- QROW scale은 input scaler에서 consume됨
- QROW zero point는 prealign 이후 zero-point 연산에서 consume됨
- QCOL zero point는 activation reduce 이후에 consume됨
- QCOL scale은 `INT2FP_CTRL_IDX`의 output scaling에서 consume됨

따라서 GEMM command completion과 W/S/Z register consume completion을 별도 event로
관리해야 한다. `wreg_busy`, `sreg_busy`, `zreg_busy`와 LOAD bus의 `req_ready`는
최종 안전장치로 유지하되, resource별 consume fence가 실제 lifetime을 표현해야
한다. Weight는 이 fence를 child issue가 아니라 destination commit 시점에 적용한다.

## Weight double buffering은 동작하지만 LOAD execution이 느림

M=4 FSDB에서 Weight register double buffering 자체는 동작한다.

```text
Compute(wreg0) || Load(wreg1)
Compute(wreg1) || Load(wreg0)
```

`weight_consume_valid` 후 2 cycle에 관측되는 write는 consume된 register와 같은
register의 reuse write가 아니라, 이미 실행 중이던 반대편 register LOAD의 write다.
대표적으로 `consume(wreg0) -> write(wreg1)`과
`consume(wreg1) -> write(wreg0)`가 2 cycle이다. 이는 consume dependency latency가
아니라, 당시 도착한 source response가 response RAM read stage를 거쳐 destination
request로 나오는 pipeline 정렬의 결과다.

반면 consume된 register와 같은 register의 다음 write까지는 대부분 16 cycle이
걸린다. 하나의 `w_lmem_bus` write port를 공유하므로 현재 반대편 register의
4-beat burst를 먼저 끝내야 하는 것은 필요하다. 하지만 그 burst 이후에도 다음
burst가 즉시 시작하지 못하고 10 cycle의 `req_valid=0` 간격이 반복된다.

Writer-side source prefetch를 적용한 뒤 초기 세 command를 cycle 기준으로 보면
source overlap은 정상 동작하지만 2-bank Weight reuse가 GEMM-tree 이전 pipeline
latency를 숨기지 못한다.

```text
C0      W-LDMA1 enqueue -> WREG0
C1      W-LDMA2 enqueue -> WREG1
C7-C11  W-LDMA1 writes WREG0
C11     GEMM1 ARM start, WREG0 사용
C12-C15 W-LDMA3 source read와 W-LDMA2 WREG1 write overlap
C15     W-LDMA3 source payload 준비 완료
C16     W-LDMA2 WREG1 write 완료
C17-C19 W-LDMA3는 WREG0 overwrite fence 대기
C20     GEMM1의 WREG0 final consume
C21     W-LDMA3 WREG0 first write
```

즉 CMD3 source data는 C15에 이미 준비되고 destination port도 C16 이후 비어 있지만,
CMD3가 다시 WREG0을 사용하기 때문에 C20의 final consume까지 기다린다. 이 gap의
직접 원인은 response latency가 아니라 **두 Weight bank의 reuse distance보다
input-admission-to-GEMM-tree weight-sample lifetime이 길다는 것**이다.

Scale/ZP는 마지막 input admission에서 원본 register를 consume하고 이후 stage가
snapshot을 사용하므로 같은 문제가 없다. 따라서 Weight만 4-bank로 늘리고 Scale/ZP는
2-bank snapshot 구조를 유지하는 것이 resource lifetime에 맞다.

## 근본 원인: source execution과 overwrite dependency의 결합

Weight LDMA의 source read는 TMEM weight tile이 준비된 뒤에는 destination WREG의
lifetime과 무관하게 실행할 수 있다. 반면 WREG write는 기존 value의 마지막
consumer가 끝난 뒤에만 가능하다. 두 시점은 서로 다른 dependency를 갖는다.

현재 controller는 command의 모든 wait가 만족되어야 child command를 executor에
issue한다. Weight command에 `RID_W_CONSUME[target_buf]` wait가 들어 있으면 다음과
같이 source read까지 consume event 뒤로 직렬화된다.

```text
RID_TILE ready
  -> W_CONSUME를 기다림
  -> Weight command enqueue
  -> source request/response
  -> WREG write
```

따라서 두 command context와 8개의 shared response slot이 있어도 consume 전에는
다음 command가 executor에 없고, source request를 미리 발행할 수 없다. FSDB에서도
unresolved consume dependency 동안 Weight prepare는 accept되지 않았고, command는
consume과 같은 cycle에 enqueue된 뒤에야 source request를 시작했다. Steady-state
command boundary 대부분에서 다음 command의 source read가 이전 command의 write와
overlap하지 못한 이유가 이것이다.

즉 남은 병목은 response RAM 용량이나 destination ready가 아니라,
**WREG overwrite dependency가 Weight command의 source execution까지 막는 것**이다.

## Final consume cycle에도 `req_ready`가 낮은 보수적 1-cycle fence

`w_lmem_bus.req_ready`의 downstream 조건은 `wreg_wr_idx`가 가리키는 register의
`wreg_busy`를 검사한다.

```systemverilog
assign w_lmem_bus_if.req_ready = !wreg_busy[wreg_wr_idx];
```

Weight 입력에는 depth-1 `VX_pipe_buffer`가 있다. Writer head의 첫 beat가 pipe에
들어간 뒤 target WREG가 busy이면 pipe output이 막히고, 뒤의 beat는
`req_valid=1, req_ready=0`으로 기다린다. Final consumer가 있는 cycle에는
`weight_consume_valid=1`이지만 같은 `ctrl_pipe[PREALIGN_CTRL_IDX]` entry가 아직
`wreg_busy=1`을 만들므로 ready가 그 cycle에 올라오지 않는다.

```text
C20: req_valid=1, req_ready=0, WREG0 consume=1, wreg_busy[0]=1
C21: req_valid=1, req_ready=1, WREG0 actual write=1
```

이는 ready가 sequential signal이어서가 아니라, combinational ready 식이 final
consume을 same-cycle release로 보지 않기 때문이다. 마지막 GEMM-tree multiply는
clock edge에서 old weight를 capture하고 weight register는 같은 edge에서 new value로
갱신할 수 있으므로, 다른 same-bank consumer가 없다는 조건 아래 final consume과
overwrite를 같은 cycle에 허용할 수 있다.

또한 `wreg_busy`는 GEMM unit에 admission된 packet과 내부 consumer pipeline만
검사한다. ARM command는 accept됐지만 input packet이 아직 input LDMA 또는 node-to-unit
pipeline에 있는 구간에는 future consumer가 `wreg_busy`에 보이지 않는다. 이때
`req_ready`만으로 조기 WREG write를 허용하면, 뒤늦게 도착할 packet이 사용해야 하는
old weight를 overwrite할 수 있다. 따라서 `req_ready`는 현재 pipeline의 immediate
hazard를 막는 최종 gate로 유지하되, 정확한 consume RID/target을 writer-side fence로
별도로 확인해야 한다. Same-cycle release는 writer RID/target이 일치하고,
`PREALIGN_CTRL_IDX`의 final consumer 외에 같은 WREG를 사용하는 `input_fire` 또는
`ctrl_pipe[0:PREALIGN_CTRL_IDX-1]` entry가 없을 때만 허용한다.

## 기존 S_DONE command chaining은 충분하지 않음

`VX_dma_unit_align`에는 `S_DONE` completion handshake와 다음 descriptor accept를
겹치는 command chaining이 있다. 그러나 Weight local DMA path는 `lookahead.activate=0`으로
연결되어 이 기능을 사용하지 않는다.

이 chaining을 Weight에 연결하면 wrapper의 `S_DONE -> S_IDLE` bubble 약 2 cycle은
줄일 수 있다. 하지만 다음 command의 source read가 이전 command의 destination
write와 overlap되지 않으므로 start-to-first-write latency는 그대로 남는다. 따라서
S_DONE에서 빠르게 start하는 것만으로는 10-cycle burst gap을 제거할 수 없다.

## 4-bank Weight 이후에도 Input LDMA command가 직렬화됨

4-bank Weight와 writer-side fence를 적용한 뒤에는 WREG reuse가 다음 Input burst를
직접 막지 않는다. 그러나 M=4 XRT-VCS FSDB에서 I_LDMA command 하나가 만드는 4-beat
input burst 사이에는 여전히 다음과 같은 gap이 남는다.

```text
Input command 수                 : 64
Command당 input admission        : 4 beats
Burst 사이 idle gap              : median 9 cycles, min 9, max 16
i_lmem_bus.req_valid&&!req_ready  : 0 cycles
```

즉 GEMM unit이 input을 거절해서 생기는 gap이 아니라, 다음 command의
`req_valid` 자체가 늦게 발생하는 문제다. 대표적인 command boundary를 첫 input
admission 기준 상대 cycle로 나타내면 다음과 같다.

```text
C0-C3    CMD N의 4 input beats가 GEMM unit에 admission
C5       Input DMA transfer 종료
C6       wrapper S_DONE
C7       node input_cmd_done, RID_G 증가, CMD N+1 prior_g_wait 해제
C8       CMD N+1 start/config accept
C9       CMD N+1 S_COPY
C10-C12  source request/response 및 destination pipeline
C13-C16  CMD N+1의 4 input beats admission
```

따라서 C4-C12의 9 cycle이 비어 있다. 전체 trace에서 다음 Input child의 dependency는
직전 `input_cmd_done`과 같은 cycle에만 ready가 되었고, 다음 command start는 그 다음
cycle에 발생했다. 반면 해당 command가 필요로 하는 W/S/Z LOAD completion은 대표
boundary에서 이미 C1까지 완료되어 있었다. Input child queue도 최대 depth까지 차
있었으므로 command 생성 부족이나 W/S/Z 준비 지연이 baseline gap의 원인이 아니다.

근본 원인은 다음 세 구조가 Input command를 하나씩만 실행하게 하는 것이다.

- Input ARM의 `waits[]`에 W/S/Z, `prior_g_wait`, ACC_FREE가 모두 들어가 source issue까지 막음
- Controller가 Weight child만 multi-inflight로 취급하고 Input child는 single-active로 제한
- Input LDMA wrapper와 node가 각각 descriptor/context 하나만 저장

Input activation은 TMEM source가 생산된 뒤에는 pure input이다. 따라서 W/S/Z 또는
ACC dependency가 아직 풀리지 않았더라도 source read/response를 bounded slot에 미리
저장할 수 있다. 실제 dependency가 필요한 시점은 input data가 GEMM unit에 admission되어
W/S/Z snapshot/consume과 accumulator update를 시작하는 순간이다.

또한 `prior_g_wait`는 accumulator RAW를 보호하기 위해 다음 I_LDMA admission에 반드시
필요한 dependency가 아니다. GEMM unit은 command boundary를 포함하여 동일 accumulator
주소의 admission distance `d=1`은 immediate forwarding, `d=2`는 history forwarding,
`d>=3`은 갱신된 SRAM read로 처리한다. M=4 seamless micro-K에서는 같은 row의 재사용
거리가 4 cycle이므로 in-order admission만 보장하면 gap 없이 처리할 수 있다.

다만 W/S/Z ready만 확인하는 것으로는 충분하지 않다. 동일 accumulator group을 output이
사용 중인지 나타내는 ACC_FREE도 admission fence에 남겨야 한다. 또한 다음 tile DMA가
아직 source read가 끝나지 않은 input tile buffer를 overwrite하지 않도록 하는 buffer
reuse dependency는 계속 보존해야 한다.

## Input overlap 이후 Scale/ZP LOAD cadence가 최종 admission을 제한함

Input LDMA를 depth-4 command/context와 8 shared response slot 구조로 바꾼 뒤에는
`admission_ready=1 && req_valid=0`인 cycle이 없어졌다. 즉 다음 Input payload는 미리
준비된다. 그러나 M=4 QCOL/QROW FSDB에서 63개 Input burst boundary 중 zero-gap은
`2/63`뿐이고, nonzero boundary 대부분은 Scale/ZP LOAD completion을 기다린다.

Scale/ZP command는 각각 64 byte, 즉 한 번의 register write로 끝나는 1-beat
transfer다. 그런데 두 경로가 기존 single-command `VX_lmem_dma_misal` executor를
그대로 사용하므로 실제 data 크기보다 command lifecycle 비용이 크다. 첫 command의
대표 cycle은 다음과 같다.

```text
                    Scale       Zero point
LDMA command start    C0             C0
TMEM read request     C1             C1
TMEM response         C4             C5
register write        C6             C7
aligned DMA done      C7             C8
wrapper S_DONE        C9            C10
next command start   C10            C11
```

Steady-state register write는 Scale `C6, C15, C24, ...`, ZP `C7, C16, C25, ...`처럼
9-cycle 간격으로 발생한다. Register write port의 `req_ready`가 낮아서 늦는 것은 아니다.
Destination request는 나타난 cycle에 handshake한다. 근본 원인은 다음 command가 현재
command의 read, response, write, DMA done과 `S_DONE -> S_IDLE`을 모두 기다린 뒤에야
executor에 들어갈 수 있다는 것이다.

Scale과 ZP는 서로 다른 LDMA라 병렬 실행되지만 TMEM source bank arbitration 때문에
ZP response가 Scale보다 보통 1 cycle 늦고, 결과적으로 ZP가 마지막 admission blocker가
된다. 또한 같은 cycle qparam write/snapshot의 모호함을 피하기 위해 Input admission은
registered SC/ZP LOAD completion을 사용하므로 actual write 다음 cycle부터 새 version을
사용한다. 이 1 cycle은 correctness fence이고, 주된 9-cycle cadence의 원인은 아니다.

기존 Scale/ZP prefetch는 한 command 내부의 source beat를 release 전에 읽는 기능일 뿐,
다음 command descriptor와 source execution을 현재 command와 overlap하지 못한다. 따라서
prefetch max beat나 response slot 수만 늘려도 이 문제는 해결되지 않는다.

# 해결책

TMEM-to-register LOAD의 lifetime은 physical buffer별 W/SC/Z consume completion으로
관리한다. Weight LDMA는 dependency를 source execution과 destination commit으로
분리하고, **source는 조기에 실행하되 WREG write만 consume fence 뒤에 허용**한다.
Input LDMA도 같은 원칙으로 source execution과 GEMM admission을 분리한다. Input
activation은 tile-ready 뒤에 미리 읽어 shared response slot에 저장하고,
**W/S/Z와 ACC_FREE는 GEMM unit admission만 제한**한다. 두 executor 모두 command별
in-order read/write를 유지하면서 CMD N의 destination과 CMD N+1의 source를 overlap한다.
Scale/ZP LDMA도 command issue와 register overwrite를 분리한다. Source tile이 ready하면
consume completion 전이라도 여러 command를 executor에 넣어 TMEM data를 slot에
저장하고, **matching SC/ZP consume target과 GEMM register ready는 actual write만
제한**한다.

Physical register 구성과 allocation pointer는 resource별로 분리한다.

```text
Weight     : 4 bank, 2-bit circular pointer, GEMM-tree final read에서 consume
Scale      : 2 bank, 1-bit pointer, input snapshot에서 consume
Zero point : 2 bank, 1-bit pointer, input snapshot에서 consume
```

기존 `mxu_buf_q` 하나를 W/S/Z가 공유하는 규칙과 W/S/Z index equality assertion은
폐지한다. GEMM ARM은 `{wreg_use_idx[1:0], sreg_use_idx, zreg_use_idx}`를 독립 metadata로
전달한다. 각 resource의 정확한 LOAD-completion dependency는 command issue가 아니라
Input executor writer-head의 admission fence에서 확인한다.

Resource consume RID는 register overwrite의 correctness와 release 시점을 해결한다.
Command FIFO와 shared response slot은 consume 전에도 Weight source data를 bounded
storage에 미리 채워 DMA source pipeline을 saturate한다. 즉 Weight에서는 consume
dependency를 없애는 것이 아니라 child issue에서 writer commit으로 이동한다.
Input에서도 W/S/Z/ACC dependency를 없애는 것이 아니라 child issue에서 GEMM admission으로
이동한다. `prior_g_wait`만 다음 Input command 사이의 dependency에서 제거하고, ordered
writer와 accumulator forwarding이 command 순서를 보존한다.

## Resource별 consume completion RID 추가

Resource별 physical bank 수에 맞춰 다음 consume completion RID를 둔다.

```text
RID_W_CONSUME[0],  RID_W_CONSUME[1],
RID_W_CONSUME[2],  RID_W_CONSUME[3]
RID_SC_CONSUME[0], RID_SC_CONSUME[1]
RID_ZP_CONSUME[0], RID_ZP_CONSUME[1]
```

기존 `RID_W`, `RID_SC`, `RID_ZP`는 TMEM-to-register LOAD 완료를 의미하고, 새
RID는 GEMM datapath가 기존 register value를 더 이상 읽지 않는 시점을 의미한다.
두 종류의 event를 섞지 않는다.

GEMM ARM command가 accept될 때 W/S/Z 각각에 대해 ARM metadata가 선택한 physical
bank의 다음 consume target을 예약한다. Invocation 시작 시 resource/bank별
valid/expected count를 초기화한다. 이후 각 datapath의 실제 consume 완료 지점에서
해당 buffer의 RID를
한 번씩 증가시킨다.

Current와 next W/SC/Z LOAD command는 destination buffer와 resource 종류에 맞는
consume RID/target을 생성한다. W/SC/Z 모두 이 target을 command와 함께 전달하되 child
source issue를 막지 않는 writer commit fence로 사용한다.

- Current LOAD는 current resource pointer를 사용
- Next LOAD는 `next_w_buf=(w_buf+1) mod 4`, `next_s_buf=(s_buf+1) mod 2`,
  `next_z_buf=(z_buf+1) mod 2`를 사용
- W_LDMA source issue는 tile-ready만 기다리고,
  `RID_W_CONSUME[w_buf]`는 destination write 시점에 기다림
- SC_LDMA source issue는 tile-ready만 기다리고,
  `RID_SC_CONSUME[s_buf]`는 destination write 시점에 기다림
- ZP_LDMA source issue는 tile-ready만 기다리고,
  `RID_ZP_CONSUME[z_buf]`는 destination write 시점에 기다림
- 해당 buffer의 이전 consumer가 없으면 consume dependency를 추가하지 않음

W/SC/Z LOAD는 source tile이 ready이고 대응 executor command FIFO에 빈 entry가 있으면
consume target의 도달 여부와 무관하게 실제 issue한다. FIFO entry는 destination
buffer와 consume RID/target을 저장하고, source read/response는 즉시 진행한다.
Writer head는 matching consume target이 도달할 때까지 payload를 shared response
slot에 보관한다. Passive prepare context는 streaming의 필수 조건이 아니다.

## Weight consume completion과 busy 범위

Weight는 크기가 커 input packet과 함께 pipeline하기 어렵다. 기존 weight
register를 GEMM tree가 직접 읽는 구조를 유지하고, 마지막 input packet이 GEMM
tree 입력에 도달해 기존 weight를 읽은 시점에
`RID_W_CONSUME[wreg_use_idx]` completion을 발생시킨다.

`w_lmem_bus_if.req_ready`는 immediate pipeline hazard에 대한 최종 안전장치로 유지하되, 현재처럼
`WRITE_CTRL_IDX`까지 전체 pipeline을 scan하지 않고 실제 마지막 weight read
stage까지만 scan한다.

```systemverilog
wreg_busy[idx]
    = current input_fire가 idx를 사용하는 경우
    | ctrl_pipe[0:PREALIGN_CTRL_IDX] 중
      valid && (wreg_use_idx == idx)인 entry가 있는 경우;

assign w_lmem_bus_if.req_ready = !wreg_busy[wreg_wr_idx];
```

`PREALIGN_CTRL_IDX` entry는 그 cycle에 GEMM tree가 old weight를 읽으므로 일반적인
busy scan 범위에는 포함한다. 다만 그 entry가 해당 ARM의 final consumer이고 같은
bank의 다른 consumer가 없으면, GEMM-tree multiplier가 old value를 capture하는 edge에
새 weight를 register에 기록하는 same-cycle overwrite를 허용한다. Writer는 다음
조건을 만족할 때 destination request를 commit한다.

```text
writer_can_commit
    = matching W_CONSUME RID/target reached
    && (!wreg_busy[target_buf]
        || same_cycle_final_consume[target_buf])

same_cycle_final_consume[idx]
    = weight_consume_valid
    && weight_consume_idx == idx
    && input_fire가 idx를 사용하지 않음
    && ctrl_pipe[0:PREALIGN_CTRL_IDX-1]에 idx consumer가 없음
```

첫 조건은 아직 GEMM unit에 도착하지 않은 future consumer까지 보호하고, 두 번째
조건은 현재 consumer pipeline의 immediate hazard를 보호한다. Same-cycle overwrite에서는
final multiply가 old weight를 사용하고 다음 packet부터 new weight를 사용하는지
old/new nonuniform weight로 검증한다. Matching consume가 아니거나 같은 bank의 다른
consumer가 남아 있으면 실제 weight write handshake가 발생하지 않아야 한다.

## Weight 4-bank circular versioning

GEMM-tree 내부 Weight storage를 2-bank에서 4-bank로 확장한다. `in_weight_sel_i`,
`out_weight_sel_i`, `wreg_wr_idx`, `wreg_use_idx`, `weight_consume_idx`는 모두 2-bit로
확장한다. Weight bank allocation은 modulo-4 circular pointer를 사용한다.

```text
logical GEMM 0 : W0
logical GEMM 1 : W1
logical GEMM 2 : W2
logical GEMM 3 : W3
logical GEMM 4 : W0 reuse, RID_W_CONSUME[0] target 확인
```

Circular pointer는 bank가 free라고 가정하지 않는다. 각 W_LDMA entry가 destination
bank와 그 bank의 정확한 consume target을 저장하고 writer-side fence로 확인한다.
따라서 compute가 느려 네 bank가 모두 live인 경우에는 source를 bounded FIFO/slot까지
prefetch한 뒤 writer가 정상적으로 backpressure된다.

4-bank의 목적은 consumer latency 자체를 줄이는 것이 아니라 producer가 같은 bank를
재사용하기까지의 거리를 늘려 고정 latency를 숨기는 것이다. 초기 M=4 timeline에서는
CMD3가 WREG0 consume을 기다리지 않고 WREG2에 기록되므로, source가 C15에 준비되고
이전 burst가 C16에 끝난 뒤 C17부터 destination write를 시작하는 것을 목표로 한다.
평균 Weight 생산률이 GEMM 소비율보다 계속 빠르면 유한한 bank는 결국 차므로,
4-bank를 무한 streaming 보장으로 해석하지 않는다.

## Weight LDMA in-order overlap execution

Weight LDMA에 최소 depth 2의 command FIFO를 둔다. FIFO entry는 descriptor,
command tag/entry ID, destination `wreg_idx`, writer commit용 consume RID/target,
release bit, command별 read/write 진행 정보를 저장한다. 하나의 active descriptor만
유지하는 대신 다음 포인터를 분리한다.

```text
rd_cmd_ptr   : 현재 source read request를 발행하는 command
wr_cmd_ptr   : 현재 response RAM을 drain하여 destination write하는 command
cmd_tail_ptr : 다음 command enqueue 위치
```

`rd_cmd_ptr`와 `wr_cmd_ptr`가 서로 다른 FIFO entry를 가리킬 수 있게 하여
다음 execution을 허용한다.

```text
CMD N     : destination write issue
CMD N + 1 : source read issue
```

Read request는 command 단위로 in-order를 유지한다.

- CMD N+1의 첫 `src_req_fire`는 CMD N의 마지막 `src_req_fire` 이후에만 허용
- CMD N의 마지막 source response, destination write 또는 command done은 기다리지 않음
- Source request bus가 하나이므로 두 command의 read request를 cycle별로 interleave하지 않음

Write request도 command 단위 in-order를 유지한다.

- CMD N+1의 첫 `dst_req_fire`는 CMD N의 마지막 `dst_req_fire` 이후에만 허용
- CMD N+1의 payload를 response RAM에서 조기 read하여 output stage에 준비하는 것은 허용
- CMD N의 last write와 동시에 next payload RAM read를 수행하여, 다음 cycle에
  CMD N+1의 first write가 나올 수 있도록 함

Executor의 bus completion은 read issue 종료가 아니라 해당 FIFO entry의 마지막
destination write handshake를 기준으로 in-order 발생시킨다. Node의 Weight boundary
queue는 이 bus completion과 실제 `weight_register_write`를 함께 추적하며, controller에
보내는 command completion은 마지막 actual WREG write 시점에만 발생시킨다. 이로써
기존 command tag, notify, dependency completion 순서를 유지하고, 중간 input pipe에
data가 들어간 것만으로 command가 조기 완료되지 않게 한다.

## 8-entry shared response slot

두 inflight Weight command의 source response는 하나의 8-entry `response_payload_ram`을
공유한다. WLOAD=8 설정에서 command당 weight data가 4 beat이므로, 8 slot이면
CMD N과 CMD N+1의 payload를 동시에 보유할 수 있다.

```text
CMD N     response -> shared slot 0..3
CMD N + 1 response -> shared slot 4..7
                       |
                       +-> single in-order destination writer
```

Slot은 command별로 고정 partition하지 않고 전역 ring allocator로 할당한다. 현재의
`SLOT_FREE`, `SLOT_WAIT_RSP`, `SLOT_READY`, `SLOT_DRAINING` state를 유지하되
slot lifetime을 `cmd_start`마다 reset하지 않고 모든 inflight command가 공유하도록 한다.

- Source request tag는 3-bit global slot ID를 사용
- Response는 tag의 slot ID로 RAM에 저장
- Writer는 global `wr_expect_slot` 순서로 drain
- Response가 out-of-order로 도착해도 writer는 expected slot이 `SLOT_READY`가 될 때까지 기다림
- Slot의 command owner/sequence ID를 assertion/debug metadata로 저장

현재 `W_RD_OUTSTANDING`은 command당 4 beat와 response slot/wide-read context 수를
하나의 값으로 결합한다. 이 의미를 다음과 같이 분리한다.

```text
W_LDMA_CMD_BEATS      = 4  // WLOAD=8의 command payload/layout invariant
W_LDMA_RESPONSE_SLOTS = 8  // 두 inflight command의 shared payload capacity
```

TMEM wide-read switch도 0..7 global slot tag를 수용할 수 있도록 8 context/3-bit tag로
확장한다. 이를 통해 실제 source request 8개가 아직 destination에 write되지
않은 상태에서도 충돌 없이 tracking될 수 있게 한다.

## Weight source issue와 writer commit dependency 분리

Weight command의 dependency를 다음 두 종류로 분리한다.

```text
source issue dependency : RID_TILE[target_tile] ready
writer commit dependency: RID_W_CONSUME[target_buf] target reached
```

`RID_TILE`은 Weight LDMA가 읽을 TMEM source가 생산 완료됐는지를 나타내므로 제거하면
안 된다. 반면 `RID_W_CONSUME`는 destination WREG overwrite 시점만 제한하므로 Weight
child issue 조건에서는 제외한다. 즉 "Weight child dependency를 비운다"는 것은
consume wait를 source issue 조건에서 제거한다는 의미이며, source producer의
tile-ready dependency까지 제거한다는 의미가 아니다.

FSM은 Weight command마다 기존 consume RID/target을 생성하되 일반 `waits[]`에서
writer commit metadata로 이동한다. Controller의 Weight child는 source dependency가
ready이고 FIFO capacity가 있으면 이전 command completion이나 consume completion을
기다리지 않고 command를 accept한다. Controller는 depth-2 Weight inflight entry별로
commit RID/target을 보관하고, `effective_sync[commit_rid]`가 target에 도달하면 해당
command의 release bit/token을 node의 Weight executor에 전달한다.

Command accept 시점에 target이 이미 도달했거나 consume dependency가 없는 initial
LOAD는 entry를 처음부터 released 상태로 만든다. 아직 target이 도달하지 않은
경우에는 이후 consume event로 release한다. 따라서 command issue보다 먼저 발생한
consume event도 유실되지 않는다. Release가 늦게 도착해도 source engine은 command의
payload를 shared slot에 미리 채울 수 있다. Writer는 FIFO head의 release bit와
`w_lmem_bus_if.req_ready`가 모두 true일 때만 destination request를 발생시킨다.
두 번째 command의 release가 먼저 도착하더라도 write와 completion은 FIFO 순서를
추월하지 않는다.

다음 correctness invariant를 assertion으로 검증한다.

- Tile/source-ready가 아닌 Weight command는 FIFO에 accept되지 않음
- W_CONSUME가 ready가 아니어도 Weight command와 source read는 FIFO/slot capacity까지 진행 가능
- Matching W_CONSUME target 전에는 같은 buffer의 destination write가 발생하지 않음
- 다른 buffer, stale target 또는 later command release가 writer head를 잘못 release하지 않음
- CMD N+1 read는 CMD N의 last read request보다 먼저 발생하지 않음
- CMD N+1 write는 CMD N의 last write request보다 먼저 발생하지 않음
- `SLOT_FREE`가 아닌 slot에 새 request를 할당하지 않음
- Response tag의 slot은 반드시 `SLOT_WAIT_RSP`이어야 함
- Busy인 target wreg에 destination write handshake가 발생하지 않음
- Command completion/tag/notify는 FIFO 순서와 일치함

이 구조에서 목표 timing은 consume을 기다리는 동안에도 최대 두 command, 8 beat의
source request/response를 미리 준비하는 것이다. Matching consume과 `wreg_busy`
해제가 완료된 시점에는 source latency를 다시 지불하지 않고 writer가 이미 준비된
payload를 drain해야 한다. 연속 두 command가 모두 write-ready이고 destination bus에
backpressure가 없다면 CMD N의 last write 다음 cycle에 CMD N+1의 first write를
내보내 10-cycle burst gap을 0~1 cycle로 줄이는 것을 목표로 한다.

## Scale/ZP multi-command source overlap과 writer fence

Scale과 Zero-point에 각각 독립적인 multi-command executor를 둔다. 두 resource 사이에서
descriptor FIFO나 response RAM을 공유하지 않고, 각 executor 내부의 모든 inflight
command가 하나의 slot ring을 공유한다.

```text
Scale executor      : depth-4 command FIFO + 8 shared response slots
Zero-point executor : depth-4 command FIFO + 8 shared response slots
Source order        : resource별 command/beat in-order
Write order         : resource별 command/beat in-order
```

M=4/QBLK=32에서 SC/ZP command 하나는 각각 64 byte, 1 beat다. 네 descriptor를 미리
accept해도 executor별 payload는 4 slot만 사용하므로 기존 8-slot capacity 안에 들어간다.
Scale과 ZP를 합친 평균 source bandwidth도 Input 4 cycle당 2 beat이므로, 두 resource가
같은 TMEM bank에서 한 cycle에 하나씩만 grant되어도 필요한 평균 bandwidth를 만족한다.
Bank arbitration은 ZP가 Scale보다 1 cycle 늦어질 수 있지만 9-cycle single-command
lifecycle을 반복할 이유는 없다.

각 FIFO entry는 complete descriptor, destination `sreg_idx` 또는 `zreg_idx`, exact
consume RID/target, command sequence와 read/write progress를 저장한다. Dependency를
다음처럼 분리한다.

```text
SC source issue dependency : RID_TILE[source_tile] ready
SC writer commit dependency: RID_SC_CONSUME[s_idx] target reached

ZP source issue dependency : RID_TILE[source_tile] ready
ZP writer commit dependency: RID_ZP_CONSUME[z_idx] target reached
```

Source request와 response 수신은 writer fence와 무관하게 FIFO/slot capacity까지 진행한다.
Destination writer는 oldest command만 선택하며 다음 두 조건이 모두 true일 때 actual
register write를 발생시킨다.

```text
SC writer_can_commit
    = matching RID_SC_CONSUME target reached
   && sc_lmem_bus_if.req_ready;

ZP writer_can_commit
    = matching RID_ZP_CONSUME target reached
   && zp_lmem_bus_if.req_ready;
```

Exact RID/target은 아직 Input executor에 대기 중인 future consumer까지 보호한다.
GEMM-unit ready는 현재 admission edge에서 같은 bank를 snapshot하는 immediate hazard를
보호하는 두 번째 gate다. Busy/ready만으로 future version을 구분할 수 없으므로 writer
fence를 대체해서는 안 된다.

Scale/ZP는 Weight와 달리 same-cycle final-consume/write bypass를 기본적으로 사용하지
않는다. 마지막 Input packet의 old qparam snapshot이 끝난 다음 cycle에 미리 읽어둔 새
payload를 register에 쓰고, registered LOAD completion이 그 다음 cycle부터 Input
admission에 보이게 한다. 2-bank reuse 간격은 M=4에서 4 cycle이므로 이 write/completion
latency를 반대 bank의 Input burst 안에 숨길 수 있다. Same-cycle qparam write/snapshot이
필요해지는 경우에만 write data를 snapshot input으로 전달하는 명시적 bypass를 별도
설계한다.

Command completion과 notify는 source response나 slot fill 시점이 아니라 해당 entry의
마지막 actual SC/ZP register write handshake에서 발생한다. Later entry의 fence가 먼저
ready여도 write와 completion은 FIFO head를 추월하지 않는다. Reset/invocation abort는
descriptor, slot owner, writer wait와 completion metadata를 함께 무효화한다.

이 구조의 목표는 SC/ZP source payload를 consume 전에 준비하여, matching snapshot
consume 뒤 source latency나 `S_DONE -> S_IDLE` tail을 다시 지불하지 않는 것이다.
Input CMD1-4가 사용하는 alternating S0/S1 및 Z0/Z1 version이 제때 준비되어 네 4-beat
Input burst가 back-to-back으로 admission되는 것을 최종 성능 조건으로 둔다.

## Input LDMA source issue와 GEMM admission dependency 분리

Input command의 dependency를 다음 두 종류로 분리한다.

```text
source issue dependency : RID_TILE[input_tile_buf] ready
GEMM admission fence    : RID_W[w_idx], RID_SC[s_idx], RID_ZP[z_idx],
                          RID_ACC_FREE[acc_group] target reached
```

`RID_TILE`은 Input LDMA가 읽을 source tile이 생산 완료됐음을 나타내므로 source issue
조건에 남긴다. W/S/Z와 ACC_FREE는 source read correctness와 무관하고 실제 input이
GEMM unit에 들어가는 시점만 제한하므로 일반 child issue `waits[]`에서 제거하고
command별 admission metadata로 이동한다. 다음 I_LDMA를 직전 GEMM completion에
직렬화하던 `prior_g_wait`는 source issue와 admission fence 모두에서 제거한다.

Input executor는 descriptor/context FIFO와 하나의 shared response RAM을 사용한다.
Read와 destination admission은 각각 command 단위 in-order를 유지한다.

- Source request는 CMD N의 마지막 source request 뒤에 CMD N+1을 시작
- Source response는 global slot tag로 저장하며 W/S/Z/ACC가 ready가 아니어도 수신 가능
- Destination writer는 FIFO head command만 GEMM unit에 전달
- Head의 네 admission dependency가 모두 ready일 때만 input request handshake 허용
- CMD N의 마지막 input admission 다음 cycle에 CMD N+1의 첫 admission을 허용
- Later command의 dependency가 먼저 ready여도 writer command 순서를 추월하지 않음

M=4에서는 command당 4 beat이므로 8 response slot이면 두 command payload를 동시에
보유할 수 있다. 그러나 Weight와 동일한 depth-2 command context만 사용하면 CMD1이
끝난 뒤에야 CMD3 descriptor를 받을 수 있고, 현재 약 5-cycle인 source start-to-first-data
latency를 CMD2의 4-cycle drain만으로 완전히 숨기기 어렵다. 따라서 Input은 다음 구성을
기본으로 한다.

```text
Input command/context FIFO : depth 4
Shared response slots      : 8
Source issue order         : command/beat in-order
Destination order          : command/beat in-order
```

Slot은 두 command payload만 저장하지만 descriptor 네 개는 미리 accept한다. CMD0을
drain하여 slot이 하나씩 free될 때 이미 queue에 있는 CMD2 source read가 그 slot을
채우고, CMD1을 drain하는 동안 CMD3 source read를 진행한다. 따라서 이상적인 M=4
steady state는 다음과 같다.

```text
C0-C3    CMD0 admission, CMD2 source refill 시작
C4-C7    CMD1 admission, CMD2/CMD3 source refill
C8-C11   CMD2 admission
C12-C15  CMD3 admission
```

Controller Input child도 depth-4 ordered inflight metadata를 허용한다. Executor가 새
descriptor를 받을 수 있으면 이전 Input command completion을 기다리지 않고 command를
issue한다. Command FIFO full, response slot full 또는 source tile not-ready일 때만 source에
정상 backpressure를 건다.

Admission dependency는 단순 `wreg_busy/sreg_busy/zreg_busy`가 아니라 command가 저장한
정확한 `{RID, target}`으로 비교한다. Busy bit는 이전 version과 새 version을 구분하지
못하므로 LOAD-completion 확인을 대체할 수 없다. Controller의 relevant sync level을
Input executor/node까지 전달하여 writer-head entry의 target과 비교하고, 최종
`input_admission_ready` 한 비트를 GEMM unit에 전달한다.

```systemverilog
input_admission_ready
    = input_head_valid
   && w_load_target_ready
   && sc_load_target_ready
   && zp_load_target_ready
   && acc_group_free_target_ready;

assign i_lmem_bus_if.req_ready = input_admission_ready;
assign input_fire = i_lmem_bus_if.req_valid
                  && i_lmem_bus_if.req_ready;
```

현재 GEMM unit의 `input_fire=req_valid`와 `req_ready=1` 가정은 반드시 handshake 기반으로
변경한다. Ready가 0인 동안 DMA는 `req_valid`, payload와 writer-head context를 안정적으로
유지하고, node의 packet index와 GEMM unit control pipe는 실제 `input_fire`에서만
진행해야 한다. Fixed-latency compute pipeline은 accepted packet만 삽입하고 기존처럼
bubble을 허용하므로 내부 stage 전체를 stall할 필요는 없다.

Resource completion과 동일 cycle의 admission 규칙은 resource별로 다르게 적용한다.

- Weight는 register write 뒤 실제 GEMM-tree read까지 pipeline latency가 있으므로,
  matching actual WREG write completion을 same-cycle admission에 bypass할 수 있음
- Scale/ZP는 input admission edge에서 immutable snapshot을 capture하므로 같은 bank의
  register write와 same-cycle admission을 기본적으로 금지함
- Scale/ZP same-cycle release가 필요하면 write data를 snapshot input으로 명시적으로
  bypass해야 하며, 이 bypass 없이는 registered completion을 다음 cycle부터 사용

Input command completion은 source read 완료가 아니라 consumer-side progress를 기준으로
ordered하게 유지한다.

- 일반 command: 마지막 input beat가 GEMM unit에 실제 admission된 시점
- `notify_on_writeback` command: 해당 command의 마지막 accumulator writeback 시점
- `RID_G` notify/tag retirement: command FIFO 순서 유지

다음 tile의 DMA LOAD가 아직 읽고 있는 input tile buffer를 overwrite하지 않도록 하는
buffer-reuse dependency와, ACC2LMEM이 final GEMM writeback을 기다리는 dependency는
계속 유지한다. 제거 대상은 오직 다음 I_LDMA source/admission을 직전 `RID_G` completion에
묶던 dependency다.

## Scale/ZP snapshot pipeline과 consume completion

Scale과 zero point는 각각 32 lane x 16 bit로 weight보다 작으므로, input packet이
GEMM unit에 admission될 때 선택된 register vector를 snapshot하여 input/control과
함께 pipeline한다. GEMM unit 내부의 기존 `scale_regs`와 `zero_regs`는 LDMA의
staging register로 그대로 유지한다.

Snapshot 이후의 연산은 mutable register를 다시 읽지 않고 packet과 함께 전달된
값만 사용한다.

- QROW scale snapshot은 input scaler에 전달
- QROW zero-point snapshot은 prealign 이후 zero-point 연산에 전달
- QCOL zero-point snapshot은 activation reduce 이후 연산에 전달
- QCOL scale snapshot은 `INT2FP_CTRL_IDX`의 output scaler까지 전달

한 I_LDMA command의 마지막 input packet이 scale/ZP snapshot을 완료하면 각각
`RID_SC_CONSUME[sreg_use_idx]`와 `RID_ZP_CONSUME[zreg_use_idx]`를 증가시킨다.
Logical input packet은 뒤쪽 pipeline에서 복사된 값을 계속 사용하지만, 원본
register의 consume는 snapshot 시점에 끝났으므로 이후 overwrite가 안전하다.

각 packet마다 1024 bit의 SC/ZP vector를 전체 pipeline에 무조건 복제하지 않도록
QDIR과 실제 consume stage에 맞춘 별도 delay path를 사용한다. 마지막 packet의
snapshot이 완료되기 전 overwrite, 동일 cycle read/write ordering, consume event의
중복 또는 누락을 assertion으로 검증한다.

## W/S/Z 독립 pointer와 ARM metadata

W/S/Z가 하나의 `mxu_buf_q`와 equality invariant를 공유하는 구조를 폐지한다.

```text
w_buf_q[1:0] : modulo-4 Weight bank pointer
s_buf_q      : modulo-2 Scale bank pointer
z_buf_q      : modulo-2 Zero-point bank pointer
g_buf_q      : GEMM completion ordering용 logical pointer
```

기본 schedule에서는 S/Z가 같은 ARM마다 함께 toggle되므로 우연히 같은 값을 가질 수
있지만, correctness가 이 equality에 의존하면 안 된다. ARM command는 세 index를
독립적으로 encode하고 node/input context/snapshot pipeline이 그대로 전달한다.

```text
flags[6]   = quant_dir
flags[5]   = notify_on_writeback
flags[4]   = is_accum
flags[3:2] = wreg_use_idx
flags[1]   = sreg_use_idx
flags[0]   = zreg_use_idx
```

기존 `RID_SZ[buf]=min(RID_SC[buf], RID_ZP[buf])`는 S/Z가 같은 physical buffer를
사용한다는 전제가 있으므로 ARM readiness에 사용하지 않는다. ARM은 선택한
`RID_SC[s_buf]`와 `RID_ZP[z_buf]`를 별도 dependency로 확인한다.

## ARM wait dependency를 5개로 확장

독립 W/S/Z readiness를 표현하기 위해 `GEMM_MAX_WAIT_DEPS`와 command metadata의
`waits[]`를 4개에서 5개로 확장한 구조는 유지한다. Resource 영향이 작은 control
metadata는 별도 join state machine 대신 bitwidth/entry 수를 늘려 표현한다.

다만 Input streaming 적용 후 아래 다섯 dependency는 더 이상 모두 child issue
dependency가 아니다. 이는 기존 non-overlap ARM의 dependency 배치다.

```text
기존 issue waits[0] = RID_W[w_buf] load complete
기존 issue waits[1] = RID_SC[s_buf] load complete
기존 issue waits[2] = RID_ZP[z_buf] load complete
기존 issue waits[3] = prior GEMM complete
기존 issue waits[4] = accumulator group free
```

Input overlap command에서는 다음처럼 분리한다.

```text
issue waits[0]       = RID_TILE[input_tile_buf]
admit_waits[0]       = RID_W[w_buf] load complete
admit_waits[1]       = RID_SC[s_buf] load complete
admit_waits[2]       = RID_ZP[z_buf] load complete
admit_waits[3]       = accumulator group free
prior GEMM wait      = 다음 Input command에는 사용하지 않음
```

Command metadata에 `input_admit_waits[4]` 또는 동등한 고정 크기 admission fence를
추가한다. Controller의 dependency loop는 일반 `waits[]`만 child issue에 적용하고,
Input executor는 entry별 `input_admit_waits[]`를 destination handshake에 적용한다.
기존 `GEMM_MAX_WAIT_DEPS=5`는 다른 command와 debug/constructor 호환을 위해 축소하지
않는다. Weight의 `writer_wait`와 Input의 `input_admit_waits[]`는 일반 issue
dependency와 별도이며 `waits[]`에 다시 넣지 않는다.

## 기존 `prior_g_wait`의 적용 범위 분리

Current/Next W/SC/Z LOAD의 여섯 dependency는 resource별 consume dependency로
교체한다. Input overlap 적용에서는 다음 I_LDMA/GEMM ARM의 source issue와 admission도
`prior_g_wait`에서 분리한다. Input command 간 실행 순서는 Input executor의 ordered
descriptor FIFO와 in-order destination writer가 보장하고, accumulator RAW는 GEMM
unit의 기존 forwarding/read scheduler가 보장한다.

다음 용도의 GEMM completion dependency는 다른 lifetime을 보호하므로 유지한다.

- GEMM 완료 후 ACC2LMEM 시작
- 다음 tile DMA가 input buffer를 overwrite하기 전 source-consumer 완료 확인

즉 `prior_g_wait`를 전역으로 삭제하지 않는다. 다음 Input command를 직전 Input
completion 뒤에 세우는 용도에서만 제거하고, output/accumulator 및 tile-buffer reuse
안전 조건은 유지한다.

# 구현계획

## 1. Sync RID와 consume event contract 정의

기존 2-bank consume implementation의 RID 번호와 의미는 유지한다. 4-bank Weight에
필요한 W2/W3 LOAD-completion RID와 W2/W3 consume RID를 기존 21개 RID 뒤에 추가하여
`GEMM_NUM_SYNC_REGS`를 25로 확장한다. 최대 RID가 24이므로
`GEMM_SYNC_REG_ID_WIDTH=5`는 그대로 유지한다.

```text
RID_W0, RID_W1, RID_W2, RID_W3
RID_W_CONSUME0, RID_W_CONSUME1, RID_W_CONSUME2, RID_W_CONSUME3
RID_SC_CONSUME0, RID_SC_CONSUME1
RID_ZP_CONSUME0, RID_ZP_CONSUME1
```

Consume event의 공통 contract는 다음과 같다.

- 한 GEMM ARM command는 자신이 사용하는 독립 W/S/Z bank에 대해 target 하나씩 예약
- 한 command에서 각 W/SC/Z consume event는 정확히 한 번 발생
- Event는 `{valid, buffer_idx, value=1}` 형태이며 backpressure로 유실되지 않음
- Invocation 시작/reset 시 issued/completed target을 모두 0으로 초기화
- LOAD completion RID와 consume completion RID는 서로 갱신하지 않음

현재 node의 `gemm_sync_if[1]`, `[2]`, `[3]` weight/scale/zero-point consume event
경로를 유지한다. Controller는 이 세
입력만 consume RID update로 받아들이고, 다른 legacy sync 입력의 의미는 변경하지
않는다. 세 resource event가 같은 cycle에 들어와도 모두 반영할 수 있어야 한다.

## 2. GEMM unit consume-event interface와 index width 분리

`VX_gemm_unit_v2_if`에 resource별 consume pulse와 physical buffer index를
추가한다.

```text
weight_consume_valid, weight_consume_idx
scale_consume_valid,  scale_consume_idx
zp_consume_valid,     zp_consume_idx
```

`weight_consume_idx`와 모든 Weight selector/index를 2-bit로 확장한다. Scale/ZP
selector와 consume index는 1-bit를 유지한다. Package typedef, node command context,
GEMM unit control pipe와 debug probe에서 암시적인 1-bit cast가 남지 않도록 resource별
index type을 정의한다.

기존 packet metadata의 `last`, `wreg_use_idx`, `sreg_use_idx`, `zreg_use_idx`를
각 resource의 consume stage까지 함께 전달한다. Event pulse가 pipeline valid와
정확히 정렬되고 bubble/reset에서 발생하지 않도록 한다.

`VX_gemm_node.sv`는 이 pulse를 해당 consume RID와 `value=1`인
`VX_gemm_sync_if` transaction으로 변환한다. Consume event의 ready는 항상
보장하고, valid인데 ready가 아니거나 동일 event가 두 번 전송되는 경우 assertion으로
실패시킨다.

## 3. Scale/ZP snapshot datapath 구현

Input admission 시 `sreg_use_idx`와 `zreg_use_idx`로 선택한 전체 scale/ZP vector를
snapshot한다. 기존 `scale_regs`와 `zero_regs`는 LDMA staging register로
유지하되, snapshot 이후 datapath에서는 이 register를 다시 직접 읽지 않는다.

QDIR과 실제 사용 stage에 따라 snapshot path를 분리한다.

- QROW scale: input scaler까지 전달
- QROW ZP: `PREALIGN_CTRL_IDX`의 zero-point 연산까지 전달
- QCOL ZP: `QCOL_REDUCE_CTRL_IDX`까지 전달
- QCOL scale: `INT2FP_CTRL_IDX`의 output scaler까지 전달

Full 1024-bit qparam vector를 모든 stage에 하나의 공통 shift register로 전달하지
않고, scale/ZP와 QCOL/QROW별 필요한 구간만 pipeline한다. Pipeline valid,
quantization direction, `last`, buffer index를 data와 동일하게 정렬한다.

한 I_LDMA command의 마지막 packet이 snapshot되는 cycle에 SC/ZP consume pulse를
각각 발생시킨다. 이 cycle 이후에는 이전 packet들이 복사된 qparam을 사용하므로
원본 register를 overwrite할 수 있다. `sreg_busy`와 `zreg_busy`는 mutable
register를 아직 snapshot하지 않은 input만 나타내도록 범위를 줄이고, snapshot
이후 stage를 busy에 포함하지 않는다.

Read와 동일한 cycle에 같은 register write가 요청되는 경우에는 기존 값의 snapshot
완료가 우선이라는 ordering을 명시한다. 구현에서는 ready로 same-cycle write를
막거나 old-value capture가 보장되는 sequential ordering을 사용하고 assertion으로
검증한다.

Scale/ZP bank 수는 각각 2로 유지한다. `s_buf_q`와 `z_buf_q`는 별도 pointer로
관리하고 ARM metadata의 독립 index로 snapshot source를 선택한다. W/S/Z equality를
검사하는 node/unit/FSM assertion은 제거하고, S와 Z가 서로 다른 index인 directed
case에서도 각 snapshot이 올바른 register를 읽는지 검증한다.

## 4. Weight 4-bank와 same-cycle consume/write gate 구현

Weight data는 pipeline하지 않고 기존 GEMM-tree 내부 weight register를 2-bank에서
4-bank로 확장한다. `VX_gemm_weight_regs_v1`, `VX_gemm_tree_v1`과 PE로 전달되는
`in_weight_sel_i`/`out_weight_sel_i`를 2-bit로 바꾸고 4-bank mux 및 write selection을
구현한다. Weight LDMA destination은 beat-aligned 주소 위에
`{load_dir, wreg_idx[1:0]}`를 encode/decode한다.

`wreg_busy[idx]` 계산 범위를 다음으로 제한한다.

- 현재 cycle의 `input_fire`와 `packet_ctrl.wreg_use_idx`
- `ctrl_pipe[0]`부터 `ctrl_pipe[PREALIGN_CTRL_IDX]`까지의 valid/index
- `PREALIGN_CTRL_IDX`는 실제 GEMM-tree weight read cycle이므로 포함
- `PREALIGN_CTRL_IDX` 이후 stage는 이미 weight를 읽었으므로 제외

마지막 packet이 `PREALIGN_CTRL_IDX`에서 GEMM-tree input으로 전달되는 cycle에
`weight_consume_valid`와 해당 2-bit `wreg_use_idx`를 발생시킨다.

`w_lmem_bus_if`의 downstream ready는 일반적으로 `!wreg_busy[wreg_wr_idx]`를 사용하되,
matching final consume cycle에는 같은 bank의 다른 consumer가 없으면 ready를
lookahead하여 old-weight read와 new-weight write를 같은 edge에 허용한다. 이 신호만으로
아직 unit에 도착하지 않은 future consumer를 보호하지 못하므로 Weight executor의
writer RID/target release도 반드시 만족해야 한다. Matching consume 전 write,
non-final same-bank consumer와의 overwrite, wrong-bank same-cycle release를 assertion으로
금지한다.

## 5. Controller의 external consume update 통합

`VX_gemm_ctrl.sv`의 `effective_sync[]` 계산에 W/SC/Z consume event를 추가한다.
Stored sync value, 같은 cycle child completion, consume event를 모두 적용한 뒤
dependency를 비교하여 consume event가 들어온 cycle에 대기 command를 바로
release할 수 있게 한다.

다음 collision 규칙을 적용한다.

- W/SC/Z consume RID는 서로 다르므로 세 event의 same-cycle update를 허용
- Child command completion은 consume RID를 notify하지 않아야 함
- 같은 consume RID에 두 update가 동시에 들어오면 assertion failure
- RID가 range 밖이거나 event value가 1이 아니면 assertion failure

Controller와 legacy `VX_gemm_sync`의 array 크기, loop bound, debug/status packing,
unittest의 고정 15-RID 가정을 모두 새 `GEMM_NUM_SYNC_REGS` 기준으로 변경한다.

`GEMM_MAX_WAIT_DEPS`를 4에서 5로 늘리고 `gemm_unified_cmd_t.waits`, FSM command
constructor, controller dependency loop, queue width, trace/debug와 unittest를 모두
parameter 기반으로 확장한다. 다섯 dependency entry는 W/SC/Z load-ready,
prior-GEMM, accumulator-free 순서로 사용한다.

Weight child에는 일반 issue dependency와 별도로 depth-2 commit-wait metadata를 둔다.
Weight command accept 시 consume RID/target을 해당 inflight entry에 저장하고,
accept cycle의 `effective_sync`가 이미 target 이상이면 release bit를 즉시 설정한다.
그렇지 않으면 이후 `effective_sync`가 target에 도달할 때 command tag/sequence와
결합된 release token을 발생시킨다. Release token은 command가 완료됐다는 뜻이
아니며 destination writer가 해당 command를 commit할 수 있다는 뜻만 가진다.
Notify/tag retirement은 기존처럼 actual WREG write completion을 기다린다.

Scale과 Zero-point child도 single-active 제한에서 제외하고 각각 depth-4 ordered inflight
metadata를 사용한다. SC/ZP command issue에는 source tile-ready와 executor capacity만
적용하고, matching consume target은 command별 writer-wait metadata로 executor에
전달한다. Controller는 SC0/SC1 및 ZP0/ZP1 consume level을 node/executor에 전달하되,
completion/notify는 oldest entry의 actual register write와만 결합한다.

Input child도 multi-inflight 대상으로 확장하되 depth-4 ordered inflight metadata를
사용한다. Input command의 child issue에는 source tile-ready만 적용하고 W/SC/Z/ACC
target은 controller issue eligibility에서 제외한다. Controller는 Input executor가
entry별 exact target을 비교할 수 있도록 W0..W3, SC0..SC1, ZP0..ZP1,
ACC_FREE0..ACC_FREE1의 sync level을 node에 전달한다.

Input completion은 ordered inflight head만 retire한다. Same-cycle last admission과 다음
Input command accept가 함께 발생할 수 있도록 pop/push를 허용하고, later command의
completion이나 dependency가 head notify를 추월하지 못하게 assertion을 추가한다.

## 6. FSM의 독립 pointer와 resource별 last-consumer target 관리

`VX_gemm_fsm.sv`에 resource별, buffer별 issued consume count와 valid를 둔다.

```text
w_consume_issued[4]
sc_consume_issued[2]
zp_consume_issued[2]
```

단일 `mxu_buf_q`를 `w_buf_q[1:0]`, `s_buf_q`, `z_buf_q`, `g_buf_q`로 분리한다.
`gemm_arm_parent_accept`에서 ARM metadata가 선택한 W/S/Z bank entry를 각각 1
증가시킨다. 이 값은 해당 ARM command가 향후 발생시킬 consume event의 target이자,
동일 physical register를 덮어쓸 LOAD가 기다릴 target이다. `g_buf_q`는 resource
bank와 무관하게 기존 GEMM completion/prior-GEMM ordering만 관리한다.

Current/Next W/SC/Z LOAD의 여섯 command 생성 지점을 다음처럼 변경한다.

- Current command는 resource별 current pointer의 consume target 사용
- Next command는 W modulo-4, S/Z modulo-2 next pointer의 consume target 사용
- Target의 issued count가 0이면 consume wait를 만들지 않음
- W/SC/Z는 count가 0보다 크면 대응하는 consume RID와 issued target을 resource별 writer
  commit metadata에 추가하고 일반 child issue wait에는 넣지 않음
- Resource별 count가 0이면 commit fence 없이 initial LOAD로 표시
- 기존 tile-ready source wait와 LOAD-completion notify는 유지
- 여섯 command에서 전역 `prior_g_wait` dependency는 제거

Input ARM은 source issue용 `RID_TILE[buf_cur]`만 일반 `waits[]`에 넣는다. 선택된
physical bank의 `RID_W[w_buf]`, `RID_SC[s_buf]`, `RID_ZP[z_buf]`와 accumulator group의
`RID_ACC_FREE`는 `input_admit_waits[]`에 넣고, `prior_g_wait`는 Input command metadata에서
제거한다. 기존 joined `RID_SZ`는 사용하지 않는다. ARM flags는
`{qdir, notify, accum, w_idx[1:0], s_idx, z_idx}`를 encode하며 각 LOAD notify 및 admission
target과 정확히 대응해야 한다.

ACC2LMEM과 다음 tile input-buffer reuse에서 사용하는 `prior_g_wait`는 유지한다.

Issued target overflow, completion이 issued target을 초과하는 경우, invocation
종료 시 issued/completed consume count 불일치도 assertion으로 검사한다. Weight
command가 source-ready 이전에 issue되거나, consume target metadata가 유실·변조되는
경우도 assertion으로 검사한다.

## 7. Weight streaming executor와 4-bank writer release 연결

기존 depth-2 Weight command FIFO와 8-entry shared response slot은 유지한다. 각 command
entry에 `commit_valid`, `commit_rid`, `commit_target`, `write_released`를 추가하고,
controller/node의 release token을 정확한 entry에 기록한다. Executor와 controller가
받는 Weight consume level을 2개에서 4개로 확장하고, entry의 2-bit destination bank로
정확한 level/RID를 선택한다.

- `rd_cmd_ptr`는 `write_released`와 무관하게 source-ready command를 순서대로 읽음
- Source response는 global slot ID로 shared RAM에 저장하며 release 전에도 보관 가능
- `wr_cmd_ptr`는 head entry의 `write_released`와 destination ready를 모두 확인
- Head가 unreleased이면 later command도 write하지 않지만 source read는 capacity까지 진행
- Head의 matching consume가 final-reader cycle에 도달하면 same-cycle WREG write를 허용
- Slot/FIFO가 가득 차면 source에 정상 backpressure를 걸고 data를 overwrite하지 않음
- Reset/invocation abort 시 descriptor, release bit, slot owner와 boundary metadata를 함께 무효화

Node의 Weight boundary queue는 executor의 마지막 destination bus handshake와 GEMM
unit의 실제 `weight_register_write`를 구분한다. Controller child completion과 notify는
기존처럼 command의 마지막 actual register write에서만 발생시킨다.

## 8. Scale/ZP streaming executor와 writer release 구현

기존 single-descriptor Scale/ZP `VX_lmem_dma_misal` instance를 resource별 overlap
executor로 교체한다. Weight executor의 global slot lifecycle과 independent
`rd_cmd_ptr`/`wr_cmd_ptr` 구조를 재사용하되, SC/ZP의 64-byte command와 1-bit destination
bank index에 맞춘다.

```text
SC_CMD_FIFO_DEPTH = 4
ZP_CMD_FIFO_DEPTH = 4
SC_RESPONSE_SLOTS = 8
ZP_RESPONSE_SLOTS = 8
```

각 descriptor entry에는 source/destination address와 stride/bound 외에
`{resource, bank, writer_wait_valid, writer_wait_rid, writer_wait_target, sequence}`를
저장한다. `rd_cmd_ptr`는 writer wait와 무관하게 source request를 진행하고,
`wr_cmd_ptr`는 oldest entry의 exact consume target과 GEMM register ready가 모두
만족될 때만 slot을 drain한다.

- CMD N+1 source request는 CMD N의 마지막 source request 뒤 즉시 시작 가능
- CMD N+1 source response는 CMD N write/complete 전에도 slot에 저장 가능
- Destination write와 completion은 resource별 FIFO 순서를 추월하지 않음
- Matching SC/ZP consume 전에는 같은 bank destination write가 발생하지 않음
- Other-bank, stale target 또는 later entry의 consume가 head를 release하지 않음
- `req_valid&&!req_ready` 동안 payload, byte-enable, address와 entry owner가 안정적임
- Slot은 `FREE -> WAIT_RSP -> READY -> DRAINING -> FREE` lifecycle을 지킴
- Actual final register write 전에는 child completion/notify가 발생하지 않음

Node에는 SC와 ZP 각각 ordered boundary/completion metadata를 두어 DMA destination bus
handshake와 `scale_register_write`/`zero_point_register_write`를 1:1로 결합한다. 첫
command가 1 beat여도 start와 write가 같은 cycle이라는 가정을 하지 않고 command별
remaining-write count를 저장한다.

Scale/ZP의 final actual register write는 completion의 원인이지만, controller에는
registered pulse로 다음 cycle에 전달한다. 또한 qparam command FIFO가 full인 경우 현재
cycle의 final write를 `idle` capacity로 combinational bypass하지 않고 registered count가
감소한 다음 cycle에 새 command를 받는다. 이 두 causal boundary는 GEMM `req_ready`에서
completion/effective-sync/scheduler를 거쳐 다시 GEMM `req_ready`로 돌아오는 delta-cycle
loop를 끊는다. Actual-write completion 의미, resource별 in-order 순서, exact writer
fence는 바뀌지 않는다.

Input admission은 현재처럼 registered `RID_SC`/`RID_ZP` LOAD-completion value를 사용한다.
따라서 actual qparam write와 같은 cycle에는 새 Input을 같은 bank로 admission하지 않으며,
다음 cycle의 sync update 뒤에만 새 version이 snapshot된다. Explicit write-to-snapshot
bypass는 이번 구현 범위에 포함하지 않는다.

Scale과 ZP가 같은 TMEM source bank를 사용할 때의 arbiter ordering도 검증한다. 한
resource가 연속 grant를 독점하지 않게 기존 arbitration contract를 보존하고, ZP의
1-cycle response skew가 slot ownership이나 command completion 순서를 바꾸지 않도록
assertion을 추가한다.

## 9. Input admission metadata와 controller multi-inflight 구현

`gemm_unified_cmd_t`에 Input destination admission 전용 wait array를 추가한다.

```text
input_admit_waits[0] : W LOAD-completion RID/target
input_admit_waits[1] : SC LOAD-completion RID/target
input_admit_waits[2] : ZP LOAD-completion RID/target
input_admit_waits[3] : ACC_FREE RID/target
```

이 metadata는 일반 child issue dependency loop에서 평가하지 않는다. Input child의
일반 `waits[]`에는 source tile-ready만 두고, executor capacity가 있으면 W/S/Z/ACC가
unready여도 command를 start한다. `prepare`는 기존 interface 호환 및 source-credit
검증에 남길 수 있지만 Input streaming의 command context 역할로 사용하지 않는다.

Controller의 Input child를 Weight와 함께 multi-active 대상으로 지정하고 Input inflight
FIFO를 depth 4로 확장한다. `input_read_flag.idle`의 의미도 "전체 Input pipeline이
비었음"이 아니라 "새 descriptor를 받을 capacity가 있음"으로 바꾼다. Invocation
quiescence는 descriptor FIFO, response slot, admission context, delayed final-writeback
entry가 모두 empty일 때만 성립한다.

다음 assertion을 추가한다.

- Input issue 시 source tile-ready가 정확한 target에 도달함
- W/S/Z/ACC admission target은 issue eligibility에 영향을 주지 않음
- Inflight depth를 초과한 command accept가 없음
- Completion은 oldest inflight notify와만 결합
- Same-cycle completion/pop과 next command push가 metadata를 교차시키지 않음
- Invocation 완료 시 Input source/writer/context/completion entry가 모두 drain됨

## 10. Input streaming executor와 shared slot 구현

기존 single-descriptor `VX_lmem_dma_misal` Input instance를 Input 전용 overlap executor로
교체한다. Weight executor의 global slot lifecycle과 in-order head 구조를 재사용하되,
Input command의 variable `bound/eff_mt`를 지원한다.

```text
CMD_FIFO_DEPTH = 4
RESPONSE_SLOTS = 8
slot state     = FREE -> WAIT_RSP -> READY -> DRAINING -> FREE
```

FIFO entry에는 source/destination descriptor뿐 아니라 다음 full command context를 함께
저장한다.

- accumulator base, packet count/index
- `is_accum`, `notify_on_writeback`, QDIR
- `wreg_use_idx[1:0]`, `sreg_use_idx`, `zreg_use_idx`
- 네 admission RID/target
- command sequence/tag와 source/destination progress

`rd_cmd_ptr`, `wr_cmd_ptr`, `cmd_tail_ptr`를 분리한다. Source request는 command/beat
in-order로 issue하고 response는 global slot tag로 수신한다. Writer는 `wr_cmd_ptr`가
가리키는 command의 expected beat만 drain한다. CMD N의 last admission과 같은 cycle에
CMD N+1의 first slot을 pre-read하여 다음 cycle의 first admission이 가능하도록 한다.

M>4 command는 8 slot 전체를 고정 점유하지 않고 writer가 slot을 반환하는 동안 source가
같은 ring을 refill하는 streaming 방식으로 처리한다. M=4에서는 두 command payload가
동시에 resident할 수 있어야 한다. TMEM response가 out-of-order로 도착하거나 source와
destination에 독립 backpressure가 있어도 owner/sequence/beat가 바뀌지 않아야 한다.

Node의 단일 `input_cmd_ctx_r`는 writer-head context로 교체한다. `packet_ctrl`과
accumulator address/index는 현재 destination head에서 만들고, ready가 낮은 동안
payload와 모든 sideband를 안정적으로 유지한다. Command head 전환은 last
`input_fire`에서만 수행하며 다음 cycle에 새 head의 packet index 0을 선택한다.

## 11. GEMM input admission gate와 completion endpoint 구현

`VX_gemm_unit_v2`에 node가 계산한 `input_admission_ready`를 전달한다. Unit의 input
contract를 always-ready에서 handshake 기반으로 변경한다.

```systemverilog
assign i_lmem_bus_if.req_ready = input_admission_ready;
wire input_fire = i_lmem_bus_if.req_valid
                && i_lmem_bus_if.req_ready;
```

Control pipe valid, Scale/ZP snapshot, consume pulse, accumulator address progression과
performance counter는 모두 `input_fire`에서만 진행한다. `req_valid&&!req_ready` 동안
어떤 input data나 packet context도 consume되지 않아야 한다.

Admission gate는 writer-head의 exact W/S/Z/ACC target을 사용한다. Weight LOAD의 final
actual register write는 새 input의 Weight read보다 충분히 앞서므로 matching completion을
same-cycle bypass할 수 있다. Scale/ZP는 같은 admission edge에서 snapshot하므로 explicit
write-data bypass를 구현하지 않는 한 same-cycle completion을 사용하지 않고 registered
sync value가 다음 cycle에 보인 뒤 ready를 올린다.

Accumulator ordering은 Input executor의 in-order admission과 기존 GEMM-unit forwarding
contract로 보장한다. M=1/2/3/4 seamless command boundary를 각각 d=1/2/3/4 case로
검증하여 `prior_g_wait` 제거가 accumulator result를 손상시키지 않는지 확인한다.

Command completion endpoint는 다음처럼 command별로 저장하고 in-order 전송한다.

- 일반 command는 last `input_fire`에서 destination complete
- `notify_on_writeback=1` command는 matching tagged final accumulator write에서 complete
- Source request/response 완료나 global executor idle은 command completion으로 사용하지 않음
- 다음 tile input-buffer reuse 및 ACC2LMEM용 `RID_G` notify 의미는 유지

## 12. 통합 instrumentation과 성능 관측점 추가

Unittest와 XRT-VCS FSDB에서 다음 신호를 직접 관측할 수 있도록 named debug
probe 또는 기존 trace에 event를 추가한다.

- ARM accept의 W/S/Z index와 예약된 consume target
- W/SC/Z consume pulse의 RID, buffer, target
- Controller의 stored/effective consume sync value
- 각 W/SC/Z LOAD의 source-ready, child issue, commit RID/target, writer release/start
- Weight FIFO occupancy, slot occupancy/owner, read/write command pointer와 release bit
- Weight `wreg_busy`, `wreg_wr_idx`, `req_valid`, `req_ready`, write handshake
- SC/ZP FIFO occupancy, slot occupancy/owner, read/write command pointer와 writer wait
- SC/ZP source request/response, register `req_valid/req_ready`, actual write와 completion
- SC/ZP snapshot valid, last, buffer index와 consume event
- Input child queue/inflight occupancy, issue wait와 네 admission target
- Input command/context FIFO occupancy, shared slot state/owner와 read/write pointer
- Input source request/response, destination `req_valid/req_ready/input_fire`
- Command별 last admission, tagged final writeback, completion/notify sequence
- Burst boundary gap과 slot underflow 원인(resource wait/source wait/empty slot)

Debug probe는 synthesis datapath나 command timing에 영향을 주지 않게
`ifndef SYNTHESIS` 또는 기존 debug guard 아래에 둔다.

# 검증계획

## 1. Static contract 및 compile 검증

- 모든 기존 RID 번호가 유지되고 W2/W3 LOAD/consume RID가 unique/in-range인지 확인
- `GEMM_NUM_SYNC_REGS=25`, RID width 5 bit가 command metadata, FIFO, interface,
  debug packing에 일관되게 적용되었는지 확인
- Production RTL에서 고정 array size 15 또는 4-bit RID slice가 남지 않았는지 검색
- `git diff --check`와 affected unittest compile을 먼저 통과

모든 VCS unittest는 target config를 source한 뒤 `tools/verify_rtl.py`로 실행한다.

```bash
source configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh
```

## 2. `gemm_unit_v2` directed unittest

`hw/unittest/gemm_unit_v2`에 QCOL/QROW 각각의 register reuse case를 추가한다.

### Scale/ZP snapshot

- REG0의 nonuniform scale/ZP로 여러 input packet을 연속 admission
- 마지막 packet snapshot 직후 REG0을 서로 다른 값으로 overwrite
- 기존 packet의 뒤쪽 QCOL/QROW 결과는 old snapshot을, 다음 command는 new value를 사용
- QROW scale, QROW ZP, QCOL ZP, QCOL scale의 네 사용 지점에서 data/control 정렬 확인
- 마지막 packet마다 SC/ZP consume pulse가 각각 정확히 한 번 발생
- Bubble, reset, `last=0`, 잘못된 index에서 consume pulse가 발생하지 않음
- Snapshot 전 같은 register write는 stall되고 snapshot 후에는 허용
- Same-cycle SC/ZP write와 snapshot ordering에서 torn vector가 생성되지 않음

### Weight consume/ready

- REG0을 사용하는 여러 packet을 넣고 마지막 packet이
  `PREALIGN_CTRL_IDX`를 통과하기 전 REG0 write를 시도하여 `req_ready=0` 확인
- 마지막 GEMM-tree input read cycle에는 기존 weight가 사용되고 consume pulse가 발생
- Exact final consume cycle에 다른 same-bank consumer가 없으면 old-weight read와
  REG0 write가 같은 cycle에 발생
- REG1/REG2/REG3 write는 REG0 consumer와 무관하게 조기에 accept됨
- REG0..REG3 packet이 pipeline에서 겹치는 경우 busy mask가 네 bit를 독립적으로 관리
- Consume 전 weight write handshake 및 consume 이후 불필요한 WRITE-stage stall이 없음

실행:

```bash
/usr/bin/python3 tools/verify_rtl.py unittest --path hw/unittest/gemm_unit_v2 --sim vcs --timeout 600
```

## 3. `gemm_fsm`, `gemm_ctrl`, `gemm_sync` dependency unittest

### FSM

- 첫 consumer가 없는 buffer의 W/SC/Z LDMA에는 writer commit fence가 없음
- Current/Next W/SC/Z LOAD가 독립 resource pointer와 target bank에 맞는 RID/target을 선택
- W/SC/Z LDMA의 consume RID/target은 resource별 writer commit metadata에 있고 child
  issue wait에는 없음
- W/SC/Z LDMA의 tile-ready dependency는 유지되며 source tile이 준비되기 전에는 issue되지 않음
- W0..W3 및 S/Z 0..1의 다른-bank consume event로 command가 release되지 않음
- W consume는 W_LDMA writer만, SC consume는 SC_LDMA만, ZP consume는 ZP_LDMA만 release
- 같은 buffer에서 sequence가 증가해도 stale consume target으로 다음 LOAD가 release되지 않음
- Input ARM issue에는 RID_TILE만 있고 W/S/Z/ACC는 `input_admit_waits[]`에 존재
- Input ARM source/admission에는 `prior_g_wait`가 없고 ACC2LMEM/next-tile reuse에는 유지
- W/S/Z index가 서로 다른 ARM tuple도 허용되고 정확한 register를 선택
- Input admission의 네 wait가 W/SC/Z readiness와 accumulator-free를 모두 보존

### Controller/sync

- W/SC/Z consume event가 서로 다른 cycle, 같은 cycle, buffer 교차 순서로 들어오는 경우
- Consume event와 unrelated child completion이 같은 cycle에 들어오는 경우
- Weight command가 consume 전 child/executor에 issue되고 commit-wait metadata가 보존됨
- Event가 들어온 cycle의 `effective_sync`가 즉시 갱신되어 정확한 Weight entry만
  writer-release되며, 이 시점에는 child completion/notify가 발생하지 않음
- Weight 두 command가 inflight일 때 later release가 먼저 도착해도 completion은 추월하지 않음
- Weight inflight FIFO의 full, same-cycle pop/push, reset에서 metadata 유실/alias가 없음
- Scale과 ZP child가 각각 consume-unready 상태에서도 tile-ready와 capacity만으로 최대
  4개 command를 issue하고 resource별 ordered inflight metadata를 유지
- SC/ZP later entry의 consume target이 먼저 ready여도 actual write/completion이 oldest
  entry를 추월하지 않음
- Input child가 W/S/Z/ACC unready 상태에서도 tile-ready와 capacity만으로 최대 4개
  command를 issue하며, destination admission은 exact target까지 차단됨
- Input ordered inflight FIFO의 full, same-cycle pop/push와 notify retirement 순서 확인
- Duplicate, out-of-range, value!=1, child-notify-to-consume-RID를 assertion으로 차단
- Reset/new invocation 뒤 이전 consume count가 다음 invocation을 release하지 않음

실행:

```bash
/usr/bin/python3 tools/verify_rtl.py unittest --path hw/unittest/gemm_fsm --sim vcs --timeout 600
/usr/bin/python3 tools/verify_rtl.py unittest --path hw/unittest/gemm_ctrl --sim vcs --timeout 600
/usr/bin/python3 tools/verify_rtl.py unittest --path hw/unittest/gemm_sync --sim vcs --timeout 600
```

## 4. Scale/ZP overlap executor directed unittest

`hw/unittest/lmem_dma_qparam_overlap`을 추가하거나 공통 overlap executor TB를 Scale과
Zero-point mode로 각각 실행한다. `CMD_FIFO_DEPTH=4`, `RESPONSE_SLOTS=8`, command당
1 beat 조건에서 다음을 검증한다.

- Consume target이 모두 blocked인 상태에서도 command 네 개가 accept되고 source
  request/response가 slot에 저장됨
- Source request와 response가 resource별 sequence 0..3 순서를 유지하고 slot owner가
  정확함
- 다른 bank, stale target 및 later command consume로 writer head가 release되지 않음
- Matching consume 전 actual register write와 command completion은 0회
- Matching consume 뒤 register ready가 올라오면 미리 준비된 payload가 source latency
  없이 write됨
- `req_valid&&!req_ready` 동안 address/data/byte-enable/owner가 안정적으로 유지됨
- S0/S1 또는 Z0/Z1 circular destination과 actual write/completion 순서가 정확함
- 네 command 뒤 추가 command를 넣어 FIFO pointer와 slot ring wrap을 검증
- Source/response/destination backpressure 및 live reset에서 duplicate, stale write,
  slot leak이 없음
- Scale/ZP 두 source가 같은 TMEM bank를 사용할 때 arbitration으로 1-cycle skew가
  발생해도 starvation이나 owner mismatch가 없음

Completion은 마지막 actual register write와 일치해야 하며 source response나 slot fill로
조기 발생하면 실패한다. Registered LOAD completion은 actual write 다음 cycle부터만 Input
admission에 보이는지 controller/node integration에서 함께 확인한다.

## 5. Node integration unittest

`hw/unittest/gemm_node_improve`에서 M=4, N=256, K=256, QBLK=32,
WTRANS=0의 QCOL/QROW case를 수행한다. Scale/ZP는 lane과 micro-k마다 다른 값을
사용하여 old/new snapshot이 뒤섞이면 numerical mismatch가 나도록 한다.

Scoreboard는 ARM command별로 다음을 확인한다.

- 예약된 W/SC/Z consume target과 실제 pulse가 각각 1:1 대응
- SC/ZP consume는 마지막 input snapshot, W consume는 마지막 GEMM-tree input에서 발생
- Weight LOAD command와 source request는 matching consume 이전에도 issue될 수 있음
- Weight source data가 release 전 shared slot에 보존되고 destination write는 발생하지 않음
- SC/ZP LOAD command와 source request도 matching consume 이전에 최대 4개까지 issue되며
  payload가 resource별 shared slot에 보존됨
- Matching SC/ZP consume 전 actual qparam write는 없고, consume 뒤 oldest prepared
  payload만 해당 bank에 write됨
- ARM은 accept됐지만 input packet이 아직 GEMM unit에 도착하지 않은 blind window에서도
  같은 buffer의 WREG write가 차단됨
- Matching consume 이후 unrelated `RID_G`를 기다리지 않고 writer가 release됨
- Weight completion은 source 완료나 bus pipe accept가 아니라 마지막 actual WREG write와 일치
- 모든 LOAD notify, input completion, final writeback count가 baseline과 동일
- Random input gap과 W/SC/Z destination backpressure에서도 deadlock/duplicate event가 없음

실행 예:

```bash
/usr/bin/python3 tools/verify_rtl.py unittest --path hw/unittest/gemm_node_improve --sim vcs --params "TEST=WREG_DB_QCOL_M4 M=4 N=256 K=256 QBLK=32 WTRANS=0 QDIR=0" --extra-sim-args "+NO_WAVE" --timeout 1200
/usr/bin/python3 tools/verify_rtl.py unittest --path hw/unittest/gemm_node_improve --sim vcs --params "TEST=WREG_DB_QROW_M4 M=4 N=256 K=256 QBLK=32 WTRANS=0 QDIR=1" --extra-sim-args "+NO_WAVE" --timeout 1200
```

Prefetch/release datapath의 기존 backpressure 동작이 유지되는지 다음 smoke도
재실행한다.

```bash
/usr/bin/python3 tools/verify_rtl.py unittest --path hw/unittest/lmem_dma_misal --sim vcs --timeout 600
```

## 6. XRT-VCS functional regression

`ci/run_target_gemm.sh`를 사용해 `N=256`, `K=256`, `QBLK=32`, `WTRANS=0`,
`WLOAD=8`을 고정하고 `M={4,256} x QDIR={0,1}` 네 조합을 검증한다.

```bash
ci/run_target_gemm.sh run --m 4   --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8 --rebuild
ci/run_target_gemm.sh run --m 4   --n 256 --k 256 --qblk 32 --qdir 1 --wtrans 0 --wload 8
ci/run_target_gemm.sh run --m 256 --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8 --timeout 3600
ci/run_target_gemm.sh run --m 256 --n 256 --k 256 --qblk 32 --qdir 1 --wtrans 0 --wload 8 --timeout 3600
```

네 run 모두 numerical verification이 PASS하고 VCS fatal/assertion, timeout,
consume count mismatch, stale qparam/weight 사용, register overwrite가 없어야 한다.
M=4에서는 짧은 4-request input burst 사이의 register reuse latency를,
M=256에서는 장시간 ping-pong 전환과 counter wrap/stale dependency, deadlock 없음을
확인한다.

## 7. FSDB correctness 및 latency 검증

변경 전 baseline과 비교하기 위해 M=4 QCOL/QROW 두 case의 GEMM node FSDB를
생성한다.

```bash
ci/run_target_gemm.sh fsdb-gemm --m 4 --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8
ci/run_target_gemm.sh fsdb-gemm --m 4 --n 256 --k 256 --qblk 32 --qdir 1 --wtrans 0 --wload 8
```

`tools/fsdb_cli`로 다음 순서를 command별, buffer별로 추출한다.

```text
ARM accept / consume target reservation
  -> W/SC/Z child issue
  -> W/SC/Z source request/response 및 resource별 shared slot fill
  -> SC/ZP final snapshot
  -> RID_SC_CONSUME / RID_ZP_CONSUME update
  -> final GEMM-tree weight read
  -> RID_W_CONSUME update
  -> matching W/SC/Z writer release
  -> target register req_valid && req_ready
  -> actual register write 및 command completion
```

필수 correctness 조건:

- 각 ARM당 resource별 consume update가 정확히 한 번 존재
- Weight source read는 consume 전에 허용되지만 같은 buffer의 actual register write는 없음
- Scale/ZP source read도 consume 전에 허용되지만 같은 bank의 actual register write는 없음
- Qparam register overwrite 후에도 이전 packet은 snapshot value를 사용
- Weight final consume pulse cycle에는 old weight를 사용하고, exact matching
  same-cycle overwrite인 경우 같은 edge에서 새 weight가 write됨
- ARM accept 후 input packet이 unit에 도착하기 전의 blind window에서도 overwrite가 없음
- 다른 buffer 또는 다른 resource consume event가 command를 잘못 release하지 않음
- Weight command completion/notify는 마지막 actual WREG write와 정확히 일치
- Input source request는 W/S/Z/ACC admission target보다 먼저 실행되고 response slot에 저장
- Input destination은 writer-head의 네 target이 ready되기 전에는 GEMM unit에 admission되지 않음
- 일반 Input command completion은 last admission, final command completion은 tagged writeback과 일치
- 네 개 M=4 Input burst가 4 beat씩 command boundary bubble 없이 in-order로 admission
- Invocation 종료 시 issued count와 effective consume sync count가 모두 일치

성능 통과 조건:

- Source tile-ready와 FIFO capacity가 있는 Weight command는 child issue/source request가
  W_CONSUME보다 앞서 발생하며, steady-state에서 두 command/8 slot capacity가 실제로 사용됨
- Matching consume 시 writer-head payload가 이미 slot에 준비된 경우 consume update에서
  첫 `w_lmem_bus_if.req_valid`까지 1 cycle 이내
- SC/ZP payload는 matching consume 전에 slot에 준비되고, consume 다음 cycle부터
  register write가 가능해야 함
- SC/ZP actual write 다음 cycle에 registered LOAD completion이 보이며, same-cycle
  qparam write/snapshot은 발생하지 않아야 함
- 네 SC command와 네 ZP command가 각각 depth-4까지 source-prefetch되고 single-command
  `S_DONE -> S_IDLE` cadence가 다음 source request를 직렬화하지 않아야 함
- Exact final consume만 남은 bank는 same-cycle overwrite가 가능하고, 그 외
  `wreg_busy`는 마지막 GEMM-tree read 다음 cycle까지 불필요하게 유지되지 않음
- 초기 Weight destination bank가 W0/W1/W2/W3 순서로 진행하며 CMD3가 W0 consume을
  기다리지 않고 W2에 기록됨
- 연속 writer-ready command의 4-beat burst 사이 gap은 0~1 cycle이어야 함
- Input CMD0..CMD3의 각 4-beat burst 사이 idle gap은 모두 0 cycle이어야 함
- Input response slot 최대 occupancy 8과 command/context FIFO lookahead depth 4가 관측되어야 함
- 남은 gap은 TMEM bank conflict, slot/FIFO full, source tile not-ready 또는 실제
  same-buffer consumer로
  cycle 단위 설명 가능해야 함

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


# 결과

## Scale/ZP multi-command overlap: correctness/overlap PASS, 전체 zero-gap 목표 FAIL

Scale과 Zero-point 각각에 depth-4 ordered descriptor FIFO와 private 8-slot response
ring을 구현했다. Source issue에는 tile-ready와 capacity만 남기고 matching SC/ZP consume
RID/target은 command별 writer fence로 이동했다. Actual register write는 exact fence와
GEMM qparam `req_ready`가 모두 만족할 때만 발생하며, controller completion은 final
actual write가 원인이 되는 registered pulse로 전달된다. Same-cycle qparam write/snapshot
bypass는 추가하지 않았다.

Directed VCS는 Scale/ZP focused executor, GEMM FSM/controller/sync/unit, Input/Weight overlap,
generic LDMA, TMEM wide-read 및 M=4 QCOL/QROW node integration을 모두 통과했다. Focused
test에서는 consume이 blocked인 동안 command 네 개와 payload를 미리 저장했고, one-beat
ordered completion, two-beat `last=0 -> last=1`, stride/address progression, backpressure와
live reset을 확인했다. XRT-VCS `M={4,256} x QDIR={QCOL,QROW}` 네 case도 numerical PASS했다.

M=4 QCOL FSDB에서 qparam overlap 자체는 목표대로 동작했다.

- Scale/ZP 각각 command enqueue, source request/response, actual write/completion 64회
- Resource별 command FIFO 최대 occupancy 4, response slot 최대 occupancy 4/8
- 첫 네 Scale/ZP command가 cycle 0-3에 연속 accept
- Scale source request cycle 3-6, ZP source request cycle 4-7
- 다음 command source가 이전 write 전에 시작한 비율은 Scale `62/63`, ZP `61/63`
- 62개 fenced write 모두 exact RID/target 이후 수행; unreleased/early write 0회
- Actual register write와 destination bus write가 Scale/ZP 각각 64/64 일치
- Actual write에서 registered controller completion까지 모두 정확히 1 cycle
- 같은 bank의 qparam write/Input snapshot overlap은 Scale/ZP 모두 0회

첫 네 command의 qparam/Input timeline은 다음과 같다. Cycle 0은 첫 Input/SC/ZP command
enqueue다.

| Input CMD | Scale resident / write / completion | ZP resident / write / completion | Input fire | 이전 gap |
|---|---|---|---|---:|
| CMD1 | 4 / 6 / 7 | 5 / 7 / 8 | 13-16 | - |
| CMD2 | 5 / 7 / 8 | 6 / 8 / 9 | 17-20 | 0 |
| CMD3 | 6 / 17 / 18 | 7 / 17 / 18 | 26-29 | 5 |
| CMD4 | 7 / 21 / 22 | 8 / 21 / 22 | 31-34 | 1 |

CMD3/4의 Scale/ZP LOAD completion은 Input burst보다 충분히 앞서므로 qparam은 더 이상
steady-state admission blocker가 아니다. 기존 single-command `S_DONE -> S_IDLE` source
cadence도 제거됐다.

그러나 전체 Input zero-gap 목표는 아직 실패했다.

- 63개 Input boundary gap: `min=0, median=2, p75=5, max=77`
- zero-gap: `18/63`
- histogram: `{0:18, 1:10, 2:8, 3:6, 4:5, 5:12, 6:2, 7:1, 77:1}`
- 첫 세 boundary: `0, 5, 1`; 필수 조건 `0, 0, 0` 미달
- 일반 nonzero boundary 44개는 모두 Weight readiness만 기다림
- 77-cycle tile boundary 한 개는 context+W+SC+ZP+ACC+empty-slot이 함께 blocked

즉 이번 변경은 Scale/ZP를 steady-state blocker에서 제거했지만, 최종 zero-gap의 직접
병목은 다시 Weight LOAD readiness로 이동했다. QCOL에서 user-level 목표 실패가 확인된
즉시 Hard Rule에 따라 QROW FSDB와 추가 RTL 변경을 중단했다.

FSDB artifact:

- QCOL: `build/run_logs/target_gemm/20260812-124421_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d0_pid3923519/target_gemm.fsdb`

## 이전 Input LDMA overlap 결과: correctness PASS, Scale/ZP 병목으로 zero-gap 실패

Input LDMA에는 source tile-ready만 issue dependency로 남기고, W/S/Z/ACC는 command별
admission fence로 분리했다. Input executor는 4개의 variable-length command context와
8개의 shared response slot을 사용하며, node는 독립 admission/completion head로 command
순서를 유지한다. Normal command completion은 final Input admission 다음 cycle, final
notify command completion은 기존 tagged writeback 시점에 발생한다.

Directed VCS 검증은 `gemm_unit_v2`, GEMM FSM/controller/sync, Input/Weight overlap,
generic LDMA, TMEM wide-read와 M=4 QCOL/QROW node numerical test를 모두 통과했다.
XRT-VCS `M={4,256} x QDIR={QCOL,QROW}` 네 case도 numerical PASS했으며 Input stall은
모두 0이었다.

그러나 M=4 QCOL/QROW FSDB에서 최종 목표인 모든 4-beat Input burst의 back-to-back
공급은 달성하지 못했다. 두 방향의 결과는 동일했다.

- Input command 64개, source request/response와 destination fire 각각 256회
- command/context/response-slot 최대 occupancy는 계획한 `4/4/8`
- 63개 burst boundary gap은 `min=0, median=5, p75=6, max=32` cycle
- zero-gap boundary는 `2/63`; histogram은 `{0:2, 5:42, 6:14, 7:4, 32:1}`
- `admission_ready && !req_valid`은 0 cycle이므로 Input executor source starvation은 없음
- nonzero boundary 61개 중 58개는 Scale+ZP, 2개는 Weight+Scale+ZP, 1개 tile
  boundary는 context+ACC+Weight+Scale+ZP admission target이 blocker

첫 네 command의 cycle timeline은 다음과 같다. Cycle 0은 첫 Input command enqueue다.

| Command | Enqueue | Source request | Source response | GEMM Input fire | 이전 burst gap |
|---|---:|---|---|---|---:|
| CMD1 | 0 | 1-4 | 2-5 | 13-16 | - |
| CMD2 | 1 | 5-8 | 6-9 | 17-20 | 0 |
| CMD3 | 2 | 14-17 | 15-18 | 26-29 | 5 |
| CMD4 | 5 | 18-21 | 19-22 | 37-40 | 7 |

CMD3/4 payload는 각각 cycle 18/22에 executor 내부에 준비되어 있지만, destination
`req_valid`가 유지된 상태에서 admission `req_ready`가 Scale/ZP completion을 기다린다.
CMD3는 ZP와 Weight가 cycle 26에 ready되어 즉시 fire하고, CMD4는 Scale final write
cycle 35, ZP final write cycle 36 뒤 cycle 37에 fire한다. 따라서 구현한 Input command
overlap과 buffering은 동작하지만, 전체 zero-gap의 남은 근본 병목은 Scale/ZP를 중심으로
한 downstream operand readiness다.

Correctness는 command/beat 순서, circular context head, 64 last admissions와 64 exact
completions, early admission 0회, QCOL/QROW numerical PASS로 확인했다. 전체 zero-gap
목표 실패가 확인되어 Hard Rule에 따라 추가 RTL 변경은 중단한다.

FSDB artifact:

- QCOL: `build/run_logs/target_gemm/20260812-011451_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d0_pid1411482/target_gemm.fsdb`
- QROW: `build/run_logs/target_gemm/20260812-012334_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d1_pid1500748/target_gemm.fsdb`

## 최종 수행 상태: 4-bank Weight versioning PASS

기존 writer-side consume fence와 depth-2/eight-slot Weight executor 위에 다음 변경을
구현했다.

- Weight storage와 use/write/consume selector를 4-bank, 2-bit circular 구조로 확장
- Scale/ZP는 기존 2-bank immutable snapshot 구조를 유지하고 W/S/Z allocation pointer를
  각각 독립화
- 기존 RID 번호를 유지한 채 W2/W3 LOAD 및 consume RID를 21..24에 append하고 sync
  register를 25개로 확장
- GEMM ARM wait를 W/SC/Z/prior-G/ACC의 5개 독립 dependency로 확장
- exact final Weight consume이고 같은 bank의 더 이른 consumer가 없을 때
  `req_ready`와 actual WREG overwrite를 같은 cycle에 허용

Directed VCS 검증은 Weight overlap, `gemm_unit_v2`, GEMM FSM/controller/sync, legacy
GEMM unit, TMEM wide-read switch, generic LDMA, M=4 QCOL/QROW node integration을 모두
통과했다. 특히 W0..W3 writer fence, W2/S0/Z1 및 W3/S1/Z0 독립 index 조합, 5개 ARM
wait, 25개 sync register no-alias, final-consume same-cycle write를 직접 검증했다.

XRT-VCS `M={4,256} x QDIR={QCOL,QROW}` 네 case도 모두 numerical PASS했다.
M=4의 input/Weight fire-stall은 `256/0`, `256/0`, M=256은 `16384/0`, `512/0`이며
fatal, assertion, timeout은 없었다.

M=4 QCOL/QROW GEMM-only FSDB를 `tools/fsdb_cli`로 분석한 결과는 두 방향에서
동일했다.

- Weight command 64개, source request와 actual WREG write 각각 256회
- W/S/Z consume 각각 64회, Scale/ZP register write 각각 64회
- Weight destination은 W0/W1/W2/W3가 각각 16회이며 정확히 circular하게 진행
- CMD N+1 source와 CMD N destination write overlap은 `62/63`
- command FIFO/response slot 최대 occupancy는 계획한 `2/8`
- 초기 writer-ready command boundary의 idle gap은 `0, 0, 1, 1 cycle`
- WREG reuse 60회 중 source payload가 consume 전에 준비된 59회는 consume과 첫
  actual write가 같은 cycle이며, 나머지 첫 W0 reuse는 payload 준비 때문에 7 cycle
- 같은 bank의 early write, wrong-bank release, `req_valid && !req_ready`는 모두 0회
- 초기 destination bank는 W0→W1→W2→W3이며, 세 번째 command의 W2 write가 첫
  W0 consume보다 3 cycle 먼저 시작

Steady-state source/destination burst boundary의 median gap은 각각 9 cycle이지만,
이는 네 bank가 모두 live인 뒤 circular reuse command가 해당 bank의 실제 final
consumer를 기다리는 구간이다. 평균 producer가 consumer보다 빠르면 유한 bank가
결국 차는 것으로 계획에 명시한 동작이며, writer-ready 상태였던 모든 boundary는
0~1 cycle 조건을 만족했다. 따라서 이전 2-bank의 고정 consumer-latency 병목과
final-consume 뒤 1-cycle ready bubble은 제거됐고, correctness 및 계획의 제한된
4-bank streaming 목표를 모두 만족했다.

FSDB artifact:

- QCOL: `build/run_logs/target_gemm/20260811-220638_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d0_pid3728975/target_gemm.fsdb`
- QROW: `build/run_logs/target_gemm/20260811-221420_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d1_pid3806401/target_gemm.fsdb`

## 이전 2-bank writer-side fence 결과: correctness PASS, source-streaming 성능 목표 실패

Writer-side consume fence를 구현했다. Weight child issue에는 source tile-ready wait만
남기고, exact W_CONSUME RID/target은 command별 `writer_wait`로 Weight executor FIFO에
저장한다. Source read/response는 consume 전에 진행할 수 있고, destination write는
writer target과 기존 `wreg_busy` gate가 모두 만족될 때만 발생한다. Completion/notify는
마지막 actual WREG write 시점을 유지한다.

Directed VCS 결과는 모두 PASS했다.

- Weight overlap, GEMM FSM/controller, TMEM wide-read, GEMM unit/sync, generic LDMA 통과
- Source-before-consume, stale/wrong-buffer release 차단, consume-before-accept,
  two-inflight/8-slot, ordered write/completion과 reset cleanup 통과
- M=4 QCOL/QROW node integration이 각각 1024 elements numerical PASS

XRT-VCS의 `M={4,256} x QDIR={QCOL,QROW}` 네 case도 모두 numerical PASS했다.
M=4의 input/Weight fire-stall은 각각 `256/0`, `256/0`이었고 M=256은
`16384/0`, `512/0`이었다. Functional assertion, fatal 또는 timeout은 없었다.

그러나 M=4 QCOL FSDB에서 strict source-streaming 목표는 실패했다.

- 64 Weight command, source request/response와 destination write 각각 256회
- Writer fence가 있는 62/62 command가 matching consume 전에 enqueue/source-prefetch됨
- Early same-buffer write, wrong release, busy-buffer write는 모두 0회
- WREG0/WREG1은 32/32로 정확히 교대하고 FIFO/slot 최대 occupancy는 2/8
- Consume에서 같은 command의 첫 write까지 62/62 모두 1 cycle
- 하지만 CMD N+1 source와 CMD N destination write overlap은 `2/63`뿐임
- Source burst boundary gap은 `min=0, median=9, p75=11, max=16` cycle
- Destination burst boundary gap도 `min=0, median=9, p75=11, max=16` cycle

따라서 writer fence는 post-consume source latency를 기존 median 7 cycle에서 1 cycle로
줄이고 overwrite correctness도 유지했지만, Weight source engine을 steady-state로
saturate하거나 burst 간격을 0~1 cycle로 만드는 목표는 달성하지 못했다. Executor가
두 command/8 slot을 보유하고 consume 전에 source를 읽을 수 있어도 upstream의 Weight
command/source 실행 cadence가 여전히 bursty하기 때문이다.

QROW simulation과 FSDB 생성은 numerical PASS했지만, QCOL에서 핵심 성능 목표 실패가
확인된 즉시 Hard Rule에 따라 QROW waveform 분석과 추가 RTL 변경을 중단했다. 다음
단계에서는 현재의 1-cycle consume-to-write 개선을 수용할지, 아니면 upstream command
production cadence를 별도 설계 문제로 다룰지 먼저 논의해야 한다.
