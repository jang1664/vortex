# Overview
command scheduling의 최적화를 한다.
command의 dependency가 resolve 됐을 때 최대한 빨리 issue하는 것을 목표로 한다.

# 문제점

## 분석 범위

최적화 범위는 `VX_gemm_fsm`이 command를 생성한 시점부터 해당 command가 실제 downstream
executor의 start handshake로 전달되는 시점까지다.

```text
VX_gemm_fsm
  -> 1-entry command staging register
  -> parent command FIFO
  -> VX_gemm_sync WAIT/NOTIFY 처리 및 child route
  -> child command FIFO
  -> downstream executor start handshake
```

Weight, scale/ZP, input/output LDMA 및 global DMA executor가 command를 받은 뒤 실제 작업을
완료하는 데 걸리는 latency와 executor 자체의 처리량은 독립적인 문제로 취급한다. 예를 들어
weight executor 내부 전송 시간이 길더라도 그 시간 자체는 이 문서의 최적화 대상이 아니다.
여기서는 dependency가 이미 resolve됐거나 executor가 새 command를 받을 수 있는데도 command
전달 구조 때문에 생기는 cycle만 다룬다.

아래 수치는 WLOAD8, `M=4, N=256, K=256, QBLK=32, WTRANS=0, QDIR=1` XRT-VCS trace를
기준으로 한다.

## 1. WAIT/NOTIFY command에 의한 sync overhead

현재 FSM이 생성하는 command 사이의 dependency는 명시적인 `WAIT`와 `NOTIFY` command로
표현된다. executor 작업이 완료된 뒤에도 다음 순서가 추가로 필요하다.

```text
executor completion 감지
  -> child queue의 NOTIFY issue
  -> sync register update
  -> parent queue head의 WAIT가 다음 cycle에 update 관측
  -> WAIT pop
  -> 뒤 command route
```

NOTIFY update와 WAIT 비교 사이에는 combinational bypass가 없고, non-input child의
`child_cmd_inflight_r`도 executor가 idle로 돌아온 다음 cycle에 해제된다. 따라서 dependency
완료 signal이 발생한 cycle에 waiting command를 executor로 바로 issue할 수 없다.

target trace에서 총 714개 FSM command 중 `WAIT=213`, `NOTIFY=212`로, 425개(59.5%)가
실제 data movement나 compute를 수행하지 않는 sync command였다. 이 command들도 FSM 생성,
staging register, parent FIFO, sync dispatcher 및 일부 child FIFO의 대역폭과 entry를 사용한다.

## 2. 단일 in-order parent FIFO의 head-of-line blocking

parent command FIFO의 head가 만족되지 않은 WAIT이면 그 뒤에 있는 command는 서로 독립적인
executor로 향하더라도 route될 수 없다. 예를 들어 `RID_G` WAIT 뒤에 REG0/REG1 weight 또는
scale/ZP preload가 있으면 W/SZ executor가 idle하고 target register가 현재 GEMM과 충돌하지
않아도 WAIT가 해제될 때까지 child queue에 들어가지 못한다.

즉 현재 command stream은 실제 dependency graph보다 강한 global program order를 만든다.

```text
parent FIFO head: WAIT RID_G
behind head:      W preload -> SC preload -> ZP preload

RID_G가 unresolved인 동안:
  input dependency와 무관한 W/SZ preload도 route 불가
```

이 문제는 parent FIFO depth만 늘려서는 해결되지 않는다. 더 많은 command를 저장할 수는 있지만
unresolved WAIT를 건너뛰어 독립 command를 route할 수 없기 때문이다.

## 3. Double buffer는 존재하지만 preload command가 충분히 일찍 전달되지 않음

Weight와 scale/ZP register는 REG0/REG1 ping-pong으로 동작한다. FSM도 current register를
준비한 뒤 반대편 `~mxu_buf_q`의 W/SC/ZP preload command를 생성하므로 register index와
functional double buffering 자체는 정상이다.

그러나 steady state에서 refill command의 FSM issue 간격은 다음과 같았다.

```text
W refill issue
  +22 cycles: SC refill issue
  + 7 cycles: ZP refill issue
  + 5 cycles: 다음 I_ARM issue
```

해당 state에는 별도의 data dependency 조건이 없으므로 이 22/7-cycle gap은 executor 내부
처리 시간이 아니라 `can_emit` backpressure, parent FIFO 포화 및 앞선 WAIT의 in-order
blocking으로 발생한다.

실제 weight register는 REG0/REG1 순서로 정상 교대했지만, 이전 weight ready부터 반대편
weight load start까지 일반적으로 7 cycle이 비었다. 이 중 일부는 독립적인 SZ readiness를
기다리는 global command order 때문에 발생한다. 다음 input이 register를 사용하기 전에
weight는 12 cycle, scale/ZP는 8 cycle 먼저 ready였지만, scale/ZP readiness는 현재 input의
raw ACC writeback보다 2 cycle 늦었다. 따라서 command-finish 최적화로 확보한 early window가
W/SZ command scheduling에 가려져 next input이 이전 writeback보다 먼저 시작하지 못했다.

## 4. Dependency가 없는 command에도 고정 전달 latency가 존재함

WAIT에 추가로 block되지 않는 일반 I_ARM command도 FSM accept부터 실제 input executor
start까지 trace에서 일관되게 5 cycle이 걸렸다.

```text
FSM command accept
  -> staging register
  -> BRAM parent FIFO
  -> sync route
  -> child FIFO
  -> executor start
```

현재 구조에는 queue가 비어 있고 downstream이 ready여도 command를 직접 전달하는 fall-through
또는 bypass path가 없다. 따라서 dependency가 이미 resolve된 command도 위 pipeline latency를
항상 지불한다.

## 5. 단일 command 생성/route 대역폭과 불필요한 직렬화

FSM과 parent route는 cycle당 최대 한 command만 처리한다. W와 SZ처럼 서로 다른 executor로
향하는 독립 command도 한 linear stream에서 순서대로 생성되고 route된다. 여기에 WAIT/NOTIFY가
끼어들어 실제 work command의 issue slot을 밀어낸다.

cycle당 한 command라는 제한만으로 현재 성능 병목이라고 단정할 수는 없지만, explicit sync
command를 제거한 뒤에도 독립 executor로 동시에 issue할 수 없는 구조는 남는다. 따라서 새
scheduler에서는 다음 두 문제를 분리해서 평가해야 한다.

1. dependency resolve 후 executor issue까지 불필요한 bubble이 있는가
2. 같은 cycle에 서로 다른 executor가 ready일 때 둘 이상의 독립 command를 issue할 필요가 있는가

# 해결책

- WAIT와 NOTIFY COMMAND를 없애자. 그리고 command에 dependency 정보를 embed하자. 즉 어떤 command를 wait 해야하는지 command 내부에 적어두자. 그리고 command의 executor에서는 command가 종료되는 직후 cycle에 signal을 emit해서 sync register를 update하자. Waiting command는 sync register의 값과 동시에 현재 cycle에 sync register가 update되는지 까지 파악해서 해당 cycle에 바로 dependency를 resolve하고 가능하면 바로 executor로 issue한다.

- command에 NOTIFY와 WAIT 정보를 embed하자. NOTIFY의 경우 command가 끝나면 어떤 register에 어떤 값을 어떻게 update할지를 적어둔다. WAIT의 경우에는 어떤 sync register가 어떤 condition을 만족하는 것을 기다릴지 적어둔다.

- FSM은 별도의 `OP_WAIT`와 `OP_NOTIFY` command를 생성하지 않는다. LOAD, COMPUTE, STORE 같은
  실제 work command를 생성할 때 해당 command의 dependency와 completion metadata를 직접
  설정한다. 기존 WAIT/NOTIFY command stream을 뒤에서 변환하는 constructor는 두지 않는다.

- 각 work command에는 completion 시 수행할 NOTIFY metadata를 한 group 둔다.

  ```text
  notify = {
      valid,
      reg_id,
      update_mode,  // SET 또는 PLUS
      value
  }
  ```

  한 command가 완료될 때 최대 하나의 sync register를 update하는 contract를 사용한다.

- 각 work command에는 최대 4개의 WAIT group을 둔다.

  ```text
  waits[0:3] = {
      valid,
      reg_id,
      target
  }
  ```

  wait condition은 `sync_value[reg_id] >= target` 하나로 고정하므로 별도의 condition opcode는
  저장하지 않는다. valid WAIT group이 모두 만족해야 command가 child FIFO head에서 issue된다.

- Dependency resolve와 command issue를 서로 다른 의미로 분리한다. child FIFO head의 dependency가
  resolve되지 않았으면 dependency mask가 FIFO output valid를 막아 executor에는 `valid=0`으로
  보인다. 모든 dependency가 resolve되면 mask만 clear되어 executor에 command가 valid하게
  보인다.

  ```systemverilog
  head_deps_ready = 1'b1;
  for (int d = 0; d < 4; ++d) begin
    if (head_cmd.waits[d].valid)
      head_deps_ready &= effective_sync[head_cmd.waits[d].reg_id]
                      >= head_cmd.waits[d].target;
  end

  dependency_mask       = !head_deps_ready;
  dependency_eligible   = child_fifo_valid && !dependency_mask;
  inflight_can_accept   = !child_inflight_full || executor_done;
  // 현재 executor는 child마다 active command를 하나만 허용한다.
  single_active_ready   = child_inflight_empty || executor_done;
  executor_cmd_valid    = dependency_eligible
                       && inflight_can_accept
                       && single_active_ready;
  issue_fire            = executor_cmd_valid && executor_cmd_ready;
  child_fifo_pop        = issue_fire;
  ```

  여기서 dependency mask clear는 command가 issue 가능한 eligibility를 얻었다는 뜻일 뿐 실제
  issue가 아니다. executor가 ready가 아니면 command는 FIFO head에 그대로 남고 dependency-eligible
  상태를 유지한다. FIFO pop, executor inflight metadata capture 및 command start는 오직
  `issue_fire`에서만 발생한다.

  Inflight slot의 수용 가능 여부는 별도의 capacity gate다. Slot이 full이고 같은 cycle done도 없으면
  executor-facing valid를 0으로 막아 executor handshake와 child FIFO pop이 어긋나지 않게 한다.
  반대로 full 상태에서도 같은 cycle done이 있으면 `inflight_can_accept=1`로 만들어 oldest slot pop과
  새 metadata push를 동시에 허용한다. 이 gate는 dependency가 resolve됐다는 사실 자체를 되돌리지
  않는다.

  현재 executor interface에서는 같은 child에 active command가 두 개 생기지 않는다. 따라서 issue는
  inflight empty 상태 또는 oldest completion과 새 issue가 겹치는 cycle에만 허용한다. Child별
  2-entry FIFO는 독립적인 in-order metadata 경계로 유지하며, 이후 DMA pipeline 최적화로 두 entry를
  실제 사용할 때도 child 내부 completion은 issue 순서를 따른다. 이 계약이 깨져 out-of-order
  completion이 가능해지는 시점에만 issue/completion tag를 interface에 추가한다.

- Same-cycle completion은 registered sync value가 아니라 current completion update까지 적용한
  effective sync view를 통해 dependency mask만 즉시 clear한다.

  ```text
  effective_sync[rid] = apply_same_cycle_updates(sync_reg[rid], completions[])
  ```

  그 cycle에 executor가 command를 실제로 가져갈 수 있는지는 inflight capacity gate를 통과한 뒤
  독립적인 `executor_cmd_ready`가 결정한다. scheduler는 same-cycle accept를 강제하지 않으며,
  executor가 ready를 늦게 올려서 생기는 시간은 executor-side availability로 분류한다.

  필수 invariant는 다음과 같다.

  ```text
  !head_deps_ready -> !executor_cmd_valid
  executor_cmd_valid -> child_fifo_valid && head_deps_ready
                     && inflight_can_accept && single_active_ready
  child_fifo_pop == issue_fire
  dependency_eligible && (!inflight_can_accept || !executor_cmd_ready) -> FIFO head와 metadata 유지
  same_cycle_completion_resolves_head -> dependency_eligible, if child_fifo_valid
  ```

- parent queue와 WAIT/NOTIFY command가 제공하던 implicit global ordering은 더 이상 사용하지
  않는다. 모든 work command는 correctness에 필요한 dependency를 자신의 `waits[0:3]`에 전부
  명시한다. 서로 다른 child FIFO의 command는 metadata에 적힌 dependency 외에는 서로의 issue
  순서를 보장하지 않는다.

- 기존 NOTIFY의 SET/PLUS mode와 value는 producer work command의 notify metadata로 그대로
  이동한다. 한 cycle에 같은 sync register를 둘 이상의 executor가 update하는 동작은 지원하지
  않고 pairwise assertion으로 금지한다.

  ```systemverilog
  for (int i = 0; i < N_EXECUTORS; ++i)
    for (int j = i + 1; j < N_EXECUTORS; ++j)
      assert (!(completion_fire[i]
             && completion_fire[j]
             && notify_meta[i].valid
             && notify_meta[j].valid
             && notify_meta[i].reg_id == notify_meta[j].reg_id));
  ```

  `RID_O`는 두 executor가 공유하지만 명시적인 dependency로 completion 순서를 직렬화한다.

  1. child 3 `OP_O_ACC2LMEM`: ACC MEM -> LMEM 완료 시 odd target을 SET
  2. child 4 `OP_DMA_ST`: LMEM -> DRAM 완료 시 PLUS 1하여 다음 even target 생성

  `OP_DMA_ST`는 대응하는 ACC2LMEM odd target을 wait하고, 다음 `OP_O_ACC2LMEM`은 이전 DMA_ST의
  even target을 wait한다. 따라서 두 executor가 같은 cycle에 `RID_O`를 update하는 것은 design
  contract 위반이다.

- NOTIFY는 executor가 직접 실행하지 말고 executor는 done signal만 emit하면 scheduler가 done signal을 보고 sync register를 update한다.

- Scheduler는 command가 executor에 issue될 때 completion metadata를 해당 child의 2-entry
  inflight slot에 저장한다. Completion metadata에는 notify metadata를 포함한다. `notify.valid=0`인
  command도 완료될 때까지 slot 하나를 점유해야 scheduler가 실행 중인 command를 quiescent로
  오판하지 않는다. Executor done은 가장 오래된 inflight slot을 retire하고, 그 slot의 valid한
  notify metadata로 sync register를 update한다. 같은 child의 completion은 issue 순서대로
  발생하는 contract를 사용한다.

  ```text
  issue_fire:
      child FIFO pop
      inflight metadata FIFO push(command.completion_metadata)

  executor_done:
      inflight metadata FIFO head의 valid notify publish
      inflight metadata FIFO pop
  ```

  2-entry slot은 done과 새 issue가 같은 cycle에 발생하는 push/pop을 지원한다. Scheduler는
  inflight slot이 full이면 추가 issue를 막고, empty 상태에서 done이 발생하면 assertion으로
  실패시킨다. 현재는 child별 active command가 하나를 넘지 않는 경계도 assertion으로 검증한다.
  Completion 순서는 executor의 in-order contract로 보장하며, out-of-order를 지원할 때는 untagged
  done을 계속 사용하지 않고 completion tag를 추가한다.

- Executor별 architectural done event는 다음으로 고정한다.

  - input: non-final command는 qualified I_LDMA idle, final command는 tagged ACC writeback
  - weight: 해당 command의 마지막 weight register write
  - scale/ZP: 해당 SC 또는 ZP command의 마지막 register write
  - output: 해당 ACC-to-LMEM command의 마지막 LMEM write
  - global DMA: 모든 channel의 실제 load/store completion

- parent queue를 없앤다. child queue만 사용하고 FSM이 생성하는 command를 바로 child queue에 넣어준다. child queue는 지금 쓰는 것과 같은 일반적인 queue다.

- `OP_CLEAR`도 제거한다. FSM이 IDLE에서 새 invocation의 initial state로 넘어가는 accept
  event에서 모든 sync register를 implicit하게 clear한다. 따라서 clear를 위한 command slot,
  route 또는 executor는 사용하지 않는다.

- Invocation lifecycle은 strict quiescence를 사용한다.

  ```text
  all_child_queues_empty = 모든 child FIFO empty
  all_inflight_empty     = 모든 child의 2-entry inflight slot empty
  scheduler_quiescent    = all_child_queues_empty && all_inflight_empty

  new_invocation_ready   = fsm_idle && scheduler_quiescent
  ```

  FSM이 마지막 command를 생성해 IDLE에 들어간 뒤에도 scheduler가 quiescent가 될 때까지 새
  invocation을 받지 않는다. `done_if`도 active invocation에서 FSM IDLE과 scheduler quiescence가
  함께 성립할 때만 발생한다. Sync register implicit clear는 `new_invocation_ready` 상태에서 실제
  config accept가 발생한 cycle에 수행한다. 따라서 old completion과 clear가 겹치지 않으며 job
  epoch는 사용하지 않는다.

- 초기 구현의 child queue는 fall-through가 없는 일반 registered FIFO를 사용한다. FSM enqueue는
  먼저 FIFO에 저장되고, dependency가 resolve된 FIFO head는 다음 cycle 이후 executor에 valid로
  보인다. Queue empty bypass는 초기 구현에 넣지 않는다.

  성능 검증에서 invocation active cycle 기준으로 child별 empty cycle 비율을 측정한다.

  ```text
  child_empty_ratio[child]
      = child_empty_cycles[child] / invocation_active_cycles
  ```

  empty 비율과
  `empty && enqueue && incoming_deps_ready && inflight_can_accept
  && single_active_ready && executor_ready` fall-through
  opportunity가 크면 후속 최적화로 fall-through FIFO를 고려한다. 그렇지 않으면 registered FIFO를
  유지한다.

- 특정 child queue가 full이어서 FSM command 생성이 잠시 stall하는 것만으로는 문제로 보지
  않는다. 다음 조건이 모두 성립할 때만 FSM-level HOL blocking이 실제로 발생한 것으로 판정한다.

  1. FSM head command의 target인 `child1` queue가 full이어서 push할 수 없다.
  2. command stream에서 그 뒤에 생성될 command의 target인 `child2` queue는 empty다.
  3. `child2` command는 unresolved dependency가 없어 즉시 issue 가능한 command다.
  4. 오직 `child1` full 때문에 FSM이 `child2` command까지 생성하지 못한다.

  이 상황이 trace에서 실제로 발생하면 해당 child queue의 depth를 늘려 해결한다. 발생하지
  않는다면 route별 staging, issue window 또는 full child를 건너뛰는 복잡한 scheduler는
  추가하지 않는다. 각 child별 `fifo_full_block_cycles`와
  `fifo_full_blocks_ready_other_child`를 측정해 판정 근거로 사용한다.

# 참고사항
- feat/gemv-opt branch를 참고한다. 비슷하게 구현된 RTL이 있다. 관련된 부분만 참고한다.

# unresolved issues

현재 합의된 architecture에 unresolved issue는 없다. Registered child FIFO의 empty 비율과
fall-through opportunity는 구현 후 성능 계측으로 판단하는 optional optimization이다.

# 구현계획

## Phase 0. Command metadata와 dependency matrix 정의

1. Work command payload에 notify metadata 한 group과 WAIT metadata 네 group을 추가한다.
2. WAIT comparator는 `sync_value >= target`으로 고정한다.
3. 모든 work command에 필요한 dependency를 직접 기록한 opcode/state별 matrix를 작성한다.
4. 각 command의 notify owner, SET/PLUS mode와 value를 기존 command stream과 대조한다.
5. command당 notify 최대 1개, WAIT 최대 4개임을 static/runtime assertion으로 고정한다.

## Phase 1. FSM command stream 단순화와 direct child enqueue

1. FSM에서 `OP_WAIT`, `OP_NOTIFY`, `OP_CLEAR` command 생성을 제거한다.
2. LOAD/COMPUTE/STORE command 생성 state에서 waits/notify metadata를 직접 설정한다.
3. Parent staging register, parent FIFO 및 opcode 기반 WAIT/NOTIFY route를 제거한다.
4. FSM command를 target child FIFO에 직접 enqueue한다.
5. Target child FIFO full일 때만 FSM command accept를 stall한다.

## Phase 2. Sync scoreboard와 dependency valid mask

1. Sync register의 기존 SET/PLUS semantics를 유지한다.
2. 같은 RID를 둘 이상의 executor가 같은 cycle에 update하지 않는 pairwise assertion을 추가한다.
3. Same-cycle completion을 적용한 `effective_sync` view를 생성한다.
4. 각 child FIFO head의 최대 4개 WAIT를 비교해 dependency mask를 만든다.
5. `dependency_eligible = fifo_valid && deps_ready`를 만든 뒤 inflight capacity로 executor-facing
   valid를 gate하고, FIFO pop은 executor issue handshake에만 연결한다.
6. Dependency가 resolve됐지만 executor ready가 낮을 때 FIFO head와 metadata가 유지되는지 검증한다.

## Phase 3. Per-child 2-entry inflight metadata slot

1. 각 child에 2-entry in-order inflight metadata FIFO를 추가한다.
2. Executor issue에서 notify valid 여부와 관계없이 completion metadata를 push하고, done에서
   oldest metadata를 pop한 뒤 valid notify만 publish한다.
3. Done과 새 issue의 same-cycle push/pop을 지원한다.
4. `inflight_can_accept = !inflight_full || executor_done`으로 정의해 executor-facing valid를 gate하고,
   현재는 `inflight_empty || executor_done`으로 single-active 경계를 함께 적용한다. Empty done,
   overflow 및 single-active 위반을 assertion으로 막고 child 내부 in-order completion을 executor
   contract로 둔다. Out-of-order completion이 가능해지는 최적화에서 tag를 추가한다.
5. Input, W, SC/ZP, output, global DMA의 확정한 architectural done event를 연결한다.

## Phase 4. Strict quiescence와 implicit clear

1. 모든 child FIFO empty와 모든 inflight slot empty를 `scheduler_quiescent`로 정의한다.
2. `new_invocation_ready = fsm_idle && scheduler_quiescent`로 config accept를 gate한다.
3. Config accept에서 `invocation_active`를 set하고, active invocation에서 FSM IDLE과 scheduler
   quiescence가 함께 성립할 때 `done_if`를 한 번 발생시킨 뒤 clear한다.
4. 새 invocation accept cycle에 sync register를 implicit clear한다.
5. Clear와 completion 비동시, done 이전 새 config 금지, quiescent 판정 정합성을 assertion으로 검증한다.

# 검증 계획

## Phase 5. RTL unittest

1. 최대 4개 WAIT의 all-ready/one-blocked 및 same-cycle resolve를 검증한다.
2. Dependency 미해결 시 executor valid 차단, 해결 후 valid 유지, ready handshake에서만 pop을 검증한다.
3. SET/PLUS update, 동일 RID collision assertion과 `RID_O` child3/child4 ordering을 검증한다.
4. 물리적인 2-entry inflight FIFO를 유지하면서 현재 single-active 차단, oldest done과 새 issue의
   same-cycle pop/push, in-order SET/PLUS retirement와 stray done assertion을 검증한다.
5. `notify.valid=0` command도 done 전까지 inflight를 점유해 quiescence를 막는지 검증한다.
6. Strict quiescence, implicit clear, back-to-back invocation lifecycle을 검증한다.
7. FSM command stream에 WAIT/NOTIFY/CLEAR opcode가 없고 모든 work command metadata가 reference
   dependency matrix와 일치하는지 확인한다.

## Phase 6. XRT-VCS 기능 및 성능 검증

필요한 경우 build_* 를 만들고 안에서 "../configure ......" 를 수행하고 "make -C hw config" 를 수행한 이후에 검증을 해도 된다. 여러 configuration을 비교할 때 용이하다.

1. `fpint_gemm_ffn_hw` M=4 target을 WLOAD 8에서 검증한다.
2. Output numerical result, `psum_underflow=0`, `rd_wr_conflict=0`을 확인한다.
3. FSM command accept부터 child enqueue, dependency valid, executor issue까지 latency를 측정한다.
4. Completion부터 dependent command valid까지 same-cycle resolve 여부를 측정한다.
5. Child별 FIFO full block cycle과 실제 HOL 조건 발생 여부를 측정한다.
6. Child별 empty cycle 비율과 fall-through opportunity를 측정한다.
7. Empty/opportunity 비율이 큰 child만 후속 fall-through FIFO 후보로 기록한다.


# HARD RULE

계획 수행 도중에 계획한 설계에서 문제가 발견되면 즉시 멈추고 문제를 보고한다.  그 이후에 해결책을 논의한다.
