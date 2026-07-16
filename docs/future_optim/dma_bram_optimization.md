# Aligned DMA response SRAM 기반 LUT/FF 최적화 계획

- 상태: 설계 제안
- 대상: `hw/rtl/core/VX_dma_unit_align.sv`, `hw/rtl/mem/VX_dma_engine.sv`
- 기준 빌드: `xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1`

## 범위

이 문서는 aligned DMA만 다룬다.

- source와 destination base/stride는 각 port beat 경계에 정렬되어 있다.
- source와 destination port width는 같거나 서로 정수배이다.
- `VX_dma_unit_align`의 response slot과 destination write path를 대상으로 한다.
- `VX_dma_unit_misal`과 `VX_lmem_dma_misal`은 이 문서의 범위에서 제외한다.
- misaligned access의 byte shift, pack, partial-lane 문제는 별도 문서에서
  검토한다.

DMA channel 수, outstanding 수, descriptor 형식은 1차 변경에서 유지한다.

## 목표

- source read response payload는 명시적인 1R1W SRAM에 한 번만 저장한다.
- destination write data는 SRAM read output에서 직접 구동한다.
- SRAM 뒤에 별도의 wide output register를 추가하지 않는다.
- output stall 시 SRAM read를 중단하여 현재 SRAM output을 유지한다.
- address, byte enable, slot ID와 같은 작은 metadata만 FF 또는 narrow
  elastic buffer에 저장한다.
- 기존 wide `wr_slot_buf`와 destination request payload buffer를 제거하거나
  control-only buffer로 축소한다.
- pipeline 충전 후 가능한 최대 byte throughput을 유지한다.

## 기준 사용량

기준 리포트:

```text
/opt/vortex_fpga_bins/fpint/
  xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/bin/
  hier_utilization.rpt
```

리포트는 Vivado 2025.1 post-route physopt 결과이다.

| 영역 | LUT | FF | RAMB36 | DSP |
|---|---:|---:|---:|---:|
| `u_dma_engine` | 54,869 | 48,320 | 0 | 128 |
| 8개 aligned `u_dma_unit` 합계 | 52,522 | 47,392 | 0 | 128 |
| 채널당 aligned DMA | 6,389–6,853 | 5,924 | 0 | 16 |

8개 채널의 주요 wide buffer 비용은 다음과 같다.

| 버퍼 | LUT | FF |
|---|---:|---:|
| `dcache_req_buf` | 13,553 | 9,712 |
| `lmem_req_buf` | 872 | 9,408 |
| `wr_slot_buf` | 17,164 | 8,320 |
| 합계 | **31,589** | **27,440** |

전체 top은 RAMB36을 761/2,016개 사용하므로 BRAM을 수십~수백 개 추가해
LUT/FF와 routing congestion을 줄일 여유가 있다.

## 설계 결정

### 명시적인 `dp_sram` 사용

SRAM은 pragma 기반 inference로 만들지 않는다.

- `(* ram_style = "block" *)`을 사용하지 않는다.
- 현재 `VX_dp_ram`의 inferred array 구현을 사용하지 않는다.
- aligned DMA는 명시적인 `dp_sram` 모듈을 인스턴스한다.
- Xilinx primitive 또는 명시적인 memory macro 선택은 `dp_sram` 내부에
  격리한다.

현재 저장소에는 이름이 `dp_sram`인 모듈이 없으므로 구현 단계에서 모듈을
추가하거나 외부에서 제공되는 동일 계약의 모듈을 연결해야 한다.

필요한 SRAM 계약:

- 독립적인 1 write port와 1 read port
- read latency는 정확히 1 cycle
- `rd_en=0`일 때 `rd_data` 유지
- 서로 다른 주소에 대한 read/write 동시 수행
- payload memory 자체는 reset하지 않음
- 같은 주소의 동시 read/write는 상위 slot state로 금지

True dual-port 2RW SRAM은 필요 없다. Source response용 write port 하나와
destination drain용 read port 하나면 충분하다.

### SRAM output이 write holding entry 역할을 수행

SRAM 뒤에 별도의 `MAX_BYTES*8` 폭 output register를 두지 않는다. SRAM의
synchronous read output을 destination write data로 직접 사용한다.

작은 metadata만 register에 유지한다.

```systemverilog
logic                     out_valid_r;
logic [RD_SLOT_BITS-1:0]  out_slot_r;
logic [DST_ADDR_W-1:0]    out_addr_r;
logic [DST_BYTES-1:0]     out_byteen_r;
logic [FRAG_W-1:0]        out_frag_r;
```

```systemverilog
assign dst_req_valid  = out_valid_r;
assign dst_req_data   = select_fragment(sram_rd_data, out_frag_r);
assign dst_req_addr   = out_addr_r;
assign dst_req_byteen = out_byteen_r;
```

현재 output이 비었거나, 이번 cycle에 destination이 현재 slot의 마지막
fragment를 받는 경우에만 다음 SRAM read를 시작한다. Same-width에서는 모든
request가 마지막 fragment이므로 아래 조건이 기존 ready/valid stage와 동일하게
축약된다.

```systemverilog
wire dst_fire = out_valid_r && dst_req_ready;
wire out_last_frag = (out_frag_r == LAST_FRAG);
wire out_can_replace = !out_valid_r || (dst_fire && out_last_frag);
wire sram_rd_issue = out_can_replace && next_slot_ready;
```

`out_valid_r && !dst_req_ready`이면:

- `sram_rd_en=0`
- SRAM output 유지
- output metadata 유지
- 현재 slot을 `SLOT_DRAINING`으로 유지

현재 slot의 마지막 request가 받아지는 cycle에는 다음 slot read를 동시에
시작할 수 있다. 따라서 첫 read의 1-cycle latency 이후에는 SRAM 뒤의 추가
wide register 없이 연속 write가 가능하다.

## Slot 상태와 lifecycle

기존 상태에 drain 중 상태를 추가한다.

```text
SLOT_FREE
    |
    | source read request issue
    v
SLOT_WAIT_RSP
    |
    | source response -> SRAM write
    v
SLOT_READY
    |
    | SRAM read issue
    v
SLOT_DRAINING
    |
    | 마지막 destination write fire
    v
SLOT_FREE
```

핵심 규칙:

1. `SLOT_WAIT_RSP` slot만 SRAM write 대상으로 선택한다.
2. `SLOT_READY` slot만 SRAM read 대상으로 선택한다.
3. SRAM read issue 시 slot을 `SLOT_DRAINING`으로 바꾼다.
4. destination write가 stall되면 SRAM output과 metadata를 유지한다.
5. 해당 slot의 마지막 destination write가 accept된 후에만 `SLOT_FREE`로
   반환한다.
6. descriptor done은 모든 slot, SRAM output valid, request control queue가
   drain된 뒤에만 발생한다.

## Port width별 구조

`SRC_BYTES`와 `DST_BYTES`는 descriptor 방향에 따라 결정된다.

```systemverilog
SRC_BYTES = direction ? LMEM_BYTES   : DCACHE_BYTES;
DST_BYTES = direction ? DCACHE_BYTES : LMEM_BYTES;
MIN_BYTES = min(DCACHE_BYTES, LMEM_BYTES);
MAX_BYTES = max(DCACHE_BYTES, LMEM_BYTES);
```

기존 aligned DMA와 동일하게 한 port width가 다른 port width의 정수배인 경우만
지원한다.

### Case A: `SRC_BYTES == DST_BYTES`

가장 단순하며 1차 구현 대상이다.

```text
source response
    -> response SRAM write
    -> slot READY
    -> SRAM read
    -> SRAM output에서 destination write
    -> write fire 후 slot FREE
```

- response 하나가 SRAM entry 하나를 채운다.
- SRAM read 한 번이 destination write 한 번을 만든다.
- destination이 매 cycle ready이면 매 cycle 한 write beat를 보낼 수 있다.
- `wr_slot_buf`와 width-conversion window가 필요 없다.
- destination request의 wide data elastic buffer도 필요 없다.

### Case B: `SRC_BYTES > DST_BYTES` — wide to narrow

제안 구조를 그대로 사용할 수 있다.

예: 512-bit source response를 128-bit destination write 네 개로 분할한다.

```text
SRAM output = 512-bit payload, stall 또는 마지막 fragment까지 유지

fragment 0 -> bits [127:0]
fragment 1 -> bits [255:128]
fragment 2 -> bits [383:256]
fragment 3 -> bits [511:384]
```

동작:

1. wide source response 전체를 한 SRAM entry에 저장한다.
2. SRAM을 한 번 읽어 output을 유지한다.
3. `out_frag_r`로 narrow destination slice를 선택한다.
4. 각 destination write fire마다 `out_frag_r`를 증가시킨다.
5. 마지막 fragment가 accept되는 cycle에 다음 SRAM entry read를 시작한다.
6. 마지막 fragment 이후 현재 slot을 free한다.

추가 wide register는 필요 없다. SRAM output이 여러 destination write 동안
안정적으로 유지되어야 한다. Slice 선택 mux는 남지만 기존 MAX-width window와
wide elastic buffer의 중복 storage는 제거된다.

이론적인 destination beat rate는 매 cycle 1 beat이다. 한 source response를
모두 drain하는 데 `SRC_BYTES / DST_BYTES` cycle이 필요하므로 byte throughput은
port width에 맞게 유지된다.

### Case C: `SRC_BYTES < DST_BYTES` — narrow to wide

제안 구조를 사용할 수 있지만 response SRAM의 저장 방식을 바꿔야 한다.
여러 narrow response를 하나의 wide destination word로 조립해야 하기 때문이다.

단일 whole-word write SRAM에 narrow response를 하나씩 저장하면 다음 문제가
생긴다.

- 한 개의 read port로 여러 narrow entry를 같은 cycle에 읽을 수 없다.
- destination wide word 조립을 위해 별도 wide accumulator FF가 필요해진다.
- 이는 wide output register를 제거하려는 목표와 충돌한다.

따라서 preferred 구조는 `MIN_BYTES` 단위로 banked된 logical `dp_sram`이다.

```text
logical response SRAM entry, width = MAX_BYTES

+---------+---------+---------+---------+
| bank 3  | bank 2  | bank 1  | bank 0  |
| 128-bit | 128-bit | 128-bit | 128-bit |
+---------+---------+---------+---------+
```

각 bank는 동일 depth의 명시적 1R1W `dp_sram` 인스턴스다.

- narrow response는 해당 bank 하나에 write한다.
- wide response는 모든 bank에 같은 cycle에 write한다.
- drain read는 모든 bank를 같은 slot address로 동시에 읽는다.
- 각 bank output을 concatenate하여 wide destination data를 만든다.

Slot별로 작은 bank-valid mask를 FF에 유지한다.

```systemverilog
logic [NUM_BANKS-1:0] slot_bank_valid_r[RD_OUTSTANDING];
```

동작:

1. destination wide word 하나에 대응하는 group slot을 할당한다.
2. 각 narrow source read tag에 `{group_slot, bank_idx}`를 넣는다.
3. response가 도착하면 해당 bank에 write하고 valid bit를 set한다.
4. 필요한 bank가 모두 채워지면 group slot을 `SLOT_READY`로 바꾼다.
5. 모든 bank를 동시에 read하여 SRAM output에서 wide destination write를
   직접 구동한다.
6. destination write fire 후 group slot을 free한다.

이 방법은 별도 wide accumulator register 없이 narrow-to-wide 변환을 수행한다.
다만 기존 tag가 slot ID만 담던 것과 달리 bank index도 포함해야 한다.

필요 tag width:

```text
GROUP_SLOT_BITS + log2(NUM_BANKS)
```

Tag width가 부족하면 group slot 수를 줄이거나 response ordering을 별도로
보장해야 한다. Response가 항상 in-order라는 가정으로 bank index를 생략하지
않는다. 명시적인 tag가 더 안전하다.

마지막 partial group은 expected-bank mask와 valid-byte metadata를 별도로
저장하고 필요한 bank만 채워졌을 때 ready 처리한다.

## Unified banked SRAM 제안

동일 RTL로 세 width case를 지원하려면 처음부터 다음 형태를 사용하는 것이
좋다.

```systemverilog
localparam int NUM_BANKS = MAX_BYTES / MIN_BYTES;

for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_payload_bank
    dp_sram #(
        .DATAW (MIN_BYTES * 8),
        .DEPTH (RD_OUTSTANDING)
    ) payload_sram (
        .clk     (clk),
        .wr_en   (bank_wr_en[b]),
        .wr_addr (rsp_group_slot),
        .wr_data (rsp_bank_data[b]),
        .rd_en   (sram_rd_issue),
        .rd_addr (wr_expect_slot_r),
        .rd_data (sram_bank_data[b])
    );
end

assign sram_rd_data = sram_bank_data;
```

`NUM_BANKS == 1`이면 same-width 구조로 축약된다. Width mismatch이면 banked
storage가 width converter의 assembly/disassembly storage 역할까지 수행한다.

장점:

- pragma inference 없이 명시적인 memory instance 사용
- same-width, wide-to-narrow, narrow-to-wide 구조 통합
- narrow-to-wide partial response write 지원
- read 시 모든 bank가 병렬로 출력되므로 wide accumulator FF 불필요
- 물리 BRAM도 width 방향으로 분할되므로 구조와 배치가 자연스럽다.

비용:

- narrow-to-wide tag에 bank index 추가
- slot allocation 단위가 source beat가 아니라 destination group이 됨
- bank-valid/expected mask와 partial group 제어 추가
- BRAM packing 효율은 낮지만 의도적으로 허용

## Request control path

Payload는 response SRAM에만 저장한다. Request elastic buffer에는 payload를
넣지 않는다.

Source read request control:

```text
rw + address + flags + tag
```

Destination write control:

```text
address + byteen + slot ID + fragment index + last
```

Destination write data는 항상 SRAM output에서 가져온다. 따라서 현재
`dcache_req_buf`와 `lmem_req_buf`를 그대로 사용하지 않고 다음 중 하나로
재구성한다.

- source read에는 narrow control elastic buffer 사용
- destination write는 SRAM output holding entry에서 직접 구동
- timing isolation이 필요하면 payload 없이 metadata만 narrow elastic buffer에
  저장

## 구현 순서

### Phase 1: Same-width aligned DMA

- 명시적인 1R1W `dp_sram` 추가
- response payload를 SRAM으로 이동
- SRAM output direct-write holding protocol 구현
- `wr_slot_buf` 제거
- source request buffer를 control-only로 축소
- destination wide request buffer 제거

이 단계에서 width-conversion window는 기존 경로에 남겨도 된다. Same-width
config로 SRAM protocol과 resource 효과를 먼저 검증한다.

### Phase 2: Wide-to-narrow

- fragment index와 slice selector 추가
- SRAM output을 마지막 fragment까지 유지
- 마지막 fragment fire와 다음 SRAM read를 같은 cycle에 수행
- partial final beat의 byte enable 검증

### Phase 3: Narrow-to-wide

- SRAM을 `MIN_BYTES` 폭 bank들로 구성
- tag에 group slot과 bank index 추가
- bank-valid/expected mask 추가
- partial group 처리
- 기존 wide conversion window 제거

세 phase를 한 patch에서 구현하지 않는다. 각 단계의 기능, 자원, throughput을
독립적으로 측정한다.

## 검증 계획

RTL unittest와 blackbox 실행 전에는 config를 source하고 configure된 build
directory를 사용한다.

필수 테스트 축:

| 항목 | 값 |
|---|---|
| 방향 | L2G, G2L |
| width ratio | 1:1, 2:1, 4:1, 1:2, 1:4 |
| destination ready | 항상 ready, 주기적 stall, 장기 stall, random stall |
| response order | in-order, 가능한 경우 out-of-order |
| segment | 1 beat, multi-beat, partial final beat, 연속 segment |
| 동시 동작 | 서로 다른 slot의 SRAM read/write 동시 수행 |

필수 assertion:

- SRAM write는 `SLOT_WAIT_RSP` 또는 조립 중인 group slot에만 수행
- SRAM read는 모든 expected bank가 valid인 `SLOT_READY`에만 수행
- 동일 bank와 동일 slot 주소의 read/write 동시 수행 금지
- output stall 중 SRAM output과 metadata 안정
- `SLOT_DRAINING` slot에 response write 금지
- 마지막 fragment 전 slot free 금지
- done 시 slot, bank-valid, output valid, request queue가 모두 비어 있음

## 성공 기준

### 기능

- aligned DMA 관련 RTL unittest와 xrt-vcs-sim blackbox 통과
- 모든 width ratio와 backpressure 조합에서 data loss, duplication, reorder 없음
- partial final beat의 data와 byte enable 정확성 유지

### 자원

- `wr_slot_buf` wide storage 제거
- response slot payload FF 제거
- request elastic buffer의 wide payload storage 제거
- 8개 aligned DMA 합계 FF 최소 15k 감소를 1차 목표로 설정
- aligned DMA LUT가 증가하지 않고, 가능하면 10k 이상 감소
- BRAM 증가는 허용하되 AFU partition과 BRAM column congestion 확인

### 성능

- same-width와 wide-to-narrow는 pipeline 충전 후 destination 1 beat/cycle 유지
- narrow-to-wide는 source byte rate가 허용하는 최대 destination byte rate 유지
- destination stall 해제 후 불필요한 bubble 없음
- 대표 workload latency 회귀 1% 이내
- WNS 및 route congestion 악화 없음

## 위험과 대응

| 위험 | 대응 |
|---|---|
| SRAM read latency가 1 cycle이 아님 | `dp_sram` interface contract로 고정하고 assertion/test 추가 |
| `rd_en=0`에서 output이 유지되지 않음 | 명시적 SRAM 구현의 clock-enable 동작 보장 |
| narrow-to-wide tag width 부족 | group slot 수 축소 또는 tag width 확장 |
| bank response가 누락 또는 중복됨 | bank-valid mask와 duplicate-response assertion 추가 |
| destination stall 중 SRAM output 변경 | read enable 차단 및 `$stable` assertion 추가 |
| width ratio별 제어가 하나의 큰 mux로 합성됨 | elaboration-time generate로 ratio별 datapath 분리 |
| BRAM packing/placement가 나쁨 | channel 및 width bank별 hierarchy 유지, P&R 부모 합계 비교 |
| hierarchy resource가 다른 부모로 이동 | 각 channel뿐 아니라 `u_dma_engine` 합계도 비교 |

## 비범위 후속 작업

다음은 이 문서와 별도로 검토한다.

- `VX_dma_unit_misal`의 byte pack/shift 최적화
- `VX_lmem_dma_misal`의 response storage
- DMA channel 수 축소
- outstanding depth 변경
- multiplier 공유
- DMA arbiter의 `REQ_OUT_BUF/RSP_OUT_BUF` 축소
