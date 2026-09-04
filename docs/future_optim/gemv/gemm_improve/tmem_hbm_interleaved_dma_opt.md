# Restricted Interleaved HBM–DMA–TMEM Interconnection

# 문제점

현재 GEMM TMEM backend에서는 `NUM_DMA_CHANNELS` 하나가 서로 다른 세 가지 하드웨어
개수를 동시에 결정한다.

```text
NUM_DMA_CHANNELS
  ├─ TMEM bank 개수
  ├─ DMA channel 개수
  └─ HBM AXI port 개수
```

`VX_core_top`은 `NUM_TMEM_BANKS = NUM_DMA_CHANNELS`로 고정하고,
`VX_tmem_subsystem`은 `NUM_BANKS`개의 TMEM bank와 같은 수의 DMA channel을 생성한다.
HBM 쪽도 `C_M_AXI_MEM_NUM_PORTS`와 `Vortex_axi.NUM_HBM_PORTS`의 기본값을
`NUM_DMA_CHANNELS`로 사용한다. 따라서 현재 구현에서 정상적으로 표현되는 topology는
사실상 다음 경우뿐이다.

```text
NUM_TMEM_BANKS == NUM_DMA_CHANNELS == NUM_HBM_PORTS

DMA[c] <-> TMEM_BANK[c]
DMA[c] <-> HBM_PORT[c]
```

이 결합 때문에 TMEM의 on-chip bank 수와 외부 HBM port 수를 서로 다르게 선택할 수 없다.
예를 들어 TMEM bank를 늘려 local bank conflict를 줄이되 HBM AXI port 수는 유지하거나,
반대로 platform이 제공하는 HBM port 수에 맞춰 DMA channel 수만 정하는 구성을 현재
parameter 체계로는 나타낼 수 없다.

## 분리되어야 하는 세 가지 개수

다음 세 parameter는 서로 다른 물리 자원을 나타내므로 독립된 이름을 가져야 한다.

```text
NUM_TMEM_BANKS     TMEM single-port SRAM bank 수
NUM_DMA_CHANNELS   동시에 진행할 수 있는 HBM<->TMEM DMA channel 수
NUM_HBM_PORTS      외부 HBM AXI master port 수
```

세 값은 서로 같을 필요가 없지만, restricted interconnection이 정적으로 구성될 수 있도록
다음 configuration contract가 필요하다.

```text
NUM_TMEM_BANKS, NUM_DMA_CHANNELS, NUM_HBM_PORTS는 모두 양의 2의 거듭제곱

NUM_DMA_CHANNELS <= min(NUM_TMEM_BANKS, NUM_HBM_PORTS)

PLATFORM_MEMORY_NUM_BANKS % NUM_HBM_PORTS == 0
```

마지막 조건에서 `PLATFORM_MEMORY_NUM_BANKS`는 physical HBM bank 수이고,
`NUM_HBM_PORTS`는 RTL에 노출되는 AXI port 수다. 두 개수는 같은 개념이 아니다.

## 임의의 unequal topology를 현재 direct mapping으로 표현할 수 없음

현재 TMEM subsystem의 DMA port는 channel `c`를 TMEM bank `c`에 직접 연결한다.
따라서 DMA channel보다 TMEM bank가 많으면 추가 bank에 도달할 DMA 경로가 없다.
HBM 쪽 역시 일반적인 unequal 구성을 위한 정적 ownership mapping이 없고, equal-port
경로와 모든 DMA를 합치는 merged 경로만 구분한다.

이번 최적화가 다뤄야 하는 핵심 문제는 full crossbar를 추가하지 않으면서 다음 두 관계를
정적으로 결정하는 것이다.

```text
각 TMEM bank는 정확히 어느 DMA channel에 속하는가?
각 HBM port는 정확히 어느 DMA channel에 속하는가?
```

연결은 runtime arbitration으로 모든 endpoint 사이를 자유롭게 선택하는 crossbar가 아니라,
elaboration 시점에 결정되는 restricted interleaved topology여야 한다. 각 TMEM bank와 HBM
port는 하나의 DMA ownership class에만 속하고, DMA는 자기 class 밖의 endpoint에는 접근하지
않아야 한다.

## 목표 topology 예시

다음 구성에서는 HBM port가 2개, TMEM bank가 4개이고 DMA channel이 2개다.

```text
NUM_HBM_PORTS    = 2
NUM_TMEM_BANKS   = 4
NUM_DMA_CHANNELS = 2

DMA0: HBM_PORT0 <-> TMEM_BANK0, TMEM_BANK2
DMA1: HBM_PORT1 <-> TMEM_BANK1, TMEM_BANK3
```

TMEM bank ownership을 channel 수로 interleave하면 위 관계는 다음처럼 표현된다.

```text
TMEM_BANK b의 owner DMA = b % NUM_DMA_CHANNELS

DMA0 owns TMEM banks {0, 2}
DMA1 owns TMEM banks {1, 3}
```

일반적으로 HBM port 수가 DMA channel 수보다 큰 구성까지 허용하려면 HBM port에도 동일한
형태의 정적 ownership 규칙이 필요하다. 다만 한 DMA가 여러 HBM port를 소유할 때의 channel
내부 동시성, request ordering, response routing은 아직 정의되어 있지 않다. 이 부분을 정의하지
않은 채 parameter assertion만 완화하면 연결은 compile되더라도 기대한 bandwidth나 정확한
response ownership을 보장할 수 없다.

## Tile-major layout과 bandwidth 기대가 topology에 의존함

목표는 tensor가 tile-major로 배치됐을 때 연속되거나 동시에 필요한 tile들이 서로 다른 DMA
ownership class로 분산되어 모든 DMA channel이 병렬로 HBM<->TMEM transfer를 수행하게 만드는
것이다. 하지만 현재 address mapping은 다음 항목을 하나의 독립된 contract로 정의하지 않는다.

- tensor tile 주소에서 HBM port를 선택하는 bit 또는 modulo 규칙
- 같은 tile 주소에서 destination TMEM bank를 선택하는 규칙
- 선택된 HBM port와 TMEM bank가 동일 DMA ownership class에 속한다는 조건
- multi-beat DMA command가 channel boundary를 넘을 때의 분할 가능 여부
- channel별 request/response tag와 completion ordering

따라서 단순히 TMEM bank 수만 4로, HBM port 수만 2로 변경하면 tile-major address가 원하는
`{bank0, bank2}`와 `{bank1, bank3}` 경로로 자동 분산되지 않는다. 주소 interleave와 DMA
ownership이 일치하지 않으면 특정 channel만 사용되거나, 하나의 command가 연결되지 않은
bank/port 조합을 요구하거나, 추가 routing logic 없이는 transfer 자체를 표현할 수 없게 된다.

## Crossbar 없이 풀어야 하는 범위

완전한 `NUM_HBM_PORTS x NUM_TMEM_BANKS` crossbar는 모든 HBM port가 모든 TMEM bank에 접근하게
하므로 연결 수, arbitration, mux, timing 비용이 증가한다. 이번 최적화의 전제는 이 구조를
도입하지 않는 것이다.

따라서 이후 해결책은 다음 문제를 동시에 만족해야 한다.

- 세 parameter가 서로 다른 값이어도 elaboration과 address mapping이 일관될 것
- 각 endpoint가 정확히 하나의 DMA ownership class에 속할 것
- 허용되지 않은 HBM-port/TMEM-bank 조합의 물리 경로를 만들지 않을 것
- tile-major access가 channel별로 균등하게 분산될 수 있을 것
- request, response, tag, completion이 해당 restricted path 안에서만 왕복할 것
- 기존 equal configuration인 `8/8/8`의 direct mapping을 그대로 표현할 수 있을 것

현재 RTL은 이 ownership/interleave contract가 `NUM_DMA_CHANNELS` 하나와 동일-index 연결에
암묵적으로 묶여 있다는 것이 핵심 문제다.

# 해결책

## 1. 세 개의 독립 parameter와 configuration contract

TMEM bank, DMA engine, HBM AXI port의 개수를 다음 세 parameter로 분리한다.

```text
T = NUM_TMEM_BANKS
D = NUM_DMA_CHANNELS
H = NUM_HBM_PORTS
P = PLATFORM_MEMORY_NUM_BANKS
```

세 값은 동일할 필요가 없지만 다음 조건을 elaboration-time assertion으로 강제한다.

```text
T > 0, D > 0, H > 0

is_power_of_two(T)
is_power_of_two(D)
is_power_of_two(H)

D <= min(T, H)

P % H == 0
```

`T`, `D`, `H`가 모두 2의 거듭제곱이고 `D <= T`, `D <= H`이면 `D`는 `T`와
`H`의 약수다. 이 성질을 이용해 모든 TMEM bank와 HBM port를 겹치지 않는 `D`개의
DMA ownership class로 분할한다.

## 2. 64 B logical block 기반의 공통 interleave contract

Software와 GEMM command에는 TMEM과 HBM이 계속 연속된 logical byte address space로
보이게 한다. Physical endpoint 선택은 `MEM_BLOCK_SIZE=64 B` 단위로 RTL 내부에서만
수행한다.

```text
block(addr) = floor(addr / MEM_BLOCK_SIZE)

hbm_port(addr) = block(addr) % H
dma_channel(addr) = block(addr) % D
tmem_bank(addr) = block(addr) % T
```

HBM port와 TMEM bank의 owner DMA는 다음처럼 정한다.

```text
hbm_owner(port) = port % D
tmem_owner(bank) = bank % D
```

임의의 logical block `n`에 대해 다음 관계가 항상 성립한다.

```text
(n % H) % D = n % D
(n % T) % D = n % D
```

따라서 block `n`이 선택하는 HBM port와 TMEM bank는 항상 동일한 DMA channel에
속한다. Runtime에 임의의 HBM-port/TMEM-bank 조합을 찾는 crossbar가 필요하지 않다.

DMA channel `c`가 소유하는 endpoint 집합은 elaboration 시점에 다음처럼 고정된다.

```text
HBM_SET(c)  = {c, c+D, c+2D, ..., < H}
TMEM_SET(c) = {c, c+D, c+2D, ..., < T}
```

서로 다른 DMA channel의 집합은 겹치지 않는다. 물리 배선도 같은 ownership class
안에서만 만들고 class 사이의 연결은 생성하지 않는다.

## 3. TMEM 쪽 restricted interleaved demux

DMA controller는 logical transfer를 `D`개 channel로 interleave한다. Logical block `n`은
channel `n % D`에 들어가며, 해당 channel 안에서 보이는 block 번호는 다음과 같다.

```text
channel_local_block = floor(n / D)
```

DMA channel `c`의 TMEM-side interconnect는 `T/D`개의 소유 bank 중 하나만 선택하는
작은 demux로 구성한다.

```text
owned_bank_slot = channel_local_block % (T / D)
tmem_bank = c + owned_bank_slot * D

bank_local_block = floor(channel_local_block / (T / D))
bank_local_byte_addr = bank_local_block * MEM_BLOCK_SIZE
```

모든 값이 2의 거듭제곱이므로 modulo와 division은 multiplier/divider가 아니라 address
bit slice와 shift로 구현할 수 있다.

이 interconnect는 full `D x T` crossbar가 아니다. DMA channel `c`는 오직
`TMEM_SET(c)`에만 연결된다. 예를 들어 `T=4`, `D=2`이면 다음 두 개의 독립적인 1-to-2
demux만 필요하다.

```text
DMA0 -> {TMEM_BANK0, TMEM_BANK2}
DMA1 -> {TMEM_BANK1, TMEM_BANK3}
```

Read response는 선택된 bank ID 또는 기존 request tag에 저장한 bank slot을 이용해 같은
DMA channel로 되돌린다. 다른 ownership class의 response arbiter와는 연결하지 않는다.

## 4. HBM 쪽 restricted interleaved routing

HBM logical address는 `VX_mem_remap`에서 `H=NUM_HBM_PORTS`를 기준으로 remap한다.
Consecutive 64 B block은 다음처럼 HBM port에 round-robin 배치된다.

```text
block 0 -> HBM port 0
block 1 -> HBM port 1
...
block H-1 -> HBM port H-1
block H -> HBM port 0
```

HBM 쪽도 DMA channel `c`를 `HBM_SET(c)`에만 연결한다.

- `D == H`이면 DMA channel `c`와 HBM port `c`를 직접 연결한다.
- `D < H`이면 channel `c` 안에 `H/D`개 port만 선택하는 restricted AXI demux를 둔다.
- AXI AR/AW address가 선택한 port를 transaction state에 보존하고 R/B response와 W data가
  같은 port를 사용하도록 한다.
- 하나의 AXI burst는 중간에 HBM port가 바뀌지 않도록 descriptor 생성과 assertion으로
  보장한다.

`D < H` 구성은 legal하지만, 하나의 DMA channel이 한 cycle에 하나의 beat만 issue할 수
있다면 전체 peak bandwidth는 `D` channel로 제한된다. TMEM/HBM 양쪽의 가능한 병렬도를
모두 사용하려는 성능 configuration은 다음 값을 사용하는 것이 적절하다.

```text
D = min(T, H)
```

`D < min(T, H)`는 area를 줄이는 legal configuration이지만 모든 HBM port 또는 TMEM bank의
동시 bandwidth를 사용한다는 보장은 없다.

## 5. `H=2`, `T=4`, `D=2`의 정확한 배치

`[0, 4096)`의 4096 B를 읽으면 64 B block이 64개 생성된다. 각 block은 다음 규칙으로
배치된다.

| Byte 범위 | HBM port | DMA | TMEM bank | Bank-local offset |
|---|---:|---:|---:|---:|
| 0–63 | 0 | 0 | 0 | 0 |
| 64–127 | 1 | 1 | 1 | 0 |
| 128–191 | 0 | 0 | 2 | 0 |
| 192–255 | 1 | 1 | 3 | 0 |
| 256–319 | 0 | 0 | 0 | 64 |
| 320–383 | 1 | 1 | 1 | 64 |
| 384–447 | 0 | 0 | 2 | 64 |
| 448–511 | 1 | 1 | 3 | 64 |
| ... | ... | ... | ... | ... |
| 4032–4095 | 1 | 1 | 3 | 960 |

최종 TMEM 내용은 다음과 같다.

```text
TMEM bank0: logical blocks 0, 4, 8, ..., 60   = 1024 B
TMEM bank1: logical blocks 1, 5, 9, ..., 61   = 1024 B
TMEM bank2: logical blocks 2, 6, 10, ..., 62  = 1024 B
TMEM bank3: logical blocks 3, 7, 11, ..., 63  = 1024 B
```

DMA0과 DMA1은 각각 32개 block, 2048 B를 처리한다. HBM port가 두 개이고 DMA channel도
두 개이므로 두 channel이 동시에 진행하면 HBM의 두 port bandwidth를 모두 사용할 수 있다.
TMEM에는 cycle당 최대 두 개의 DMA write가 들어가지만, 대상 bank가 두 ownership class로
분리되므로 두 DMA가 같은 bank를 선택하는 충돌은 발생하지 않는다.

## 6. Load/store 대칭성과 logical address 보존

HBM-to-TMEM load와 TMEM-to-HBM store는 정확히 같은 ownership/address 변환을 반대 방향으로
사용한다.

```text
load:
  logical HBM block -> HBM port -> owner DMA -> owner TMEM bank/local row

store:
  logical TMEM block -> owner TMEM bank/local row -> owner DMA -> HBM port
```

두 방향에서 다음 값이 동일해야 한다.

- logical block 번호
- DMA ownership class
- TMEM bank와 bank-local row
- HBM port와 physical-bank remap 결과
- command completion이 포함하는 전체 beat 수

Load와 store 중 한쪽만 새 mapping을 사용하면 output tensor가 logical address 순서로 복원되지
않으므로, 두 방향의 round-trip mapping을 하나의 contract로 구현한다.

## 7. 기존 `fpint_gemm` tile-major layout 유지

`fpint_gemm` device kernel은 DRAM base, logical TMEM buffer base, tile 크기를 register에 기록한다.
새 mapping은 이 software-visible 주소와 register map을 변경하지 않는다.

```text
software-visible TMEM address = 기존과 동일한 linear byte address
physical TMEM bank selection = RTL 내부의 block % T
physical HBM port selection  = RTL 내부의 block % H
```

따라서 다음 항목은 유지한다.

- Input/Weight/Scale/ZP/Output의 기존 tile-major DRAM layout
- GEMM FSM이 만드는 DMA command의 logical base와 segment size 의미
- GEMM local DMA가 사용하는 logical TMEM base/stride
- W/S/Z/Input consumer가 관찰하는 data 순서
- 기존 job register map과 device kernel binary interface

DMA load의 source와 destination 시작 block은 동일 DMA ownership class에 속해야 한다.

```text
(src_hbm_block % D) == (dst_tmem_block % D)
```

Store도 같은 조건을 반대 방향으로 적용한다. Buffer base가 512 B 경계에 있는 것만으로는
충분하지 않고, kernel/FSM이 base에 더하는 tile/row/group offset까지 포함한 모든 실제 DMA
command에서 위 congruence가 성립해야 한다. 현재 `fpint_gemm`의 tile-major slot은 이 목적을
위해 512 B 단위로 정렬되지만, RTL은 layout을 가정하지 말고 command마다 조건을 assert한다.
`D <= 8`에서는 512 B 정렬된 slot의 시작점이 `D * MEM_BLOCK_SIZE` 정렬을 만족한다. 더 큰
`D`를 지원하거나 slot 내부 offset이 이 정렬을 깨는 경우에는 software stride/alignment를
확장하거나 descriptor가 source/destination 시작 channel 차이를 처리하도록 해야 한다.

Host regression의 TMEM capacity 계산은 DMA channel 수가 아니라 실제 TMEM bank 수를 사용해야
한다.

```text
TMEM total bytes = TMEM_BANK_SIZE * NUM_TMEM_BANKS
```

이는 tensor의 tile-major layout을 변경하는 작업이 아니라, 분리된 parameter에 맞게 실제 TMEM
용량을 보고하는 수정이다. Device kernel과 DMA command format은 그대로 유지한다.

## 8. 기존 equal topology 호환성

`T == D == H`이면 각 ownership class에 TMEM bank와 HBM port가 하나씩만 존재한다.

```text
HBM_SET(c)  = {c}
TMEM_SET(c) = {c}
```

이 경우 restricted demux는 elaboration 시 제거되고 기존 direct mapping과 동일해진다.
따라서 현재 `8/8/8` configuration은 별도 compatibility mode 없이 같은 수식의 특수한 경우로
유지한다.

## 9. U55C HBM remap contract 보존

### Remap은 DMA/TMEM interleave와 별개의 address layer

U55C의 physical HBM은 32개 pseudo-channel(PC)을 가지며 현재 XRT platform 연결은 8개의
top-level AXI port가 각각 연속된 4개 PC를 소유하도록 구성되어 있다.

```text
HBM port0 -> PC0,  PC1,  PC2,  PC3
HBM port1 -> PC4,  PC5,  PC6,  PC7
HBM port2 -> PC8,  PC9,  PC10, PC11
...
HBM port7 -> PC28, PC29, PC30, PC31
```

이 mapping은 `hw/syn/xilinx/xrt/platforms.mk`의 `sp` 연결과 정확히 같아야 한다. TMEM bank
수나 DMA channel 수를 변경하더라도, `H=NUM_HBM_PORTS=8`을 유지하는 U55C build에서는 이
port-to-PC mapping을 변경하지 않는다.

`VX_mem_remap`은 software-visible 64 B block 번호 `n`을 다음 세 값으로 분해한다.

```text
P = PLATFORM_MEMORY_NUM_BANKS
H = NUM_HBM_PORTS
PC_PER_PORT = P / H

q = floor(n / H)
r = n % H                         // HBM port

pc = r * PC_PER_PORT
   + (q % PC_PER_PORT)

pc_row = floor(q / PC_PER_PORT)
```

U55C의 `P=32`, `H=8`, `PC_PER_PORT=4`에서는 다음 순서가 된다.

| Logical byte address | Block `n` | HBM port `r` | PC | PC-local row |
|---:|---:|---:|---:|---:|
| 0 | 0 | 0 | 0 | 0 |
| 64 | 1 | 1 | 4 | 0 |
| 128 | 2 | 2 | 8 | 0 |
| 192 | 3 | 3 | 12 | 0 |
| 256 | 4 | 4 | 16 | 0 |
| 320 | 5 | 5 | 20 | 0 |
| 384 | 6 | 6 | 24 | 0 |
| 448 | 7 | 7 | 28 | 0 |
| 512 | 8 | 0 | 1 | 0 |
| 576 | 9 | 1 | 5 | 0 |
| ... | ... | ... | ... | ... |
| 2048 | 32 | 0 | 0 | 1 |

따라서 사용자가 요구한 다음 동작은 새 restricted DMA/TMEM interconnection에서도 그대로
보존한다.

```text
logical address 0 B  -> HBM port0 -> PC0
logical address 64 B -> HBM port1 -> PC4
```

### `NUM_HBM_PORTS`와 `NUM_DMA_CHANNELS`의 역할을 섞지 않음

parameter 분리 후 remap의 `NUM_PORTS`에는 반드시 `NUM_HBM_PORTS`를 전달한다.

```text
VX_mem_remap.NUM_PORTS = NUM_HBM_PORTS
```

반대로 DMA descriptor가 하나의 channel에 할당할 logical block 간격은
`NUM_DMA_CHANNELS`를 기준으로 한다.

```text
DMA channel stride = D * MEM_BLOCK_SIZE
HBM port stripe     = H * MEM_BLOCK_SIZE
```

현재 두 값이 모두 `NUM_DMA_CHANNELS`에 묶여 있어 차이가 드러나지 않는다. 분리 후에는
다음 두 개념을 별도 derived constant로 유지해야 한다.

```text
DMA_CHANNEL_STRIDE_BYTES = D * MEM_BLOCK_SIZE
HBM_PORT_STRIPE_BYTES    = H * MEM_BLOCK_SIZE
```

`VX_gemm_tmem_dma_ctrl`이 channel `c`에 속하는 다음 logical block을 찾을 때는
`DMA_CHANNEL_STRIDE_BYTES`를 사용한다. `VX_mem_remap`이 같은 HBM port의 다음 block과 PC를
계산할 때는 `H`와 `PC_PER_PORT`를 사용한다. 기존 `HBM_BUS_STRIDE` 이름 하나를 두 의미에
공유하면 unequal configuration에서 잘못된 port 또는 PC로 접근할 수 있으므로 용도별로
분리한다.

### Remap 이후에도 DMA ownership invariant가 유지됨

Logical block `n`의 HBM port는 `r=n%H`이고 그 port의 owner DMA는 `r%D`다.
`D`와 `H`가 2의 거듭제곱이며 `D<=H`이므로 `D`는 `H`의 약수다.

```text
hbm_owner(n)
  = (n % H) % D
  = n % D
  = dma_channel(n)
```

TMEM 쪽도 같은 방식으로 다음이 성립한다.

```text
tmem_owner(n)
  = (n % T) % D
  = n % D
```

따라서 U55C remap이 PC 번호를 재배치해도 HBM port와 TMEM bank의 DMA ownership class는
변하지 않는다. Remap은 ownership class 내부에서 logical address를 physical PC와 row로
변환할 뿐이며, TMEM interleave와 충돌하지 않는다.

예를 들어 `H=8`, `T=4`, `D=2`이면 다음과 같다.

```text
DMA0 owns HBM ports {0,2,4,6}
DMA1 owns HBM ports {1,3,5,7}

DMA0 owns TMEM banks {0,2}
DMA1 owns TMEM banks {1,3}
```

처음 8개 block은 다음 경로를 사용한다.

| Block | HBM port / PC | DMA | TMEM bank |
|---:|---|---:|---:|
| 0 | port0 / PC0 | 0 | 0 |
| 1 | port1 / PC4 | 1 | 1 |
| 2 | port2 / PC8 | 0 | 2 |
| 3 | port3 / PC12 | 1 | 3 |
| 4 | port4 / PC16 | 0 | 0 |
| 5 | port5 / PC20 | 1 | 1 |
| 6 | port6 / PC24 | 0 | 2 |
| 7 | port7 / PC28 | 1 | 3 |

이 구성에서는 U55C의 8-port PC mapping은 그대로이고, 두 DMA가 각자 네 개의 고정된 HBM
port 집합만 담당한다. Full crossbar는 필요하지 않다. 다만 DMA가 두 개뿐이므로 한 cycle에
발행할 수 있는 최대 beat 수는 두 개이며, 여덟 HBM port를 모두 동시에 사용하는 bandwidth는
보장하지 않는다.

### `H=2` 구성은 U55C `H=8` mapping과 다른 legal topology

이 문서 앞부분의 `H=2`, `T=4`, `D=2` 예시는 top-level HBM AXI port 자체를 두 개만
노출하는 별도 configuration이다. 같은 `P=32`에서 `H=2`이면 port당 PC 수는 16개가 된다.

```text
HBM port0 -> PC0..PC15
HBM port1 -> PC16..PC31

logical address 0 B  -> port0 -> PC0
logical address 64 B -> port1 -> PC16
```

따라서 `64 B -> PC4`는 `H=8`일 때의 contract이지 `H=2`에서도 유지되는 절대 규칙이 아니다.
U55C production build에서 기존 `PC0..3`, `PC4..7`, ... 연결을 유지하려면
`NUM_HBM_PORTS=8`을 사용해야 한다. HBM port 수를 변경하려면 RTL parameter뿐 아니라
top-level port 생성과 `platforms.mk`의 `sp` mapping도 `PC_PER_PORT=P/H`에 맞게 함께 생성해야
한다.

### AXI burst와 response routing 조건

하나의 AXI burst는 하나의 top-level HBM port와 그 port가 소유한 하나의 PC window 안에
머물러야 한다. Restricted HBM router는 다음을 보장한다.

- remap된 AR/AW address에서 HBM port를 선택한다.
- 선택된 port가 현재 DMA ownership class에 속하는지 확인한다.
- AR/AW부터 마지막 R/B까지 port selection을 transaction state에 보존한다.
- W channel은 AW가 선택한 port로만 전송한다.
- burst의 첫 주소와 마지막 주소가 같은 HBM port/PC window에 속하는지 assertion한다.
- 여러 port의 response가 한 DMA로 돌아올 때 AXI ID 또는 별도 route tag로 원래 transaction을
  구분한다.

Descriptor는 channel이 소유한 여러 HBM port와 PC를 순회할 수 있지만, 개별 burst를 port
경계에 걸쳐 만들면 안 된다. 기존 physical-bank burst grouping은 유지하되 `H`, `D`, `P/H`,
`P/D`를 구분해 계산한다.

```text
PC_PER_HBM_PORT = P / H
PC_PER_DMA      = P / D
HBM_PORTS_PER_DMA = H / D
TMEM_BANKS_PER_DMA = T / D
```

### Simulation과 hardware platform도 같은 remap parameter를 사용

현재 xrt-vcs backend의 AXI port queue 수, port-range assertion, PC-per-port 계산 일부는
`NUM_DMA_CHANNELS`를 사용한다. 이를 모두 `NUM_HBM_PORTS` 기준으로 변경해야 RTL remap과
simulation inverse mapping이 일치한다.

```text
pending AXI queue count = NUM_HBM_PORTS
AW route state count    = NUM_HBM_PORTS
PC_PER_PORT             = P / NUM_HBM_PORTS
allowed port window     = [port * PC_PER_PORT,
                           (port+1) * PC_PER_PORT)
```

AFU wrapper, VCS testbench, generated top-level AXI port 반복 수도 동일하게 `NUM_HBM_PORTS`를
사용한다. Hardware에서는 `platforms.mk`의 `sp` 연결이 같은 contiguous PC window를 사용해야
한다.

### Remap 관련 필수 assertion

기존 parameter assertion에 다음 remap/ownership 검사를 추가한다.

```text
P % H == 0

remapped_pc / (P/H) == selected_hbm_port

selected_hbm_port % D == selected_dma_channel
selected_tmem_bank % D == selected_dma_channel

src_hbm_block % D == dst_tmem_block % D

AR/AW burst start port == AR/AW burst end port
AR/AW burst start PC   == AR/AW burst end PC
```

Directed test에서는 적어도 다음 경계를 검사한다.

```text
block 0, 1
block H-1, H
block P-1, P
4KB burst boundary 전후
DMA ownership class가 바뀌는 연속 block
같은 DMA가 소유한 서로 다른 HBM port로 넘어가는 block
```

결론적으로 U55C remap concept은 이번 최적화와 호환된다. 영향을 받는 것은 PC packing 수식이
아니라 그 수식에 전달되는 port-count parameter와 remap 이후 AXI port routing이다. U55C
`H=8` configuration에서 `0 B -> PC0`, `64 B -> PC4`를 golden contract로 유지하고, DMA/TMEM
ownership interleave는 그 아래의 독립된 address layer로 추가한다.

# 구현 계획

## 1. Parameter와 derived constant를 먼저 분리

`VX_config.vh`에 다음 세 architecture parameter를 독립적으로 정의한다.

```text
NUM_TMEM_BANKS
NUM_DMA_CHANNELS
NUM_HBM_PORTS
```

기본값은 기존 configuration을 보존하도록 chained default를 사용한다.

```text
NUM_DMA_CHANNELS default = 8
NUM_TMEM_BANKS   default = NUM_DMA_CHANNELS
NUM_HBM_PORTS    default = NUM_DMA_CHANNELS
```

각 값을 사용하는 영역을 다음처럼 제한한다.

```text
NUM_TMEM_BANKS:
  TMEM SRAM instance 수
  local-DMA TMEM switch width
  Weight wide-read bank grouping
  software-visible TMEM total capacity

NUM_DMA_CHANNELS:
  VX_dma_unit instance 수
  GEMM DMA descriptor/channel state 수
  DMA completion aggregation
  logical block의 DMA ownership stripe

NUM_HBM_PORTS:
  AFU top-level AXI master port 수
  VX_mem_remap port decomposition
  Vortex_axi HBM port array와 demux/mux 수
  xrt-vcs per-port request/response state 수
```

기존 `HBM_BUS_STRIDE`는 용도가 모호하므로 최소한 다음 derived constant로 의미를 분리한다.

```text
DMA_CHANNEL_STRIDE_BYTES = NUM_DMA_CHANNELS * MEM_BLOCK_SIZE
HBM_PORT_STRIPE_BYTES    = NUM_HBM_PORTS * MEM_BLOCK_SIZE

TMEM_BANKS_PER_DMA = NUM_TMEM_BANKS / NUM_DMA_CHANNELS
HBM_PORTS_PER_DMA  = NUM_HBM_PORTS / NUM_DMA_CHANNELS
PC_PER_HBM_PORT    = PLATFORM_MEMORY_NUM_BANKS / NUM_HBM_PORTS
PC_PER_DMA         = PLATFORM_MEMORY_NUM_BANKS / NUM_DMA_CHANNELS
```

SystemVerilog elaboration과 host-side compile 모두에서 다음 조건을 검사한다.

```text
is_power_of_two(NUM_TMEM_BANKS)
is_power_of_two(NUM_DMA_CHANNELS)
is_power_of_two(NUM_HBM_PORTS)

NUM_DMA_CHANNELS <= NUM_TMEM_BANKS
NUM_DMA_CHANNELS <= NUM_HBM_PORTS

PLATFORM_MEMORY_NUM_BANKS % NUM_HBM_PORTS == 0
```

Legacy `PLATFORM_MEMORY_NUM_PORTS`가 정의된 configuration은 이를 `NUM_HBM_PORTS`의 alias로
정리하고, 둘이 동시에 정의되면 값이 같은지 검사해 port-count source of truth가 두 개가
되지 않게 한다.

## 2. Core/GEMM hierarchy의 array width 분리

다음 hierarchy에서 현재 `NUM_TMEM_BANKS=NUM_DMA_CHANNELS` 가정을 제거한다.

- `VX_core_top`
- `VX_core`
- `VX_gemm_node`
- `VX_gemm_tmem_dma_ctrl`
- `VX_tmem_subsystem`
- `VX_dma_engine`

Core에서 외부로 나가는 GEMM DMA AXI array와 DMA config/done/lookahead array는 `D`개로 만든다.
TMEM bank instance와 Input/Weight/Scale/ZP/Output local switch output은 `T`개로 만든다.

```text
dma_axi_m[D]
dma_cfg_if[D]
dma_done_if[D]
dma_lookahead_if[D]

tmem_bank[T]
local_dma_bank_ports[T]
```

`VX_tmem_subsystem`에는 `NUM_TMEM_BANKS`와 `NUM_DMA_CHANNELS`를 별도 parameter로 전달하고,
`VX_dma_engine.NUM_CHANNELS=D`를 유지한다. Weight wide-read grouping은 `T` 기준으로 계산한다.

## 3. GEMM DMA descriptor를 D-channel logical stripe로 유지

`VX_gemm_tmem_dma_ctrl`은 하나의 logical command를 `D`개 DMA channel에 분배한다.

```text
start_channel = logical_tmem_base_block % D
channel(block) = block % D
channel_local_block = floor(block / D)
```

현재 `tmem_bank_local_addr()`가 최종 TMEM bank-local 주소까지 만든다는 가정을 제거한다.
Controller는 `D`-channel-local 주소까지만 만들고, 이후 TMEM restricted interconnect가
`T/D` bank 선택 bit를 제거해 최종 bank-local 주소를 만든다.

HBM descriptor 계산에서는 다음 값을 혼동하지 않는다.

- 한 DMA channel이 소유한 다음 logical block: `D * 64 B`
- 같은 HBM port가 다시 선택되는 logical stripe: `H * 64 B`
- 같은 physical PC의 다음 row: `P * 64 B`
- DMA 하나가 소유하는 physical PC 수: `P/D`

Load와 store descriptor 모두 동일한 block ownership 수식을 사용한다. Command accept 시점에
effective source/destination base를 포함해 다음을 검사한다.

```text
src_hbm_block % D == dst_tmem_block % D
```

모든 active channel의 descriptor가 program되고, active channel의 AXI/TMEM transaction과 B/R
drain이 모두 끝난 뒤에만 logical DMA command completion을 발생시킨다.

## 4. TMEM-side restricted interconnect 추가

`VX_dma_engine`의 `D`개 TMEM membus와 `T`개 TMEM bank의 DMA-direct port 사이에 전용
restricted interconnect를 둔다. Full crossbar를 재사용하지 않고 ownership class별 독립
module 또는 generate block으로 구현한다.

```text
for each DMA channel c:
  connect only to banks c + k*D, k=0..T/D-1
```

Request path는 channel-local word address의 하위 `log2(T/D)` bit로 owned bank slot을 고르고,
나머지 상위 bit를 bank-local address로 전달한다.

```text
owned_slot = channel_local_word % (T/D)
bank = c + owned_slot*D
bank_local_word = floor(channel_local_word / (T/D))
```

Response path는 request tag에 owned slot을 추가하거나 bank별 response를 해당 owner DMA로만
arbitrate한다. 다음 contract를 유지한다.

- request가 stall되는 동안 selected bank, address, payload, tag 안정
- read response의 original DMA tag 복원
- 다른 DMA ownership class로 response가 이동하지 않음
- load/write completion 순서와 기존 `VX_dma_unit` contract 유지
- reset 시 pending route/tag state 제거

`T==D`이면 `T/D=1`이므로 interconnect가 기존 channel-to-bank direct wire로 최적화되게 한다.

## 5. DMA address remap을 H 기준으로 parameter화

`VX_dma_engine` 안의 `VX_mem_remap`과 LSU remap 모두 다음 값을 명시적으로 받게 한다.

```text
NUM_BANKS = PLATFORM_MEMORY_NUM_BANKS
NUM_PORTS = NUM_HBM_PORTS
```

Remap 수식 자체와 contiguous-PC packing은 변경하지 않는다. U55C `H=8`의 golden mapping은
다음으로 고정한다.

```text
port0 -> PC0..3
port1 -> PC4..7
...
port7 -> PC28..31

0 B  -> port0/PC0
64 B -> port1/PC4
```

Remap output에서 추출한 port index가 `remapped_pc / (P/H)`와 같은지 non-synthesis assertion을
추가한다.

## 6. HBM-side restricted AXI router 구현

각 core의 DMA channel `c` 앞에 `HBM_SET(c)={c,c+D,...,<H}`만 출력으로 갖는 restricted AXI
demux를 둔다. DMA AXI address는 이미 `VX_mem_remap`을 지난 physical coordinate이므로,
remapped PC의 상위 port field로 owned port slot을 선택한다.

```text
global_hbm_port = remapped_pc / (P/H)
assert global_hbm_port % D == c
owned_port_slot = floor(global_hbm_port / D)
```

- `H==D`이면 기존 DMA channel `c` -> HBM port `c` direct 연결을 사용한다.
- `H>D`이면 `H/D` output의 AXI demux를 사용한다.
- 각 HBM port `p`의 기존 mux에는 LSU와 core별 owner DMA channel `p%D`만 연결한다.
- 서로 다른 ownership class 사이에는 AXI path를 만들지 않는다.
- AXI demux의 AW/W/B 및 AR/R route state를 사용해 response를 원 DMA로 복귀시킨다.
- AXI ID width에 route ID가 추가될 경우 LSU/DMA/core mux ID bit 배치를 함께 audit한다.

기존 `Vortex_axi`의 equal-port branch와 모든 DMA를 하나로 합치는 merged branch는 arbitrary
unequal topology를 표현하지 못하므로 위 restricted topology로 교체한다.

## 7. AFU wrapper, XRT simulation, U55C platform 연결 정리

다음 top-level 반복 수를 모두 `H` 기준으로 변경한다.

- `VX_afu_wrap.C_M_AXI_MEM_NUM_PORTS`
- generated `vortex_afu` AXI port declaration/binding
- `xrtsim`/`xrtsim_vcs` shim과 testbench port arrays
- xrt-vcs C++ pending request, DRAM queue, AW state arrays
- per-port range assertion과 `PC_PER_PORT=P/H` 계산

U55C hardware connectivity는 `H`에 따라 다음 식으로 생성한다.

```text
m_axi_mem_p -> HBM[p*(P/H) : (p+1)*(P/H)-1]
```

첫 구현의 production target은 현재 platform contract를 보존하는 `H=8`로 둔다.

```text
m_axi_mem_0 -> HBM[0:3]
...
m_axi_mem_7 -> HBM[28:31]
```

`H=1,2,4` hardware build도 지원하려면 `platforms.mk`/Vitis connectivity generator가 동일
수식으로 `sp` line을 생성하게 한다. RTL의 `H`와 Vitis의 실제 port/PC 연결이 다르면 build를
실패시키는 generated-config check를 추가한다.

## 8. `fpint_gemm` software-visible contract 유지

Device kernel의 job register map, tile-major DRAM layout, DMA command format은 변경하지 않는다.
Logical TMEM base도 기존과 같은 linear byte address다.

Host가 사용하는 TMEM capacity만 실제 bank 수를 기준으로 수정한다.

```text
tensor_mem_size = TMEM_BANK_SIZE * NUM_TMEM_BANKS
```

적용 대상은 최소한 다음과 같다.

- `tests/regression/fpint_gemm_ffn_hw/main.cpp`
- `tests/regression/fpint_gemm_ffn_hw/bench_main.cpp`
- TMEM capacity를 `NUM_DMA_CHANNELS`로 계산하는 다른 host/runtime 코드

Buffer base뿐 아니라 실제 tile/row/qparam offset까지 포함한 DMA endpoint congruence를 directed
test와 RTL assertion으로 검증한다. Software data를 새로운 physical bank 순서로 repack하지
않고, interleave는 전부 RTL address layer에서 처리한다.

## 9. Debug probe와 assertion 추가

기능 검증과 FSDB 분석을 위해 다음 non-synthesis probe를 안정적인 이름으로 노출한다.

- logical block, selected DMA channel
- selected HBM port, remapped PC, PC-local row
- selected TMEM bank, bank-local row
- DMA ownership mismatch
- channel별 request/response/write/completion count
- port별 AR/R/AW/W/B count
- bank별 DMA-direct request/write/read count

필수 assertion은 다음과 같다.

- 세 parameter의 power-of-two/range/divisibility contract
- HBM port 및 TMEM bank owner가 현재 DMA channel과 일치
- held request의 route/address/tag/payload 안정성
- AXI burst가 하나의 HBM port와 PC window 안에 머묾
- TMEM bank-local address가 logical block round-trip 결과와 일치
- response route/tag가 request ownership과 일치
- channel별 request/response/completion count 보존
- logical command completion 전에 모든 active channel drain 완료
- reset 후 pending route와 stale response 없음

## 10. 구현 순서와 중간 gate

구현은 다음 순서로 진행한다.

1. Parameter/default/assertion과 hierarchy array width 분리
2. `VX_mem_remap` 및 simulator를 `H` 기준으로 전환하고 기존 `8/8/8` remap 회귀
3. DMA descriptor를 `D` 기준 channel-local address로 정리
4. TMEM-side restricted interconnect 추가 및 `T>D` focused unittest
5. HBM-side restricted AXI router 추가 및 `H>D` focused unittest
6. AFU/XRT/platform port-count 전파
7. host TMEM capacity 수정
8. full DMA/GEMM unittest와 `run_target_gemm.sh` integration

각 단계에서 첫 compile/simulation failure를 확인한 뒤 다음 단계로 진행한다. Equal topology의
direct path가 먼저 PASS하고, 그다음 asymmetric topology를 활성화한다. Primary integration
target은 `T/D/H=16/8/8`이다. 이 target은 U55C HBM port/PC remap과 8개 DMA channel을 그대로
유지하면서 TMEM 쪽에서만 channel `c`를 bank `{c,c+8}`에 연결하므로, TMEM bank 증가 효과를
다른 변수와 분리해 측정할 수 있다.

# 검증 계획

## 1. Static 및 elaboration 검증

Target config를 source하고 configured `build/` tree를 사용한다.

- `git diff --check`
- SystemVerilog lint와 port/interface width audit
- C++ host/xrt-vcs compile
- combinational loop/UNOPTFLAT audit
- generated top-level AXI port 수와 `platforms.mk` `sp` line 수 비교
- no-cross-class wiring audit: `port%D`와 `bank%D`가 다른 DMA에 연결되지 않음
- equal topology에서 restricted demux가 direct wire로 정리되는지 elaboration 확인

최소 elaboration matrix는 다음과 같다.

```text
T/D/H = 8/8/8   기존 direct topology
T/D/H = 16/8/8  primary target: DMA당 TMEM bank 2개
T/D/H = 4/2/2   TMEM fanout, HBM direct
T/D/H = 8/4/8   ownership class당 TMEM bank 2개/HBM port 2개
```

각 configuration에서 invalid parameter test도 수행한다.

```text
non-power-of-two T/D/H
D > T
D > H
P % H != 0
```

모두 elaboration-time에 명확한 fatal/error로 거부되어야 한다.

## 2. `VX_mem_remap` focused unittest

독립 remap unittest를 추가해 logical address와 `{port,PC,row}`를 reference function과 비교한다.

U55C `P=32,H=8`에서 다음 golden mapping을 반드시 확인한다.

```text
0 B    -> port0, PC0,  row0
64 B   -> port1, PC4,  row0
448 B  -> port7, PC28, row0
512 B  -> port0, PC1,  row0
2048 B -> port0, PC0,  row1
```

`P=32,H=2`에서는 별도의 legal mapping을 확인한다.

```text
0 B  -> port0, PC0
64 B -> port1, PC16
```

Block `0`, `H-1`, `H`, `P-1`, `P`, 4KB 경계, address-space 상단을 검사하고 software address로
inverse transform했을 때 원래 logical address와 정확히 같아야 한다.

## 3. TMEM restricted interconnect unittest

새 TMEM-side interconnect를 독립적으로 검증한다.

Primary target인 `T=16,D=8`에서 `[0,4096)` 64개 block을 load한 뒤 다음을 확인한다.

```text
DMA channel c request count = 8, c=0..7

DMA channel c owns banks {c, c+8}

bank0 blocks  = 0,16,32,48
bank1 blocks  = 1,17,33,49
...
bank7 blocks  = 7,23,39,55
bank8 blocks  = 8,24,40,56
...
bank15 blocks = 15,31,47,63

각 bank payload = 4 * 64 B
각 bank-local offset = 0,64,128,192
```

`T=4,D=2` small directed case도 함께 유지한다.

```text
DMA0 request count = 32
DMA1 request count = 32

bank0 blocks = 0,4,8,...,60
bank1 blocks = 1,5,9,...,61
bank2 blocks = 2,6,10,...,62
bank3 blocks = 3,7,11,...,63

각 bank payload = 16 * 64 B
각 bank-local offset = 0,64,...,960
```

동일 내용을 TMEM에서 다시 읽어 store 방향으로 통과시켜 `[0,4096)` byte stream이 완전히
복원되는지 round-trip 비교한다.

추가 case:

- `T=8,D=4`의 두 bank/owner mapping
- `T=D=8` direct compatibility
- `T=16,D=8`에서 channel `c`가 bank `c`, `c+8`을 번갈아 선택
- request/response backpressure와 out-of-order bank response
- held request route/payload 안정성
- bank-local address wrap 및 bank-size 마지막 block
- reset 중 pending request/response flush

## 4. HBM restricted AXI router unittest

DMA AXI router를 LSU나 GEMM datapath 없이 directed AXI test로 검증한다.

`H=8,D=2`에서 다음 ownership을 확인한다.

```text
DMA0 -> ports 0,2,4,6 only
DMA1 -> ports 1,3,5,7 only
```

각 port에 AR/AW를 발행하고 다음을 검사한다.

- 허용 port만 valid가 올라감
- AW stall 동안 W route가 바뀌지 않음
- interleaved R response가 원 DMA/ID로 복귀
- B response가 원 write transaction으로 복귀
- 같은 DMA가 소유한 서로 다른 port로 연속 burst 전환
- 여러 outstanding read/write의 ID/route 보존
- 4KB 및 PC-window 경계를 넘는 burst 거부
- reset 후 stale B/R response 없음

`H=D=8` direct case와 `H=D=2` direct case도 재검증한다.

## 5. DMA controller/engine unittest

기존 test를 parameter matrix로 확장한다.

```text
hw/unittest/gemm_tmem_dma_ctrl
hw/unittest/dma_engine
```

검증 항목:

- logical segment를 정확히 `D` channel로 분배
- non-zero start channel과 wraparound
- 짧은 segment에서 일부 channel만 active
- `[0,4096)` load/store descriptor의 channel별 32-beat 분배 (`D=2`)
- `[0,4096)` load/store descriptor의 channel별 8-beat 분배 (`D=8`)
- HBM/PC burst grouping과 AR/AW 4KB 제한
- source/destination modulo-D mismatch assertion
- PREPARE/ACTIVATE overlap과 ordered logical completion
- final R/B drain 전 completion 금지
- load/store round-trip 및 misaligned tail 회귀

## 6. TMEM/GEMM subsystem 회귀 unittest

Focused interconnect가 PASS한 뒤 다음 기존 VCS unittest를 configured build tree에서 실행한다.

```text
hw/unittest/tensor_mem_bank
hw/unittest/tmem_wide_read_switch
hw/unittest/lmem_dma_input_overlap
hw/unittest/lmem_dma_weight_overlap
hw/unittest/lmem_dma_qparam_overlap   TEST_ZP=0,1 각각 실제 rebuild
hw/unittest/lmem_dma_misal
hw/unittest/gemm_fsm
hw/unittest/gemm_ctrl
hw/unittest/gemm_sync
hw/unittest/gemm_unit_v2
hw/unittest/gemm_unit_v2_backpressure
```

각 test에서 request/response/write/done count, Weight wide bank grouping, ready/valid stability,
W/S/Z exact-generation fence, occupied reset cleanup이 기존과 동일하게 PASS해야 한다.

## 7. `gemm_node_improve` integration unittest

먼저 기존 equal configuration `T/D/H=8/8/8`을 실행해 numerical/metadata regression이 없는지
확인한다. 이후 TMEM bank만 두 배로 늘린 U55C target `T/D/H=16/8/8`을 실행한다.

```text
M = 4, 256
N = K = 256
QBLK = 32
QDIR = QCOL, QROW
WTRANS = 0
WLOAD = 8
```

필수 조건:

- output numerical comparison 전부 PASS
- Input metadata command/packet/last/done/scheduler count 일치
- HBM load/store와 TMEM bank payload loss/duplicate/reorder 0
- DMA0..DMA7 block count 균형
- DMA channel `c`의 TMEM direct access가 bank `{c,c+8}` 밖으로 나가지 않음
- `[0,4096)`에서 각 TMEM bank가 정확히 4개 block을 받음
- remapped port/PC가 U55C golden window 안에 있음
- illegal ownership route 0
- pipeline deadlock와 completion hang 없음

## 8. `run_target_gemm.sh` XRT-VCS blackbox

모든 unittest가 PASS한 뒤 configured `build/` directory에서 기존 wrapper를 사용한다. Simulator는
`xrt-vcs-sim` 경로만 사용하며 첫 failure에서 중단한다.

먼저 기존 `8/8/8` baseline을 한 번 rebuild해 backward compatibility를 확인한다. 그 다음
TMEM bank를 늘린 U55C target `T/D/H=16/8/8`을 별도 fingerprint로 rebuild한다.

각 configuration에서 다음 matrix를 순서대로 실행한다.

```text
M=4,   N=256, K=256, QBLK=32, WTRANS=0, QDIR=0, WLOAD=8
M=4,   N=256, K=256, QBLK=32, WTRANS=0, QDIR=1, WLOAD=8
M=256, N=256, K=256, QBLK=32, WTRANS=0, QDIR=0, WLOAD=8
M=256, N=256, K=256, QBLK=32, WTRANS=0, QDIR=1, WLOAD=8
```

Baseline과 target의 command shape는 다음과 같다.

```bash
cd build
source ../configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh

# Baseline: T/D/H=8/8/8
../ci/run_target_gemm.sh run \
  --m 4 --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8 \
  --configs-extra "-DNUM_TMEM_BANKS=8 -DNUM_DMA_CHANNELS=8 -DNUM_HBM_PORTS=8" \
  --rebuild

# Target: T/D/H=16/8/8
../ci/run_target_gemm.sh run \
  --m 4 --n 256 --k 256 --qblk 32 --qdir 0 --wtrans 0 --wload 8 \
  --configs-extra "-DNUM_TMEM_BANKS=16 -DNUM_DMA_CHANNELS=8 -DNUM_HBM_PORTS=8" \
  --rebuild
```

후속 QDIR/M case는 동일 compile fingerprint를 재사용한다. M=256 case는 기존처럼 충분한 timeout을
지정한다.

각 artifact에서 다음을 확인한다.

- manifest `exit_status=0`
- wrapper numerical `PASSED`
- `[target-gemm] PASSED`
- functional Error/Fatal/assertion/timeout 없음
- Input/Weight/output fire count와 stall count
- ACC read/write/scaler/output count 일치
- HBM port별 AR/R/AW/W/B count
- DMA channel별 전송량
- TMEM bank별 DMA-direct request 수와 local-DMA conflict 수
- port-range/ownership/remap assertion 0건

`8/8/8`과 `16/8/8` artifact에서 다음 성능 수치를 같은 표로 비교한다.

- total cycles, busy cycles, overlap ratio
- Input/Weight source fire와 stall
- TMEM requester별 bank grant/loss
- Weight wide-read partial-issue cycle
- Input 4-beat burst internal/boundary gap
- DMA channel별 active/idle cycle

TMEM bank 수 증가 효과를 보는 실험이므로 `16/8/8`의 numerical PASS만 확인하고 끝내지 않고,
`8/8/8` 대비 bank conflict와 total cycle이 실제로 개선됐는지 명시적으로 판정한다.

## 9. Remap/throughput waveform 확인

Blackbox numerical PASS 후 `8/8/8`과 `16/8/8`의 M=4 QCOL을 각각
`run_target_gemm.sh fsdb-gemm`으로 캡처해 다음을 cycle 단위로 비교한다.

- 처음 logical blocks 0..16의 `port/PC/DMA/TMEM-bank` mapping
- `0 B -> port0/PC0`, `64 B -> port1/PC4`
- `H=8,D=8,T=16` ownership table와 실제 waveform 일치
- 여덟 DMA channel의 동시 active 구간
- DMA channel `c`가 TMEM bank `c`, `c+8`을 번갈아 선택
- logical block 0..7은 bank 0..7, block 8..15는 bank 8..15에 저장
- AXI burst가 port/PC window를 넘지 않음
- final load/store completion이 마지막 R/B drain 이후 발생

이 단계에서는 `D=H=8`이므로 충분한 work가 있을 때 여덟 HBM port와 여덟 DMA channel이 모두
병렬로 진행할 수 있다. `8/8/8`과 `16/8/8`의 HBM traffic은 동일해야 하며, 차이는 TMEM bank
selection과 bank conflict에서만 발생해야 한다. Restricted TMEM router가 추가한 bubble과
channel별 불필요한 idle cycle을 별도로 측정한다.

## 10. 최종 성공 기준

다음 조건을 모두 만족해야 최적화를 완료한 것으로 판정한다.

- `8/8/8` 기존 topology의 unittest/blackbox numerical regression 없음
- `16/8/8` U55C target의 unittest와 four-case `run_target_gemm.sh` matrix PASS
- `[0,4096)` load/store round-trip byte-exact PASS
- U55C `0 B -> PC0`, `64 B -> PC4` remap contract 유지
- `8/8/8` logical TMEM bank interleave가 `0..7,0..7,...` 순서로 유지
- `16/8/8` logical TMEM bank interleave가 `0..15,0..15,...` 순서로 유지
- DMA channel `c`가 `16/8/8`에서 TMEM bank `{c,c+8}`만 접근
- illegal HBM-port/TMEM-bank ownership route 0
- loss, duplicate, reorder, stale response, early completion 0
- full crossbar 없이 ownership class 내부의 restricted interconnect만 elaboration
- 기존 `fpint_gemm` tile-major layout과 device kernel register interface 변경 없음
- `16/8/8`의 bank-conflict 및 total-cycle 결과를 `8/8/8` baseline과 비교해 개선 여부 보고
