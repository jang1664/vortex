# L1 I/D Cache Intermittent Hang/Error Analysis

## 실제 빌드 config (확인됨)

빌드 경로: `build/hw/syn/xilinx/xrt/core2_f100_tcu_v19_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/`

```
PLATFORM_MEMORY_DATA_SIZE = 64   (= 512 bits AXI data width)
MEM_ADDR_WIDTH = 34
PLATFORM_MEMORY_NUM_BANKS = 32
PLATFORM_MEMORY_ADDR_WIDTH = 34
PLATFORM_MERGED_MEMORY_INTERFACE (단일 AXI 포트로 merge)
NUM_CORES = 2, NUM_CLUSTERS = 1
XLEN_64, EXT_TCU_ENABLE
AFU_DONE_WAIT_CACHE_DRAIN
CLOCK_FREQ_HZ = 100
```

**VX_MEM_DATA_WIDTH** = `L3_LINE_SIZE * 8` = `MEM_BLOCK_SIZE * 8` = `64 * 8` = **512 bits**
→ `PLATFORM_MEMORY_DATA_SIZE * 8` = **512 bits**
→ **mem_data_adapter는 PASSTHRU** (splitting 없음)

## 증상 요약

| 항목 | 내용 |
|------|------|
| 테스트 | `vecadd_multi_invoke`, `--threads=4 --cores=2`, `-n 65536 -r 1024` |
| 플랫폼 | `xilinx_u55c_gen3x16_xdma_3_202210_1` |
| 증상 | 간혈적 error 및 hang |
| RTL sim | PASS |
| Post-impl sim | PASS |
| Timing | All positive slack |
| L1 I,D off | 문제 해결 |
| L2 on | 정상 |
| Multi-core | 문제 빈도 증가 |
| Single core | 비교적 잘 동작, 간혹 hang |

**핵심 질문**: Simulation에서 재현되지 않는 FPGA-only 간혈적 버그의 원인은 무엇인가?

---

## 1. ASYNC_BRAM_PATCH (결론: 원인 아님)

### 분석

`VX_async_ram_patch.sv`의 `VX_placeholder`(black_box) 셀은 RTL에서는 undriven이지만,
`xilinx_async_bram_patch.tcl` 스크립트가 post-init 단계에서 netlist 변환을 수행:

```tcl
# resolve_async_bram 핵심 동작:
# 1. raddr_w의 driver가 register(FDRE/FDSE)인지 확인
# 2. register의 D pin driver(next value)를 raddr_s에 연결
# 3. register의 CE pin driver를 read_s에 연결
# 4. placeholder 셀 제거
```

**결론**: TCL 스크립트가 `read_s`를 upstream register의 CE에 정확히 연결함.
BRAM read enable이 상수 0이 아닌, 실제 clock enable 신호가 됨. **정상 동작**.

User 확인: "async bram patch를 하든 안 하든 틀려" → BRAM patch 자체는 원인 아님.

### Simulation과의 관계
- Sim: `ifdef SIMULATION` 분기 → `assign rdata = ram[raddr]` (async read)
- HW: ASYNC_BRAM_PATCH → TCL이 netlist 변환 → BRAM registered read
- 두 경로 모두 기능적으로 동일한 결과를 제공해야 함 (TCL이 정상 동작하므로)

---

## 2. BRAM RDW (Read-During-Write) Inference 불일치 (조사 필요)

### 의심 포인트

Tag store (`VX_cache_tags.sv`)와 data store (`VX_cache_data.sv`)는
`VX_dp_ram` / `VX_sp_ram`을 `OUT_REG=1`, `RDW_MODE="R"` (read-first)로 사용.

```verilog
// VX_dp_ram.sv - synthesis, sync, read-first:
always @(posedge clk) begin
    ram[waddr] <= wdata;      // write
    if (read) begin
        rdata_r <= ram[raddr]; // read (read-first: old value)
    end
end
```

RTL 설계는 read-first를 가정하고, `rdw_fill` bypass로 fill 직후 1 cycle의 hazard를 처리:
```verilog
// VX_cache_tags.sv
`BUFFER(rdw_fill, do_fill);
assign tag_matches[i] = (read_valid[i] && (line_tag == read_tag[i])) || rdw_fill;
```

### 위험: Vivado가 다른 모드로 추론할 경우

| BRAM Mode | read during same-addr write 시 read 결과 | rdw_fill bypass 효과 |
|-----------|------------------------------------------|---------------------|
| READ_FIRST | 이전 값 (old) | bypass가 강제 hit → 정확 |
| WRITE_FIRST | 새 값 (new) | bypass가 강제 hit → 정확 (우연히) |
| NO_CHANGE | 변화 없음 (hold) | bypass가 강제 hit → 정확 (우연히) |

**fill 직후 cycle에는** `rdw_fill`이 강제 hit을 만들어 어떤 모드든 동작.

**문제가 되는 경우**: tag store의 dual-port RAM에서 waddr != raddr이지만 같은 BRAM primitive 내의
다른 port에서 동시 read/write 발생 시. Xilinx BRAM은 dual-port 동시 접근에서
같은 주소가 아닐 때는 mode와 무관하게 정확해야 하므로, 이론적으로는 안전.

### 진짜 위험: dp_ram의 dual-port 동시 same-address 접근

Tag store는 `VX_dp_ram` (dual-port):
- Port A (write): `waddr = line_idx` (current stage 0)
- Port B (read): `raddr = line_idx_n` (next cycle's input selection)

**Fill 시**: write port에 fill tag 기록 + read port에 다음 request의 line_idx 읽기.
대부분 다른 주소이므로 정상. **같은 주소면** `rdw_fill` bypass가 커버.

**Flush 시**: write port에 invalid 기록 + read port에 다음 request의 line_idx 읽기.
`rdw_fill`은 fill만 커버. **flush 직후 같은 line에 접근하면?**
→ Pipeline priority에 의해 flush 중에는 core request가 block되므로 실질적으로 발생 어려움.

### 검증 방법

```bash
# Vivado 합성 로그에서 BRAM inference 확인:
grep -i "bram\|block.*ram\|collision\|rdw\|read.*first\|write.*first\|no.change" vivado_synth.log
# dp_ram 관련 inference 정보:
grep -i "Inferred\|ram_style\|BRAM\|distributed" vivado_synth.log | grep -i "tag_store\|data_store\|mshr_store"
```

### Simulation과의 관계
- Sim: SystemVerilog 배열 기반 동작, `<=` (non-blocking) 시맨틱에 의해 read-first가 자연스럽게 구현
- HW: BRAM primitive의 실제 collision mode에 의존
- **Vivado가 read-first로 정확히 추론하면 문제 없음**
- 다만 이 이슈는 "간혈적"보다는 "특정 주소 패턴에서 항상 재현"에 더 가까울 것

---

## 3. Memory Response Ordering (깊이 분석)

### 전체 경로

```
L1 Cache Bank (mem_req_queue)
  → VX_cache (mem_req_arb: banks → mem_ports)
    → VX_cache_cluster (mem_arb: cache_units → output)
      → VX_socket (mem_arb: icache[0] + dcache[0..N])
        → Vortex.sv (L2/L3 cache or direct)
          → Vortex_axi.sv
            → VX_mem_data_adapter (width adaptation)
              → VX_axi_adapter (crossbar + tag buffer → AXI)
                → Platform AXI fabric → HBM/DDR
```

### 3-1. VX_mem_data_adapter: in-order 가정

**SRC > DST 경우 (splitting mode):**

```verilog
// 1개 wide request → P개 narrow request로 분할
// 모든 chunk는 같은 tag
assign mem_req_tag_out_w = DST_TAG_WIDTH'(mem_req_tag_in);

// Response: rsp_ctr로 순서대로 수집
mem_rsp_data_out_n[rsp_ctr] = mem_rsp_data_out;

// Simulation-only assertion:
`RUNTIME_ASSERT(!mem_rsp_in_fire || (mem_rsp_tag_in_x == mem_rsp_tag_out), ...)
```

**위험**: 분할된 P개의 chunk가 VX_axi_adapter의 tag buffer에서 각각 다른 index를 받으면,
AXI fabric이 다른 ID의 응답을 out-of-order로 반환할 수 있음.
`rsp_ctr`는 도착 순서로만 세므로, chunk가 뒤바뀌면 cache line 데이터가 swap됨.

**현재 default 설정 확인:**
```
VX_MEM_DATA_WIDTH = L3_LINE_SIZE * 8 = 64 * 8 = 512 bits
PLATFORM_MEMORY_DATA_SIZE = 64 bytes → AXI_DATA_WIDTH = 512 bits
SUB_LDATAW = CLOG2(512) - CLOG2(512) = 0
→ PASSTHRU mode (분할 없음)
```

**결론**: 실제 빌드에서 확인됨: `PLATFORM_MEMORY_DATA_SIZE=64`, `VX_MEM_DATA_WIDTH=512`.
**양쪽 모두 512 bits → PASSTHRU mode 확인. 이 adapter에서의 ordering issue는 없음.**

### 3-1b. VX_mem_data_adapter2 (OOO-safe 버전 존재하나 미사용)

빌드 소스에 `VX_mem_data_adapter2.sv`가 포함되어 있음. 이 버전은 `OOO_SLOTS` 파라미터로
out-of-order 응답을 올바르게 처리:

```verilog
// slot-based fragment tracking:
slot_rsp_frag_n[rsp_slot_id][rsp_frag_idx] = mem_rsp_data_out;  // tag에서 위치 추출
slot_rsp_seen_n[rsp_slot_id][rsp_frag_idx] = 1'b1;              // bitmask로 수집
if (&slot_rsp_seen_n[rsp_slot_id]) begin                        // 전부 모이면 출력
    rsp_out_valid_n = 1'b1;
    rsp_out_data_n = slot_rsp_frag_n[rsp_slot_id];
end
```

**하지만 실제 빌드에서 인스턴스화되지 않음** (grep 결과 없음).
만약 향후 data width가 달라지는 설정에서는 `VX_mem_data_adapter` 대신
`VX_mem_data_adapter2`를 사용해야 ordering 안전.

### 3-2. VX_axi_adapter: tag-based routing

```verilog
// Tag buffer: 내부 tag → AXI ID 압축
VX_index_buffer #(...) tag_buf (
    .acquire_data  (req_tag),      // 원본 tag 저장
    .acquire_slot  (tag_buf_idx),  // 할당된 index
    .read_data     (rsp_tag_orig), // 응답 시 원본 tag 복원
);
```

- AXI response의 RID에서 index 추출 → index_buffer에서 원본 tag 복원
- **Out-of-order AXI response를 올바르게 처리** (tag-based, not order-based)
- 단, `NEEDED_TAG_WIDTH <= TAG_WIDTH_OUT`이면 tag buffer를 사용하지 않고 직접 전달

### 3-3. Vortex 내부 response routing

각 레벨에서 response가 올바른 requestor로 돌아가는 메커니즘:

1. **L1 Cache Bank**: `mem_rsp_tag[MSHR_ADDR_WIDTH-1:0]`에서 `fill_id` 추출
   - Fill이 올바른 MSHR entry로 전달됨
   - **Tag width가 충분하면 정확**

2. **Cache Cluster**: mem_arb의 tag에서 cache unit selection bit 추출
   - **VX_mem_arb가 tag를 정확히 round-trip하면 정확**

3. **Socket**: icache/dcache 구분 bit
   - Priority arbiter ("P")가 tag에 selection bit 추가
   - **Response routing은 tag-based이므로 ordering 무관**

### 핵심 의문: Tag Width 계산이 맞는가?

```verilog
// VX_cache.sv
localparam MEM_TAG_WIDTH = `CACHE_MEM_TAG_WIDTH(MSHR_SIZE, NUM_BANKS, MEM_PORTS, UUID_WIDTH);
```

이 매크로가 올바르게 계산되면 tag truncation 없음.
**Multi-core에서 추가되는 `ARB_SEL_BITS`가 누적되면서 bit 부족 가능?**

```
L1 tag = UUID_WIDTH + MSHR_ADDR_WIDTH + BANK_SEL_BITS + ...
Cluster arb tag = L1 tag + ARB_SEL_BITS(NUM_INPUTS, NUM_CACHES)
Socket arb tag = Cluster tag + ARB_SEL_BITS(2, 1)  // icache+dcache
L2/L3 further adds bits...
```

검증 방법: synthesis log에서 tag width truncation warning 확인.

### Simulation과의 관계

- **Sim**: AXI 모델이 요청 순서대로 응답하거나, tag routing이 simulation에서 정확함
- **HW**: 실제 AXI fabric (XDMA shell)이 out-of-order 응답 가능, latency 가변
- **핵심 차이**: Simulation에서의 memory model은 deterministic하고 간단함.
  FPGA에서는 HBM controller, AXI interconnect 등이 non-deterministic latency와
  reordering을 발생시킬 수 있음.
- **만약 mem_data_adapter가 split mode라면**: sim에서는 in-order 모델이므로 통과,
  HW에서는 reordering으로 data corruption → **전형적인 sim-pass/hw-fail 패턴**

---

## 4. MSHR Stale Next-Pointer (결론: 원인 아님)

`VX_cache_mshr.sv:170-175`:
```verilog
// warning: This code allows 'finalize_is_pending' to be asserted
// regardless of hit/miss ...
if (finalize_is_pending) begin
    next_table_x[finalize_previd] = 1;
end
```

Bank pipeline priority 메커니즘 (replay > fill > flush > core_req)이
이 race condition을 실질적으로 방지.
**순수 RTL 로직이므로 sim과 hw가 동일** → FPGA-only bug의 원인이 될 수 없음.

---

## 5. L1 Disable 시 동작하는 이유

L1 disable 시 (`ICACHE_DISABLE` / `DCACHE_DISABLE`):
- `VX_cache_cluster`의 `NUM_UNITS=0` → `PASSTHRU=1`
- `VX_cache_wrap`이 `VX_cache_bypass`로 대체
- **BRAM 전혀 사용하지 않음** (tag/data/MSHR store 모두 bypass)
- Memory request가 직접 downstream으로 전달 (cache pipeline 없음)

이것이 시사하는 점:
1. BRAM 자체의 문제 가능성 (항목 2)
2. Cache pipeline 로직 내 sim/hw 불일치 가능성
3. Cache 관련 tag 계산/routing 문제 가능성

---

## 6. Multi-core에서 악화되는 이유

1. **Cache miss rate 증가** → fill/replay 빈도 증가 → BRAM RDW hazard 노출 기회 증가
2. **Memory traffic 증가** → AXI response latency 변동 → reordering 가능성 증가
3. **Arbitration tag bit 추가** → tag width margin 감소, truncation 위험
4. **Cache contention** → pipeline stall 패턴 변화 → 평소 발생하지 않는 타이밍 조합 노출

---

## 현재 상태 및 다음 단계

### 확인 완료

- [x] `PLATFORM_MEMORY_DATA_SIZE=64` = `L3_LINE_SIZE=64` → **mem_data_adapter PASSTHRU** (ordering issue 없음)
- [x] ASYNC_BRAM_PATCH TCL이 정상 동작 (CE/D를 올바르게 연결)
- [x] "하든 안 하든 틀려" → BRAM patch는 root cause 아님
- [x] MSHR stale link → 순수 RTL 로직, sim/hw 동일 → 탈락
- [x] `VX_mem_data_adapter2` (OOO-safe) 존재하나 미사용

### 로그 분석 완료 결과

**1. Vivado 합성 로그 (ulp_vortex_afu_1_0_synth_1/runme.log):**
- BRAM collision mode에 대한 명시적 메시지 없음 (Vivado 2023.2는 collision mode를 별도 리포트하지 않음)
- `tying undriven pin dummy_inferred:in0 to constant 0` — VX_placeholder 관련, 정상 (TCL이 나중에 resolve)
- `VX_index_buffer` 내 unused sequential elements 제거 — 정상

**2. BRAM patch 실행 로그 (vpl/vivado.log):**
- 모든 VX_async_ram_patch 인스턴스 성공적으로 resolve
- WARNING 없음 ("not registered" 경고 없음)
- Patch된 인스턴스: dcache MSHR, dcache replacement, dcache mem_req_queue, mem_rsp_queue,
  FPU tag store, LSU mem_scheduler, TCU queues, ibuffer FIFOs, ipdom_stack 등

**3. 내부 data width:**
- ICACHE_LINE_SIZE = 64, DCACHE_LINE_SIZE = 64
- L2_MEM_DATA_WIDTH = 512, L3_MEM_DATA_WIDTH = 512
- VX_MEM_DATA_WIDTH = 512, PLATFORM_MEMORY_DATA_SIZE = 64 (= 512 bits)
- **모든 경로에서 동일한 width → 어디에서도 splitting 없음**

**4. Tag width truncation:**
- 합성 로그에 truncation/width mismatch 관련 WARNING 없음

**5. Implementation timing (핵심 발견!):**
```
Estimated Routing:  WNS=-0.010 | TNS=-0.057 | WHS=0.009 | THS=0.000
Final:              WNS=2.93809e-12 ns (사실상 0)
```
- **WNS가 사실상 0** — timing closure 경계에 있음
- Critical methodology violations: **TIMING-1, TIMING-7, TIMING-14, TIMING-17, TIMING-54**

**6. Platform AXI downsizer 존재:**
```
level0_i/blp/blp_i/PLP/plp_axi/axi_ic_data_p2p/m01_couplers/auto_ds/
    inst/gen_downsizer.gen_simple_downsizer.axi_downsizer_inst
```
Platform interconnect에 AXI downsizer가 있음. Vortex 밖에서 width 변환이 발생.
(Xilinx AXI downsizer IP이므로 ordering은 보장되어야 하지만, 확인 필요)

---

## 새로운 유력 원인: Timing Marginal Design

### WNS ≈ 0의 의미

Final WNS = 2.93809e-12 ns는 사실상 timing을 겨우 meet한 상태. 이 경우:

1. **PVT 변동**: 온도/전압/공정 변동으로 실제 동작 시 timing violation 발생 가능
2. **Clock jitter**: 실제 클럭의 jitter가 margin을 초과할 수 있음
3. **SI effects**: Signal Integrity (crosstalk 등)로 인한 delay 변동

### L1 Cache와의 관계

L1 cache가 활성화되면:
- Tag store BRAM, Data store BRAM, MSHR store BRAM 추가
- Cache bank pipeline (3-stage) 추가
- Crossbar (core_req_xbar, core_rsp_xbar, mem_rsp_xbar) 추가
- 이 모든 로직이 **critical path를 형성할 가능성**

L1 cache 비활성화 시:
- PASSTHRU 모드 → BRAM 및 복잡한 pipeline 제거
- Critical path가 단순해짐 → timing margin 증가 → 안정적 동작

### Multi-core 악화 이유

- 2 cores → 더 많은 로직 → routing congestion 증가
- L1 cache cluster의 arbitration 로직 추가 → timing pressure
- 같은 FPGA에서 더 많은 자원 사용 → placement/routing 품질 저하

### Simulation에서 동작하는 이유

**Simulation은 timing을 모델링하지 않음.**
Post-impl sim에서도 SDF timing을 사용하지 않으면 functional simulation이므로 timing 문제 미노출.
실제 SDF back-annotated simulation을 해야 이 문제가 드러남.

### Critical Methodology Violations 확인 필요

```
TIMING-1:  Input delay not specified
TIMING-7:  No common clock/node
TIMING-14: LUT input to output delay
TIMING-17: Non-clocked sequential cell
TIMING-54: Clock pessimism removal
```

이 violation들이 cache 관련 경로에 있는지 확인 필요.

---

## 최종 유력 원인 순위 (수정)

| 순위 | 원인 | 근거 | 다음 액션 |
|------|------|------|-----------|
| **1** | **Timing marginal (WNS≈0)** | WNS=2.9e-12, critical methodology violations, L1 off=OK | methodology report 확인, timing paths 분석, clock freq 낮추기 실험 |
| 2 | BRAM RDW inference | BRAM collision mode 명시적 확인 불가 | BRAM 관련 timing path가 critical인지 확인 |
| 3 | Platform AXI downsizer | HBM 경로에 downsizer 존재 | downsizer의 ordering guarantee 확인 |

---

## 즉시 시도 가능한 실험 (수정)

1. **Clock frequency 낮추기 (최우선)**: 100MHz → 80MHz로 낮춰서 timing margin 확보.
   문제가 사라지면 timing 원인 확정.

2. **Methodology report 확인**: `report_methodology` 결과에서
   cache 관련 경로의 timing violation 확인

3. **`set_clock_uncertainty -setup 1.0ns`** 적용 후 re-impl:
   추가 setup margin으로 Vivado가 더 공격적으로 최적화하도록 유도

4. **Post-impl SDF timing simulation**: SDF back-annotated simulation으로
   timing violation이 cache 경로에서 발생하는지 확인

### ILA/ChipScope 포인트

| 신호 | 위치 | 확인 목적 |
|------|------|----------|
| `mem_rsp_valid/tag` | Vortex_axi 입력 | 응답 tag가 요청과 매칭되는지 |
| `mshr_alm_full` | VX_cache_bank | MSHR full로 고착 여부 (hang 징후) |
| `mreq_queue_empty` | VX_cache_bank | Memory request queue 상태 |
| `core_req_valid & ~core_req_ready` | VX_cache bank | Core request stall 지속 여부 |
| `replay_valid & ~replay_ready` | VX_cache_bank | Replay stall 여부 |
| `mem_rsp_valid & ~mem_rsp_ready` | VX_cache_bank | Fill response 수용 불가 여부 |

### 실험

1. **`DCACHE_NUM_BANKS=1`**: Bank 간 arbitration 제거
2. **`ICACHE_MSHR_SIZE=2, DCACHE_MSHR_SIZE=2`**: 동시 miss 제한
3. **`DISABLE_ASYNC_BRAM_PATCH` 확인**: 이미 "하든 안 하든 틀린다" 확인됨 (참고용)
4. **L1 line size를 platform data size에 맞추기**: mem_data_adapter passthru 강제
