# GBAR (Global Barrier) — 정리

요약
- GBAR(Global Barrier)은 코어/워프 단위의 배리어 동기화를 하드웨어로 지원하는 모듈군입니다. 각 코어(또는 워프)가 배리어에 "도착" 신호를 보내면, 설정된 참가자 수가 모두 도착했을 때 배리어를 해제(응답)합니다. 요청은 계층적으로 집계될 수 있으며(코어 → 소켓 → 클러스터), 단일 `gbar_unit`이 최종적으로 참가자를 추적하고 해제합니다.

관련 파일
- 인터페이스: `hw/rtl/mem/VX_gbar_bus_if.sv` (요청/응답 포맷 정의)
- 아비터: `hw/rtl/mem/VX_gbar_arb.sv` (여러 입력을 단일 출력으로 중재, 응답 브로드캐스트)
- 배리어 유닛: `hw/rtl/mem/VX_gbar_unit.sv` (마스크/카운터로 참가자 추적 및 해제 응답)
- 사용 위치: `hw/rtl/VX_socket.sv`, `hw/rtl/VX_cluster.sv` (계층적 연결)
- 요청 생성자(원천): `hw/rtl/core/VX_wctl_unit.sv` (warp control에서 barrier 필드 생성)
- 요청 발행(실제 gbar 요청을 보내는 모듈): `hw/rtl/core/VX_schedule.sv` (조건 만족 시 `gbar_bus_if.req_*`에 쓰기)

인터페이스 요약 (`VX_gbar_bus_if`)
- req_data:
  - `id` : barrier identifier (NB_WIDTH)
  - `size_m1` : 기대 참가자 수 - 1 (NC_WIDTH)
  - `core_id` : 요청을 보낸 core id (NC_WIDTH)
- rsp_data:
  - `id` : 해제된 barrier id
- 핸드셰이크: `req_valid` / `req_ready`, `rsp_valid` / `rsp_data` (응답은 브로드캐스트)

요청 생성: 어디서, 어떻게
- barrier 생성(원천): `VX_wctl_unit.sv`
  - 실행 유닛의 결과(레지스터 rs1/rs2)에서 barrier 필드가 구성됩니다.
  - 관련 코드(요약):

```systemverilog
// VX_wctl_unit.sv
assign barrier.valid    = is_bar;
assign barrier.id       = rs1_data[NB_WIDTH-1:0];
`ifdef GBAR_ENABLE
  assign barrier.is_global= rs1_data[31];
`else
  assign barrier.is_global= 1'b0;
`endif
assign barrier.size_m1  = rs2_data[$bits(barrier.size_m1)-1:0] - $bits(barrier.size_m1)'(1);
```

  - 설명: `rs1_data`의 비트(예: bit 31)를 보고 `is_global`을 결정하고, `rs2_data`에 있는 참가자 수 필드에서 1을 뺀 값을 `size_m1`으로 설정합니다. 즉, ISA/명령에서 전달된 size 값을 내부적으로 `size - 1` 포맷으로 저장합니다.

- 실제 gbar 요청 발행: `VX_schedule.sv`
  - `warp_ctl_if.barrier` (warp control에서 전달된 barrier 정보)를 기반으로, 현재 워프 상태가 전부 도착한 시점에 `gbar_bus_if`로 요청을 보냅니다.
  - 관련 코드(요약):

```systemverilog
// VX_schedule.sv (핵심 부분)
`ifdef GBAR_ENABLE
  if (warp_ctl_if.valid && warp_ctl_if.barrier.valid
   && warp_ctl_if.barrier.is_global
   && !warp_ctl_if.barrier.is_noop
   && (curr_barrier_mask_p1 == active_warps)) begin
      gbar_req_valid <= 1;
      gbar_req_id <= warp_ctl_if.barrier.id;
      gbar_req_size_m1 <= NC_WIDTH'(warp_ctl_if.barrier.size_m1);
  end
  if (gbar_bus_if.req_valid && gbar_bus_if.req_ready) begin
      gbar_req_valid <= 0;
  end
`endif

// assign out
assign gbar_bus_if.req_valid        = gbar_req_valid;
assign gbar_bus_if.req_data.id      = gbar_req_id;
assign gbar_bus_if.req_data.size_m1 = gbar_req_size_m1;
assign gbar_bus_if.req_data.core_id = NC_WIDTH'(CORE_ID % `NUM_CORES);
```

  - 설명: `VX_schedule`는 warp-level 상태(활성 워프 집합 `active_warps`와 현재 barrier 마스크 `curr_barrier_mask_p1`)를 보고, 모든 참여 워프가 도달했을 때(=동일하면) 글로벌 배리어 요청을 발행합니다. `gbar_req_size_m1`은 `warp_ctl_if.barrier.size_m1`을 그대로 사용(필드 폭으로 캐스팅)합니다. `core_id` 필드는 해당 코어의 ID(`CORE_ID % NUM_CORES`)로 설정됩니다.

size_m1(요청 참가자 수 - 1) 산정 규칙
- 생성 위치: `VX_wctl_unit.sv`에서 `barrier.size_m1`이 다음과 같이 계산됩니다:

```systemverilog
assign barrier.size_m1  = rs2_data[$bits(barrier.size_m1)-1:0] - $bits(barrier.size_m1)'(1);
```

- 해석: 명령에서 전달된 값(예: `rs2_data`의 저위 비트들)을 읽어 그 값에서 1을 뺀 결과를 `size_m1`으로 저장합니다. 즉, 명령 필드에 "size"가 들어있다면 내부 표현은 `size - 1`입니다.
- 전달/사용 흐름: 이 `size_m1` 값이 `warp_ctl_if`를 통해 `VX_schedule`로 전파되고, `VX_schedule`는 이를 `gbar_bus_if.req_data.size_m1`으로 할당하여 GBAR 계층으로 전송합니다.

응답/해제 동작 요약
- `VX_gbar_unit`는 내부적으로 `barrier_masks` 배열을 유지하고, 요청이 들어올 때마다 해당 코어 비트를 세트합니다. `POP_COUNT`로 활성 참가자 수를 계산해 기대 참가자 수(`size_m1 + 1`)와 일치하면 마스크를 클리어하고 `rsp_valid`/`rsp_data.id`를 통해 해제 신호를 보냅니다. 응답은 `gbar_arb`를 통해 브로드캐스트되어 모든 입력 측에 전달됩니다.

참고 코드 위치(주요 참조)
- `hw/rtl/mem/VX_gbar_bus_if.sv` : 인터페이스 정의
- `hw/rtl/mem/VX_gbar_arb.sv` : 입력 병합/응답 브로드캐스트
- `hw/rtl/mem/VX_gbar_unit.sv` : barrier 마스크/해제 구현
- `hw/rtl/core/VX_wctl_unit.sv` : barrier 필드( `is_global`, `size_m1`, `id`) 생성
- `hw/rtl/core/VX_schedule.sv` : global barrier 요청 조건 및 `gbar_bus_if`에 데이터 할당

간단 요약 문장
- GBAR 요청은 명령 실행(주로 `VX_wctl_unit`)으로 생성된 barrier 필드가 스케줄러(`VX_schedule`)에 의해 모두 도달했을 때 실제로 `gbar_bus_if`로 발행됩니다. `size_m1`은 명령에 주어진 size에서 1을 뺀 값으로 내부 표현되며, 최종적으로 GBAR 유닛이 참가자 마스크를 관리하여 해제 시점을 결정합니다.
