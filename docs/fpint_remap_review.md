# FPINT GEMM FFN — Remap 변경 리뷰 및 실패 분석

**일시:** 2026-04-23
**브랜치:** `fpint_improve`
**대상 커밋:**
- `42111058` — Implement VX_mem_remap module
- `bffcbaff` — Add remap module between axi_adapter and demux
- `bf87fc22` — Pack bank_idx so each AXI port owns contiguous HBM banks
- `34e0d276` — connect m_axi0 for pc0-3, m_axi1 for pc4-7, and so on

**테스트:** `tests/regression/fpint_gemm_ffn_hw_improve` (driver: `xrt_vcs_sim`)

---

## 1. 요약

- 기존 interleave 기반 remap (port 0 = PC0,8,16,24) 을 새 contiguous-per-port remap (port 0 = PC0,1,2,3) 으로 전환하고 `platforms.mk` 의 HBM sp 매핑도 port 당 4개 PC 로 축소한 일련의 변경.
- **remap 자체는 설계 의도대로 정확히 구현됨** (RTL `VX_mem_remap.sv` ↔ runtime `vortex_v5.cpp::get_bank_info` 수식 일치).
- 하지만 **DMA ctrl 의 channel-slot 매핑 constraint** 가 깨질 수 있는 경로가 2군데 존재함이 확인됨:
  1. **Buffer base 정렬 문제** (m=k=n=32) — runtime allocator 정렬을 64B → 512B 로 올려 해결.
  2. **Kernel-computed stride 정렬 문제** (m=8 k=160 n=160) — scales/zp 의 per-kt stride 가 `N % 64 ≠ 0` 일 때 512B 배수가 아님. **미해결.**

---

## 2. 설계 의도와 Constraint

### 2.1 새 remap packing

```
block_idx    = addr / 64
q            = block_idx / 8
r            = block_idx % 8
bank_idx     = (r << 2) | (q & 3)       // = {r[2:0], q[1:0]}
bank_offset  = (q >> 2) * 64
hbm_address  = (bank_idx << 29) | bank_offset | byte_offset
```

- Port select (demux 또는 hardwire) = `bank_idx[4:2] = r`
- Port `c` 의 HBM window = `[c · 4 · 512MB, (c+1) · 4 · 512MB)` = 2GB
- `platforms.mk`: `m_axi_mem_c → HBM[4c:4c+3]`

### 2.2 Channel ↔ Port 매핑 불변식

`Vortex_axi.sv` 에서 DMA channel `ch` 의 AXI master 는 HBM port `ch` 에 **hardwire** 되어 있음. 따라서 channel `ch` 가 발행하는 모든 AXI 주소는 remap 후 `r == ch` 를 만족해야 port 범위 내에 머무름.

`VX_gemm_tmem_dma_ctrl.sv` 의 descriptor 생성:
```systemverilog
start_ch    = <TMEM-side base>[8:6]
logical_ch  = ch - start_ch
ch_hbm_base = <HBM-side base> + (logical_ch << 6)
```

여기서 `remap(ch_hbm_base).r == ch` 가 성립하려면:
```
((HBM_base_block + ch - start_ch) % 8) == ch
⇔ (HBM_base_block - TMEM_base_block) % 8 == 0
⇔ HBM_addr % 512 == TMEM_addr % 512
```

**즉 채널 한 번 dispatch 할 때 HBM-side base 와 TMEM-side base 가 동일한 mod-512 잔여를 가져야 함.**

이 constraint 는 단일 DMA command 의 2 endpoint 에 적용되며,
- **buffer base alignment** (runtime allocator 몫) 뿐 아니라
- **kernel 이 base 에 더하는 모든 offset** (stride 계산 몫) 에도 적용된다.

---

## 3. 검증 메커니즘 (이번 리뷰에서 추가)

### 3.1 C++ backend assertion (`sim/xrtsim_vcs/xrt_sim_vcs.cpp`)

`process_axi_events()` 가 받는 AR/AW 마다 `port_id` 와 addr 범위를 비교:

```cpp
void assert_port_range(uint8_t port_id, uint64_t addr) {
  constexpr uint32_t BANKS_PER_PORT = PLATFORM_MEMORY_NUM_BANKS / NUM_DMA_CHANNELS;
  const uint64_t port_base = (uint64_t)port_id * BANKS_PER_PORT * mem_bank_size_;
  const uint64_t port_top  = port_base + (uint64_t)BANKS_PER_PORT * mem_bank_size_;
  if (addr < port_base || addr >= port_top) { /* abort with diagnostic */ }
}
```

- Port `i` 의 허용 범위 = `[i · 2GB, (i+1) · 2GB)`
- EVT_AXI_AR 의 매 beat address, EVT_AXI_AW 의 base address 에 호출.

### 3.2 RTL assertion (`hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`)

DMA command 발행 시점(`gemm_dma_ctrl_if.start && (OP_DMA_LD || OP_DMA_ST)`)에 `rs1_data` / `rs2_data` 의 bits `[8:6]` 비교:

```systemverilog
assert (gemm_dma_ctrl_if.cmd.rs1_data[BUS_WORD_SHIFT +: NUM_CH_SHIFT]
     == gemm_dma_ctrl_if.cmd.rs2_data[BUS_WORD_SHIFT +: NUM_CH_SHIFT])
  else $fatal(1, "%m: DMA channel-slot misalignment: rs1_data=0x%0h rs2_data=0x%0h; ...");
```

- 조기 검출(커맨드 발행 순간) → 실제 AXI 상에서 잘못 가기 전에 터짐.
- C++ 쪽 assertion 과 상호 보완. `simv` 재빌드 필요 (`make -C sim/xrtsim_vcs clean && make`).

---

## 4. 실패 케이스 1 — `-m 32 -k 32 -n 32`

### 4.1 증상

```
[vcs-sim] FATAL: AXI addr 0xa0000840 on port 0 is outside its HBM window [0x0, 0x80000000)
```

### 4.2 역산

| field | 값 |
|---|---|
| `bank_idx` = `0xa0000840 >> 29` | **5** |
| `r = bank_idx[4:2]` | 1 → **port 1** |
| `q[1:0] = bank_idx[1:0]` | 1 |
| `bank_offset_value = 0xa40 >> 6` | 33 |
| `q = 33·4 + 1` | 133 |
| `block_idx = q·8 + r = 133·8 + 1` | **1065** |
| SW addr = `1065 × 64` | **`0x10a40`** |

### 4.3 버퍼 대조

로그의 `MEM_ADDRESS` (allocator min-alignment = 64B, 즉 cacheline):

| buffer | size | base | `block` | `% 8` |
|---|---|---|---|---|
| A | 2048 | `0x10000` | 1024 | 0 ✓ |
| W | 512 | `0x10800` | 1056 | 0 ✓ |
| scales | **64** | `0x10a00` | 1064 | 0 ✓ |
| **zeros** | 64 | `0x10a40` | **1065** | **1 ✗** |
| C | 2048 | `0x11000` | 1088 | 0 ✓ |

`scales` 가 단일 cacheline (64B) 이라 그 뒤 `zeros` 의 base 가 `block % 8 = 1` 로 어긋남.

### 4.4 DMA dispatch

zp LOAD (`src=0x10a40`, `dst=TMEM zpbuf=0x15000`):
- `start_ch = dst[8:6] = 0x15000[8:6] = 0` (TMEM 4KB aligned)
- Channel 0: `ch_src_base = 0x10a40 + 0 = 0x10a40`
- `axi_m[0]` → HBM port 0 (`m_axi_mem_0` = HBM[0:3], `[0, 2GB)`)
- `remap(0x10a40) = 0xa0000840` = **2.5GB, port 1 영역** → out of window → FATAL

### 4.5 Constraint 위반

```
HBM_addr % 512 = 0x10a40 % 512 = 0x40  (= 64)
TMEM_addr % 512 = 0x15000 % 512 = 0
0x40 ≠ 0 → 위반
```

### 4.6 Fix

**Runtime allocator min-alignment 를 64B → 512B 로 상향** (gaeun이 이미 적용).
- 이후 모든 `vx_mem_alloc` 의 base 가 `% 512 == 0` → TMEM (항상 `% 512 == 0`) 와 자동 매칭.
- 다음 실행 log 에서 `MEM_ALLOC_ALIGNED ... alignment=0x200` 확인됨.

---

## 5. 실패 케이스 2 — `-m 8 -k 160 -n 160`

runtime fix 후에도 이 케이스는 여전히 실패. Base 는 모두 512B aligned 이지만 **kernel 이 base 에 더하는 stride 에서 alignment 가 깨짐.**

### 5.1 증상

```
[vcs-sim] FATAL: AXI addr 0x200000a40 on port 0 is outside its HBM window [0x0, 0x80000000)
```

### 5.2 역산

| field | 값 |
|---|---|
| `bank_idx` = `0x200000a40 >> 29` | **16** |
| `r = bank_idx[4:2]` | 4 → **port 4** |
| `q[1:0]` | 0 |
| `bank_offset_value` = `0xa40 >> 6` | 41 |
| `q = 41·4 + 0` | 164 |
| `block_idx = q·8 + r = 164·8 + 4` | **1316** |
| SW addr = `1316 × 64` | **`0x14900`** |

### 5.3 버퍼 대조

로그의 `MEM_ADDRESS` (allocator alignment = 512B):

| buffer | size | base | `% 512` |
|---|---|---|---|
| A | 2560 | `0x10000` | 0 ✓ |
| W | 12800 | `0x11000` | 0 ✓ |
| **scales** | 1600 | **`0x14400`** | 0 ✓ |
| zeros | 1600 | `0x15000` | 0 ✓ |
| C | 2560 | `0x16000` | 0 ✓ |

모든 base 가 512B 정렬. 즉 m=32 케이스의 bug 는 재발하지 않았음.

그런데 `0x14900 - 0x14400 = 0x500 = 1280` 만큼 scales base 에서 들어간 지점이 접근됨.
`0x14900 % 512 = 0x100 ≠ 0` → **stride 때문에 alignment 가 깨짐.**

### 5.4 Kernel stride 추적

`kernel.cpp:191`:
```cpp
const uint64_t kt_sc_stride = uint64_t(DMA_KT / qblk) * uint64_t(N) * 2u;
//  = (128 / 32) * 160 * 2
//  = 4 * 160 * 2 = 1280
```

`kernel.cpp:270` (scales load address):
```cpp
const uint64_t d_sc = arg->dram_sc_base
                    + uint64_t(_kt) * kt_sc_stride
                    + nt_dma_sc_off;
```

`(mt=0, nt_dma=0, kt=1)` 반복:
```
d_sc = 0x14400 + 1 · 1280 + 0 = 0x14900   ← %512 = 0x100 ✗
```

### 5.5 DMA dispatch

scales LOAD (`src = 0x14900`, `dst = scbuf[b] = 0x14000 or 0x14800`, 둘 다 `% 512 = 0`):
- `start_ch = dst[8:6] = 0`
- Channel 0: `ch_src_base = 0x14900 + 0 = 0x14900`
- `axi_m[0]` → HBM port 0 (`[0, 2GB)`)
- `remap(0x14900) = 0x200000a40` = **2.5GB, port 4 영역** → out of window → FATAL

zp 도 `kt_zp_stride = kt_sc_stride = 1280` 이라 동일 bug 발생(단, scales 가 먼저 dispatch 되어 먼저 터짐).

### 5.6 일반화 — 어떤 N 이 문제인가

scales/zp 의 per-kt stride 공식:
```
kt_sc_stride = (DMA_KT / QBLK) · N · 2 = 8·N   (QBLK=32, DMA_KT=128)
```

`8·N % 512 == 0` 필요 → **`N % 64 == 0`**.

| N | `8·N` | `% 512` | 통과? |
|---|---|---|---|
| 128 | 1024 | 0 | ✓ |
| **160** | 1280 | 256 | ✗ |
| 192 | 1536 | 0 | ✓ |
| **224** | 1792 | 256 | ✗ |
| 256 | 2048 | 0 | ✓ |

N=128/192/256 은 우연히 통과하는 것이고, N=160/224 는 항상 실패.

### 5.7 다른 버퍼의 stride 비교

| 버퍼 | stride 공식 | 예 (m=8,k=160,n=160) | `% 512` |
|---|---|---|---|
| A (input) | `cm · DMA_KT · 2` | `8·128·2 = 2048` | 0 ✓ |
| W (weight) | `DMA_KT · N / 2` | `128·160/2 = 10240` | 0 ✓ |
| **scales** | `(DMA_KT/QBLK) · N · 2` | `8·160 = 1280` | **256 ✗** |
| **zp** | 동일 | `1280` | **256 ✗** |
| C (output, per-nb) | `cm · MXU_NT · 2 = k·512` | `k·512` | 0 ✓ |

**위반되는 건 scales/zp 의 per-kt stride 하나.**

### 5.8 왜 RTL assertion 이 안 터졌나

로그의 `[vcs-sim] FATAL` 은 C++ backend (`xrt_sim_vcs.cpp`) assertion. RTL `$fatal` 메시지가 없음 → **`simv` 가 새 RTL 로 다시 빌드되지 않음**. `make -C sim/xrtsim_vcs clean && make` 후 돌리면 `VX_gemm_tmem_dma_ctrl` 의 assertion 이 `rs1_data=0x14900, rs2_data=0x14xxx` 를 찍으며 C++ 보다 먼저 터져야 정상.

---

## 6. 결론

두 실패 모두 동일한 근본 원인 (channel-slot alignment 위반) 이지만 발생 경로가 다름:

| | 케이스 1 (m=32) | 케이스 2 (m=8 n=160 k=160) |
|---|---|---|
| 위반 위치 | 버퍼 **base** | 커널의 **per-kt stride** (scales/zp) |
| 트리거 | `scales` 가 단일 cacheline 이라 다음 버퍼 base 정렬이 깨짐 | `N % 64 ≠ 0` 이라 `kt_sc_stride = 8N` 이 `% 512 ≠ 0` |
| Fix 적용 | **Runtime allocator 512B alignment** (적용됨) | **미해결** |
| 일반성 | 작은 (≤1 cacheline) 버퍼가 여러 개 연속될 때마다 재현 | `N ∈ {96, 160, 224, 288, ...}` 전부 실패 |

Constraint 는 동일:
```
HBM_addr % 512 == TMEM_addr % 512    (단, base 뿐 아니라 base+offset 모두)
```

---

## 7. Fix 제안 (케이스 2)

### 옵션 A — 테스트 제약으로 선언 (가장 작음)

`test.sh.in` 및 `main.cpp::parse_args` 에 `N % 64 == 0` 체크 추가. 기본 sweep 에서 N=160 같은 케이스 제외.

- **장점:** 즉시, 코드 변경 최소.
- **단점:** Sweep coverage 축소. 실제로 제품 쪽에서 N=160 을 쓰고 싶어지면 또 깨짐.

### 옵션 B — Host-side scales/zp padding (권장)

`main.cpp::convert_scale_tiled` / `convert_zp_tiled` 에서 per-kt block 을 `align_up(per_kt_bytes, 512)` 로 올려 host 버퍼에 pad 를 넣고, `kernel.cpp::dma_preload_tile` 의 `kt_sc_stride` / `kt_zp_stride` 도 동일한 padded 값을 사용하도록 상수 변경.

- **장점:** RTL 안 건드림. Sweep coverage 유지.
- **단점:** Host 와 kernel 양쪽 layout 코드 동시 수정 필요. Padding 된 크기만큼 DRAM 낭비 (미미).

### 옵션 C — RTL 에서 start_ch 를 HBM-side 로 (구조적)

`VX_gemm_tmem_dma_ctrl.sv:201-202` 의 `start_ch` 를 HBM-side base 기준으로 뽑고, channel 별 TMEM base 도 대칭적으로 조정. TMEM 쪽 `logical_ch` 회전을 추가.

- **장점:** 어떤 N 이든 동작. TMEM 과 HBM 의 정렬이 달라도 OK.
- **단점:** `ch_src_base` / `ch_dst_base` / sub-burst size (`bank_off_beats`) 계산이 모두 영향 받음. 회귀 위험 있음. 추가 assertion 필요.

---

## 8. 권장 조치

1. **케이스 2 (옵션 B)** 로 host/kernel layout 을 수정하여 N 제약을 없앰.
2. 추가한 RTL assertion (`VX_gemm_tmem_dma_ctrl.sv`) 과 C++ assertion (`xrt_sim_vcs.cpp`) 은 유지 → 이후 회귀 즉시 검출.
3. Test sweep 에 `N % 64 ≠ 0` 케이스(예: N=160, 224) 를 명시적으로 넣어 옵션 B fix 의 유효성을 보장.

---

## 부록 A — 디버그에 유용한 역산 공식

임의의 remapped AXI addr `A` 로부터 SW block 복원:
```
bank_idx = A >> 29
r        = bank_idx >> 2           // = 예상 port
q_lo2    = bank_idx & 3
bank_off = (A >> 6) & 0x7FFFFF     // A[28:6]
q        = bank_off · 4 + q_lo2
block    = q · 8 + r
sw_addr  = block · 64 + (A & 0x3F)
```

로그에서 `FATAL: AXI addr 0x... on port X` 가 보이면 `r ≠ X` 가 확인되고, 위 공식으로 원래 SW addr 을 바로 찾을 수 있음.

## 부록 B — 이번에 추가/수정한 파일

| 파일 | 변경 |
|---|---|
| `sim/xrtsim_vcs/xrt_sim_vcs.cpp` | `assert_port_range` helper 및 EVT_AXI_AR/AW 호출점 추가 |
| `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv` | `rs1_data[8:6] == rs2_data[8:6]` assertion 추가 (sim-only) |
