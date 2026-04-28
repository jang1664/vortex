# AMD GCN Scalar Unit — "Free" Co-Issue 구조 해설

## 1. 한 줄 요약

GCN Compute Unit (CU)에는 SIMD vector ALU 옆에 **별도의 Scalar ALU + 별도의 Scalar Register File**이 물리적으로 따로 존재한다. Scheduler는 매 사이클 *서로 다른 port로* 1개의 scalar 명령과 1개의 vector 명령을 **동시에** 발사할 수 있어서, scalar 명령은 vector throughput에서 보면 "free"로 처리된다.

---

## 2. CU 구조도

```
          CU (Compute Unit)
 ┌─────────────────────────────────────────────────┐
 │  Wavefront Scheduler (한 사이클 multi-port issue)│
 ├─────────────────────────────────────────────────┤
 │  ┌─────────┐  ┌─────────┐  ┌─────────┐         │
 │  │ SIMD0   │  │ SIMD1   │  │ SIMD2/3 │ ← Vector ALU (16-lane × 4)
 │  │ VGPR    │  │ VGPR    │  │  ...    │   per-lane register
 │  └─────────┘  └─────────┘  └─────────┘         │
 │                                                  │
 │  ┌─────────────────┐   ┌────────────────────┐  │
 │  │ Scalar ALU      │   │ Vector Memory Unit │  │
 │  │ (1-wide, 64-bit)│   │ (LD/ST → L1/L2)    │  │
 │  │ + SGPR file     │   └────────────────────┘  │
 │  │ + Scalar L1 RD  │   ┌────────────────────┐  │
 │  └─────────────────┘   │ LDS (shared mem)   │  │
 │  ┌─────────────────┐   └────────────────────┘  │
 │  │ Branch & Msg    │                            │
 │  └─────────────────┘                            │
 └─────────────────────────────────────────────────┘
```

핵심 포인트:

- **Scalar ALU + SGPR**가 SIMD와는 독립된 별도 하드웨어 블록.
- 각 실행 유닛(SALU / VALU / VMEM / LDS / Branch)이 **자기 issue port**를 보유.
- 한 사이클 내에 **여러 port가 각자 명령을 동시에 받아간다.**

---

## 3. 두 종류의 Register

| | **SGPR (scalar)** | **VGPR (vector)** |
|---|---|---|
| 단위 | wavefront 전체에 1개 | 64 lane 각각에 1개 |
| 의미 | 64 lane이 **같은 값** 가질 때 | lane마다 **다른 값** |
| 예시 | loop counter, base address | per-thread tile index |
| 폭 | 32 또는 64 bit × 1 | 32 bit × 64 lane |

컴파일러가 "이 값은 모든 lane에서 동일하다"고 판단 → SGPR에 두고 SALU 명령으로 처리.
lane마다 다르면 → VGPR + VALU.

---

## 4. "co-issues with one vector instruction every cycle"의 정확한 의미

이 문장은 *"scalar ALU 자체가 vector 명령"*이 아니다. 의미는:

> 매 사이클 scheduler는 **1개의 scalar 명령 + 1개의 vector 명령을 동시에 서로 다른 port로 발사**할 수 있다.

### 타임라인 예시

```
cycle:        1        2        3        4
SALU port:    s_add    s_cmp    s_load   s_branch
VALU/VMEM:    v_store  v_mul    v_store  ─
LDS:          ─        ds_read  ─        ─
```

매 사이클 여러 port가 각자 명령을 받음 → 한 wavefront의 instruction stream을 컴파일러가 SALU / VALU / VMEM / LDS / Branch 다섯 종류로 나눠 배치해두면, **명령 종류만 다르면 서로 issue 자원을 두고 경쟁하지 않는다.**

---

## 5. "Free"의 정확한 의미

Scalar 명령은 vector 파이프라인의 issue slot을 점유하지 않는다. 따라서 vector 작업이 같은 사이클에 진행 중이라도 **scalar 명령의 비용이 vector 관점에서 0**으로 보인다 → 이것을 **"free co-issue"**라고 부른다.

자원이 정말 공짜인 것이 아니라, **vector throughput을 깎지 않는다**는 뜻이다.

---

## 6. Single-Thread Dispatcher Kernel에 미치는 영향

### 현재 Vortex (single issue, scalar/vector 미분리)

```asm
addi t0, t1, X          # 주소 산술
slli t2, t3, Y          # offset 계산
or   t0, t0, t2         # word 조립
sd   t0, 0(STREAM_ADDR) # stream_send (MMIO store)
... 다음 word마다 위를 반복
```

모든 명령이 single issue port를 직렬 점유 → store 사이에 7/10/16 cycle gap 발생.

### GCN 구조라면

dispatcher의 모든 값이 uniform이므로 산술이 SALU로 흘러가고, 직전 descriptor의 MMIO store가 VMEM port에서 동시에 진행:

```
cycle 1:  SALU: s_add  s0, s1, X
cycle 2:  SALU: s_lshl s2, s3, Y    │ VMEM: buffer_store v(prev)
cycle 3:  SALU: s_or   s0, s0, s2   │ VMEM: ─
cycle 4:  v_mov v0, s0 (broadcast)  │ VMEM: buffer_store v0   ← 실제 stream_send
```

산술이 store와 **동일 사이클에 다른 port에서 병렬 처리** → store 사이 gap이 1–2 cycle floor까지 수렴, 산술은 그림자에 묻힌다.

---

## 7. GCN 특이사항: Scalar는 Store 불가

Scalar unit은 **load만 가능**하고 store는 불가 (read-only scalar L1, constant cache 백엔드).

그래서 dispatcher kernel을 GCN에 매핑하면:

- 산술 / branch / loop 제어 → **SALU**
- `stream_send` (MMIO store) → **VMEM**
- 두 port가 **사이클마다 병렬 동작**

결과: dispatcher의 critical path가 *sd 명령 throughput 자체*로 수렴 (이론상 1/cycle), 산술은 사라진다.

---

## 8. Vortex에 GCN 방식을 적용하려면

추가해야 할 하드웨어:

1. **SGPR file** — wavefront당 32–128개의 32-bit register, lane-broadcast 지원
2. **SALU pipeline** — 단일 32/64-bit ALU + branch unit
3. **Issue logic 확장** — 한 사이클에 SALU 1 + VALU/VMEM 1을 서로 다른 port로 동시 발사
4. **Compiler / ISA 지원** — uniform value 추출

(4)는 NVIDIA Turing+ uniform datapath, AMD GCN 모두에서 풀이가 끝난 표준 컴파일러 분석이므로 새로 발명할 필요는 없다.

---

## 9. 비교 요약

| 방식 | 변경 비용 | 효과 |
|---|---|---|
| **Full GCN-style scalar unit** | 별도 SGPR + SALU + issue port 추가 | inter-store gap → ~1 cycle floor (산술이 그림자) |
| **1-thread fast-path (SIMT-X-style)** | 기존 SIMT pipeline의 corner-case 최적화만 (forwarding, mask gating bypass) | gap mode 한두 단계 감소, datapath 추가 없음 |

전자가 효과는 크지만 비용도 크고, 후자는 cheap experiment로 ROI를 먼저 측정하기에 적합하다.

---

## 10. 참고

- AMD GCN Architecture Whitepaper
- Chips and Cheese: *GCN, AMD's GPU Architecture Modernization*
- NVIDIA Turing+ uniform datapath (UR registers, uniform-only ALU)
- Intel Xe scalar EU PRM
