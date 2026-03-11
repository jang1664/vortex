# u55c의 간혈적 error 및 hang debugging
1. U55C XRT 빌드는 `PLATFORM_MERGED_MEMORY_INTERFACE`를 사용하고 있다. 실제로 link 단계 설정에 `-DPLATFORM_MERGED_MEMORY_INTERFACE`와 `-DPLATFORM_MEMORY_NUM_BANKS=32`가 같이 들어가며, AFU top인 `VX_afu_wrap.sv`에서는 이 옵션이 켜지면 외부로 노출되는 `C_M_AXI_MEM_NUM_BANKS`를 `1`로 고정한다. 즉, logical memory bank 수는 32로 유지되지만, platform에 연결되는 physical AXI master port는 1개다.

   따라서 이번 U55C 구성에서는 XRT runtime이 `BANK_INTERLEAVE`를 켜느냐 끄느냐가 "외부 AXI port 개수"를 바꾸는 문제는 아니다. interleave on/off가 있어도 결국 하나의 merged AXI port를 통해 접근하므로, 현재 디버깅에서는 `runtime/xrt`의 interleave off mode 자체를 1차 원인으로 보지 않는다.


# cache flush 정리
1. Vortex에서 explicit cache flush 요청은 보통 코어가 `fence` 명령을 실행할 때 발생한다. `vx_fence()`는 커널 코드에서 `fence iorw, iorw`를 내보내고, LSU는 이 명령을 보면 `MEM_REQ_FLAG_FLUSH`를 세팅한다. 이 flag가 `VX_cache_init.sv`의 `flush_req_mask`로 들어간다.

2. `VX_cache_init.sv`는 flush 요청을 보면 일반 요청을 잠시 막고, 먼저 기존 in-flight request가 빠지기를 기다린 뒤 각 cache bank에 `flush_begin` 펄스를 보낸다. 모든 bank가 `flush_end`를 낼 때까지 기다린 다음, 마지막에 원래의 flush request만 아래 계층으로 통과시킨다.

3. 각 bank 내부에서는 `VX_cache_flush.sv`가 flush를 수행한다. 먼저 `mshr_empty`를 기다린 뒤 cache line/way를 순회하면서 flush를 진행하고, bank0이 마지막 completion을 내도록 조정한다. 즉 flush는 단순 신호 하나가 아니라, bank별 state machine으로 수행된다.

4. reset 시에도 cache 쪽 init/flush 경로가 한 번 돈다. `VX_cache_flush.sv`는 reset 후 `STATE_INIT`에서 시작해서 tag/data 초기화를 수행한다. 따라서 explicit `fence`가 없어도 launch 시 reset/init 경로는 존재한다.

5. 현재 `vecadd_multi_invoke` 커널은 `vx_fence()`를 호출하지 않는다. 따라서 이 테스트에서는 `MEM_REQ_FLAG_FLUSH` 기반의 explicit cache flush는 발생하지 않고, reset/init과 drain 경로만 의존한다.

# VX_cache.sv에서 이상한 점 수정
assign per_bank_core_req_fire = per_bank_core_req_valid & per_bank_core_req_ready;
위 코드처럼 수정함.

# 최신 합성 parameters
PREFIX=core1_f300_tcu_cache_fix \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
NUM_CORES=1 \
CONFIGS="-DEXT_TCU_ENABLE -DAFU_DONE_WAIT_CACHE_DRAIN" \
TARGET=hw \
CLOCK_FREQ_HZ=300 \
make 2>&1 | tee core1_f300_tcu_cache_fix.log


# 실험 결과
1. vecadd_multi_invoke로 실험 중이야.
2. iteration 마다 input을 다르게 하면 몇몇 iteration이 틀려. 근데 vecadd_multi_invoke를 돌릴 때 마다 틀리는 idx가 달라.
3. 근데 input을 고정하고 돌리면 iteration을 몇번 하든 다 PASS해. -> 다시 보니까 간혈적으로 여전히 틀려. 이전 test는 vortex의 HBM을 DEADBEAF로 init하지 않고 돌렸어. 즉 이전 iteration 값이 반영된듯하네.
4. 틀린 idx의 input을 dump해서 다음에 load해서 돌리면 또 PASS해
5. L1 cache disable 시키고 돌리면 HW에서 vecadd 성공함. 즉 cache 문제는 확실한 것 같음.
6. 틀리는 경우 항상 vortex dram에 init해둔 0xDEADBEAF 가 나오는 걸로 봐서 store가 제대로 안 된것 같음.
7. 근데 100M에서는 cache가 있어도 성공함. 300M에서 실패함. latch 문제인가?. 근데 200M에서는 실패함.
  - core1_f*_tcu_*_hw 참고

# 추가 분석 (store lane/byte-enable 관점)
1. `build/bb.log`의 실패 idx들을 모아보면 전부 `idx % 4 == 3` 이다.
   - 예: `9299, 3075, 10303, 3083, 3067, 9291, 4087, 11335`
   - 이전 로그(`blackbox_hw_run1.log`)의 실패 idx도 동일하게 `idx % 4 == 3`.

2. 현재 설정에서 `TYPE=int(32-bit)`이고 LSU word는 64-bit이므로, 실패 idx 패턴은 64-bit lane의 upper 32-bit store 쪽과 대응된다.
   - `idx % 8 == 3`  -> 32B coalesced word 내 byte offset 12
   - `idx % 8 == 7`  -> 32B coalesced word 내 byte offset 28
   - 즉, 단순 random drop보다 특정 lane/byte-enable 비트군이 취약한 패턴이다.

3. 따라서 1차 suspect는 아래 write byte-enable 경로다.
   - `VX_mem_coalescer` merge (`in_req_byteen` -> `out_req_byteen`)
   - `VX_cache_bank` write-through path (`byteen_st1` -> `line_byteen` -> `mreq_queue_byteen`)
   - `VX_axi_adapter`의 `m_axi_wstrb` 전달 경로

4. timing report 상으로는 dcache 내부 BRAM enable 경로(tag -> data `ENBWREN`)가 매우 타이트하다.
   - latch inference 경고는 없고, 구조적으로는 timing-margin 취약 케이스에 더 가깝다.
   - 위 lane-specific byte-enable 경로도 동일 clock domain에서 마진이 부족하면 간헐 오동작으로 나타날 수 있다.

5. 다음 검증 실험 제안
   - `TYPE=int64_t`로 바꿔 upper/lower 32-bit partial write를 제거했을 때 오류가 사라지는지 확인
   - `DBG_TRACE_CACHE`로 실패 iteration의 `writethrough byteen`이 실제로 비는지(해당 lane 비트가 0으로 찍히는지) 확인
   - 동일 bitstream에서 clock을 낮춰(예: 150MHz) 오류 재현율 변화를 측정해 timing 민감도 재확인

# RTL 가설 검증 (DMA race / cache init race / L2-L3 stale data)

아래 세 가지 가설을 runtime + RTL 분석으로 검증한 결과, **세 가지 모두 불가능**한 시나리오임을 확인함.

1. **DMA race condition — 불가능**
   - `vx_copy_to_dev`는 내부적으로 `xrtBuffer.sync(XCL_BO_SYNC_BO_TO_DEVICE)` 호출 → 완전 동기(blocking). DMA 완료 후에야 return.
   - `vx_start` 호출 시점에는 모든 DMA가 이미 완료. 0xDEADBEEF DMA와 kernel store 사이에 race 없음.

2. **Cache init race — 불가능**
   - `VX_cache_flush.sv`: reset 시 `state <= STATE_INIT`으로 진입. `flush_init = (state == STATE_INIT)` 동안 모든 cache line 순회.
   - `VX_cache_bank.sv`: `init_valid`가 1이면 모든 core request 차단 (`creq_grant = ~init_valid && ...`).
   - Init 완료 전에는 core가 cache에 request를 보낼 수 없음.

3. **L2/L3 stale data — 불가능 (NUM_CORES=1)**
   - `L2_ENABLE`, `L3_ENABLE`은 `NUM_CORES`와 독립적인 컴파일 flag.
   - `CONFIGS_1c = -DNUM_CLUSTERS=1 -DNUM_CORES=1` — L2/L3 enable flag 미포함 → passthrough 모드.
   - Writeback도 기본 0 (write-through).

# Timing Violation 확인 (clock uncertainty 적용 합성)

## 합성 설정
`pre_opt_hook.tcl`에서 kernel clock에 `set_clock_uncertainty -setup 0.3 -hold 0.01` 적용:
```tcl
set margin_ns 0.3
foreach clk [get_clocks -quiet *kernel*] {
    set_clock_uncertainty -setup $margin_ns $clk
}
```

## 결과 (core1_f300_tcu_cache_fix 빌드, 300MHz)
- Hook 적용 확인: `INFO: Added 0.3ns setup margin and 0.01ns hold margin to clock clk_kernel_00_unbuffered_net`
- **clk_kernel_00 (300MHz): WNS = -0.060ns, 11 failing endpoints**
- clk_kernel_01 (500MHz): WNS = +0.134ns (OK)

## Failing Endpoints 분석 — 전부 같은 경로
11개 violation **모두** dcache bank[0]의 동일 패턴:
```
Source:      dcache/bank[0]/cache_tags/tag_store[way]/BRAM (CLKARDCLK)
Destination: dcache/bank[0]/cache_data/data_store[way]/BRAM (ENBWREN)
```

| Slack (ns) | Tag Store Way | Data Store Way | Data BRAM instance |
|------------|---------------|----------------|-------------------|
| -0.060 | tag_store[0] | data_store[0] | ram_reg_0 |
| -0.019 | tag_store[1] | data_store[1] | ram_reg_0 |
| -0.014 | tag_store[0] | data_store[0] | ram_reg_4 |
| -0.013 | tag_store[3] | data_store[3] | ram_reg_5 |
| -0.010 | tag_store[3] | data_store[3] | ram_reg_3 |
| -0.009 | tag_store[3] | data_store[3] | ram_reg_6 |
| -0.008 | tag_store[1] | data_store[1] | ram_reg_7 |
| -0.008 | tag_store[3] | data_store[3] | ram_reg_7 |
| -0.008 | tag_store[3] | data_store[3] | ram_reg_2 |
| -0.005 | tag_store[3] | data_store[3] | ram_reg_4 |

RTL 경로:
```
Tag BRAM clk→Q → tag_matches 비교 → line_write → Data BRAM ENBWREN (setup)
```
`VX_cache_tags.sv`: `tag_matches[i] = (read_valid[i] && (line_tag == read_tag[i])) || rdw_fill`
`VX_cache_data.sv`: `line_write = (fill && way_en) || (write && tag_matches[i] && WRITE_ENABLE)`

## 해석
- 0.3ns uncertainty 없이는 WNS=+0.007ns로 "pass"하지만, 실제 silicon에서는 OCV/voltage droop/temperature 등으로 0.3ns 이상의 마진이 필요.
- 이 경로의 timing violation 시: data SRAM write enable이 잘못 캡처됨.
  - **직접 영향**: store hit 시 cache data 업데이트 실패 (write-through에서는 DRAM에는 영향 없음)
  - **간접 영향**: fill data write에도 같은 `line_write` 사용 → fill 실패 시 이후 load가 stale data 읽을 수 있음
- Store가 DRAM에 도달하지 않는 버그(`mreq_queue_push`)는 이 경로와 독립적이므로, 11개 외에 margin이 부족한 다른 숨겨진 path가 존재할 가능성 있음.
