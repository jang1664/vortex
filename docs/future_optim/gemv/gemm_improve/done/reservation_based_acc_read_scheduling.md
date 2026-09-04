# Reservation-Based ACC Memory Read Scheduling

## 1. 목적

이 문서는 backpressure 없이 동작하는 GEMM accumulation unit을 위한 **reservation 기반 ACC memory read scheduling 방식**을 정리한다.

대상 구조는 다음 특성을 가진다.

- accumulation SRAM은 두 개의 single-port bank로 구성된다.
- 두 bank는 ping-pong 방식으로 사용된다.
- input index가 `i`일 때, 예를 들어 `i = 0`은 bank 0, `i = 1`은 bank 1에 대응한다.
- accumulation은 read-modify-write 방식으로 수행된다.
- 한 bank가 write를 수행하는 동안 다른 bank에서 다음 accumulation operand를 미리 read한다.
- input이 back-to-back으로 들어오지 않거나 pipeline에 bubble이 존재하면 read와 write가 같은 bank의 같은 cycle에 충돌할 수 있다.
- input이 들어온 뒤 accumulator adder에 도착하기까지 `L_pre` cycle이 있으므로, 이 구간에서 read issue cycle을 결정할 수 있다.

복잡한 ILP나 전역 최적화 없이, 각 bank별로 작은 reservation table과 priority encoder만 사용하여 read를 스케줄링하는 것이 목표다.

---

## 2. Pipeline Timing Model

input `i`가 cycle `T_i`에 GEMM unit으로 들어온다고 하자.

### 2.1 Adder 도착 시점

input에서 accumulator adder까지의 latency를 `L_pre`라고 하면 input `i`가 adder에 도착하는 cycle은 다음과 같다.

\[
C_A(i) = T_i + L_{\mathrm{pre}}
\]

### 2.2 Read deadline

ACC SRAM의 read latency를 `L_R`이라고 하자.

read 결과가 cycle `C_A(i)`에 accumulator adder에 도착하려면 read는 늦어도 다음 cycle에 issue되어야 한다.

\[
D_i = C_A(i) - L_R
\]

따라서

\[
D_i = T_i + L_{\mathrm{pre}} - L_R
\]

이다.

input 도착 cycle을 기준으로 한 상대 read deadline을 다음과 같이 정의한다.

\[
\Delta_R = L_{\mathrm{pre}} - L_R
\]

그러면 read issue cycle `R_i`의 허용 범위는 다음과 같다.

\[
T_i \leq R_i \leq T_i + \Delta_R
\]

`L_pre < L_R`이면 input이 관찰된 뒤 read를 issue해서 deadline을 맞출 수 없으므로, reservation 방식이 성립하려면 기본적으로 다음 조건이 필요하다.

\[
L_{\mathrm{pre}} \geq L_R
\]

### 2.3 Write 시점

accumulator adder latency를 `L_A`, accumulator output에서 ACC SRAM input까지의 latency를 `L_p`라고 하자.

input `i`의 accumulation 결과가 SRAM에 write되는 cycle은 다음과 같다.

\[
W_i = C_A(i) + L_A + L_p
\]

즉,

\[
W_i = T_i + L_{\mathrm{pre}} + L_A + L_p
\]

이다.

input 도착 시점을 기준으로 한 상대 write offset은 다음과 같다.

\[
\Delta_W = L_{\mathrm{pre}} + L_A + L_p
\]

---

## 3. Online Scheduling이 가능한 이유

read scheduling window의 마지막 cycle은 `T_i + Delta_R`이고, 해당 operation의 write는 `T_i + Delta_W`에 발생한다.

두 offset의 차이는 다음과 같다.

\[
\Delta_W - \Delta_R
=
L_A + L_p + L_R
\]

일반적으로 모든 latency가 0 이상이고 SRAM read latency가 양수이므로,

\[
\Delta_W > \Delta_R
\]

이다.

현재 cycle `T_i`에 관찰한 request의 read scheduling window는 다음과 같다.

\[
[T_i,\; T_i+\Delta_R]
\]

반면 미래 cycle `T_j > T_i`에 들어올 request의 write는 최소한 다음 cycle에 발생한다.

\[
T_j+\Delta_W
\]

그리고

\[
T_j+\Delta_W > T_i+\Delta_R
\]

이므로, 미래에 들어올 request의 write가 현재 request의 read scheduling window를 뒤늦게 침범하지 않는다.

따라서 현재 pipeline과 reservation table에 이미 존재하는 write 정보만 이용해 현재 request의 read issue cycle을 확정할 수 있다.

---

## 4. Bank별 Reservation Table

각 ACC SRAM bank마다 미래 cycle의 read/write 점유 상태를 기록하는 reservation table을 둔다.

bank `b`에 대해 다음 상태를 유지한다.

```text
read_reserved_b[k]
write_reserved_b[k]
```

여기서 `k`는 현재 cycle로부터의 상대 offset이다.

```text
k = 0 : 현재 cycle
k = 1 : 다음 cycle
k = 2 : 2 cycle 후
...
```

### 4.1 Reservation horizon

새 input의 write는 항상 `Delta_W` cycle 후에 발생하므로 reservation horizon은 최소한 다음 크기를 가져야 한다.

\[
H = \Delta_W + 1
\]

즉, bank별 write reservation bitmap은 일반적으로 다음 범위를 가진다.

```text
write_reserved_b[0 : Delta_W]
```

read scheduling에는 `0`부터 `Delta_R`까지의 slot만 필요하다.

```text
read_reserved_b[0 : Delta_R]
```

구현을 단순화하기 위해 read와 write reservation을 모두 `0 : Delta_W` 크기로 통일할 수도 있다.

---

## 5. Read Scheduling Algorithm

새 request `i`가 cycle `T_i`에 들어오고 대상 bank가 `b_i`라고 하자.

### 5.1 Write reservation 생성

해당 request의 write는 `Delta_W` cycle 후 발생하므로 다음 slot을 예약한다.

```text
write_reserved[b_i][Delta_W] = 1
```

write address나 operation tag가 필요한 경우 해당 metadata도 함께 저장한다.

### 5.2 Read 후보 slot 생성

read가 issue될 수 있는 offset은 다음 범위다.

\[
0 \leq k \leq \Delta_R
\]

single-port SRAM에서는 같은 cycle에 read와 write를 동시에 수행할 수 없으므로 각 slot의 사용 가능 여부는 다음과 같다.

\[
\mathrm{free}_{b_i}[k]
=
\neg \mathrm{read\_reserved}_{b_i}[k]
\land
\neg \mathrm{write\_reserved}_{b_i}[k]
\]

RTL 관점에서는 다음 bitmap 연산으로 계산할 수 있다.

```verilog
candidate =
    ~(read_reserved[DELTA_R:0]
    | write_reserved[DELTA_R:0]);
```

### 5.3 Latest-free slot 선택

read 결과의 FIFO 대기 시간을 줄이기 위해 가능한 slot 중 가장 늦은 slot을 선택한다.

\[
k_i
=
\max
\left\{
k \mid
0 \leq k \leq \Delta_R,\;
\mathrm{free}_{b_i}[k] = 1
\right\}
\]

실제 read issue cycle은 다음과 같다.

\[
R_i = T_i + k_i
\]

hardware에서는 `candidate` bitmap에 대해 MSB-priority encoder를 적용하면 된다.

```verilog
issue_offset = highest_set_bit(candidate);
```

선택된 slot에는 read reservation과 read request metadata를 기록한다.

```verilog
read_reserved[issue_offset] <= 1'b1;

read_schedule[issue_offset] <= '{
    valid:   1'b1,
    address: acc_address,
    tag:     request_tag
};
```

---

## 6. Latest-Free 정책을 사용하는 이유

read를 offset `k_i`에 issue하면 read 결과가 나오는 cycle은 다음과 같다.

\[
T_i + k_i + L_R
\]

해당 결과가 accumulator adder에서 소비되는 cycle은 다음과 같다.

\[
T_i + L_{\mathrm{pre}}
\]

따라서 read result가 buffer에서 기다리는 시간은 다음과 같다.

\[
H_i
=
L_{\mathrm{pre}} - (k_i + L_R)
\]

`Delta_R = L_pre - L_R`이므로,

\[
H_i = \Delta_R - k_i
\]

이다.

즉, `k_i`를 크게 선택할수록 read result의 대기 시간이 감소한다.

따라서 가능한 가장 늦은 slot을 선택하는 latest-free 정책은 다음 장점을 가진다.

- read result FIFO의 평균 체류 시간을 줄인다.
- 동시에 FIFO에 머무는 result 수를 줄이는 방향으로 동작한다.
- scheduling logic이 bitmap과 priority encoder로 단순화된다.
- 이미 예약된 read/write만 고려하면 되므로 online scheduling이 가능하다.

---

## 7. Cycle-by-Cycle 동작

각 cycle에는 다음 동작을 수행한다.

### 7.1 현재 cycle의 memory operation 실행

각 bank에 대해 `slot 0`의 operation을 실행한다.

```text
read_schedule[b][0].valid = 1
    -> ACC SRAM read issue

write_schedule[b][0].valid = 1
    -> ACC SRAM write issue
```

올바른 reservation이 이루어졌다면 single-port bank에서 read와 write가 동시에 valid가 되는 경우는 없어야 한다.

### 7.2 Reservation table shift

현재 cycle의 operation을 수행한 뒤 모든 entry를 한 칸씩 shift한다.

```text
slot[0] <- slot[1]
slot[1] <- slot[2]
...
slot[H-2] <- slot[H-1]
slot[H-1] <- empty
```

SystemVerilog 형태의 예시는 다음과 같다.

```verilog
for (int k = 0; k < H-1; k++) begin
    read_schedule[k]  <= read_schedule[k+1];
    write_schedule[k] <= write_schedule[k+1];
end

read_schedule[H-1]  <= '0;
write_schedule[H-1] <= '0;
```

새 request의 reservation은 shift와 같은 cycle에 반영되므로, nonblocking assignment ordering과 next-state logic을 명확히 정의해야 한다.

권장 방식은 combinational next-state를 먼저 계산한 뒤 한 번에 register에 반영하는 것이다.

---

## 8. Pipeline Stage 정보와 Reservation의 관계

fixed-latency pipeline이라면 input이 들어오는 시점에 read와 write cycle을 모두 알 수 있다.

따라서 각 pipeline stage를 매 cycle 스캔하여 write conflict를 계산하기보다, input admission 시점에 미래 write를 reservation table에 기록하는 방식이 단순하다.

```text
input admission
    |
    +-- reserve read slot within [0, Delta_R]
    |
    +-- reserve write slot at Delta_W
```

pipeline 내부에서는 operation과 함께 다음 metadata만 전달하면 된다.

```text
valid
bank
accumulator address
request tag
```

variable latency나 내부 stall이 존재한다면 고정 offset reservation이 깨질 수 있다. 이 경우에는 다음 중 하나가 필요하다.

1. accumulation 관련 pipeline을 stall-free fixed-latency로 유지한다.
2. pipeline stall과 함께 reservation entry도 동일하게 이동시킨다.
3. write stage에서 실제 도착 정보를 기반으로 reservation을 갱신한다.
4. elastic pipeline을 사용하되 operation의 예정 write cycle이 변경되지 않도록 별도의 buffering을 둔다.

backpressure 없는 구조를 목표로 한다면 accumulation pipeline 자체를 fixed-latency로 만드는 것이 가장 단순하다.

---

## 9. Read Schedule Entry

read request는 즉시 issue되는 것이 아니라 미래 cycle에 예약될 수 있으므로 reservation bitmap 외에 metadata 저장 공간이 필요하다.

예를 들어 각 slot은 다음 정보를 가진다.

```systemverilog
typedef struct packed {
    logic                  valid;
    logic [ACC_ADDR_W-1:0] address;
    logic [TAG_W-1:0]      tag;
} read_schedule_entry_t;
```

bank별 schedule table은 다음과 같이 구성할 수 있다.

```systemverilog
read_schedule_entry_t read_schedule [NUM_BANKS][READ_HORIZON];
```

`read_schedule[b][0]`가 해당 cycle의 ACC SRAM read port를 구동한다.

---

## 10. Scheduling Failure

다음 조건이면 read를 deadline 내에 배치할 수 없다.

\[
\mathrm{free}_{b_i}[k] = 0
\qquad
\forall k \in [0,\Delta_R]
\]

RTL에서는 다음과 같이 검출할 수 있다.

```verilog
schedule_fail = ~(|candidate);
```

backpressure를 허용하지 않는다면 `schedule_fail`은 정상 동작 중 절대 발생하지 않아야 한다.

이를 보장하는 방법은 다음과 같다.

- input bank pattern을 제한한다.
- bank당 cycle당 유입 request 수를 제한한다.
- `L_pre`를 늘려 read scheduling window를 확장한다.
- accumulation SRAM bank 수를 늘린다.
- true dual-port 또는 1R1W SRAM을 사용한다.
- read request를 위한 별도 replica SRAM을 사용한다.
- 동일 accumulator address에 대한 forwarding을 지원한다.

설계 검증 시에는 assertion을 두는 것이 좋다.

```systemverilog
assert property (@(posedge clk)
    input_valid |-> !schedule_fail
);
```

---

## 11. 여러 Request가 같은 Cycle에 들어오는 경우

한 cycle에 bank당 최대 한 request만 들어온다면 bank별 priority encoder 하나로 충분하다.

한 cycle에 여러 request가 같은 bank를 요청할 수 있다면 free bitmap을 반복적으로 갱신해야 한다.

두 request를 같은 cycle에 배치하는 예시는 다음과 같다.

```text
free_0   = ~(read_reserved | write_reserved)
offset_0 = latest_one(free_0)

free_1   = free_0 with offset_0 cleared
offset_1 = latest_one(free_1)
```

RTL 개념 예시는 다음과 같다.

```verilog
candidate_0 = ~(read_reserved | write_reserved);
grant_0     = highest_onehot(candidate_0);

candidate_1 = candidate_0 & ~grant_0;
grant_1     = highest_onehot(candidate_1);
```

lane 수가 많으면 cascaded priority encoder의 combinational delay가 길어질 수 있다.

가능한 대안은 다음과 같다.

- input routing 단계에서 bank당 최대 한 request만 허용한다.
- bank별 pending request queue를 둔다.
- scheduling logic을 pipeline화한다.
- parallel prefix 또는 hierarchical allocator를 사용한다.

---

## 12. Read Result Buffer

예약된 read가 deadline보다 일찍 수행되면 read result를 adder 도착 시점까지 보관해야 한다.

request `i`의 result enqueue cycle은 다음과 같다.

\[
E_i = T_i + k_i + L_R
\]

dequeue 또는 consume cycle은 다음과 같다.

\[
C_i = T_i + L_{\mathrm{pre}}
\]

result가 buffer를 점유하는 구간은 다음과 같다.

\[
[E_i,\; C_i)
\]

cycle `t`에서 bank `b`의 buffer occupancy는 다음과 같다.

\[
Q_b(t)
=
\left|
\left\{
i \mid
b_i=b,\;
E_i \leq t < C_i
\right\}
\right|
\]

필요한 FIFO depth는 다음과 같다.

\[
D_b = \max_t Q_b(t)
\]

latest-free 정책은 각 `E_i`를 가능한 늦게 이동시키므로 FIFO occupancy를 줄이는 방향으로 동작한다.

### 12.1 보수적인 depth 상한

bank당 한 cycle에 최대 하나의 read result만 생성되고 최대 대기 시간이 `Delta_R`이라면 보수적으로 다음 depth를 사용할 수 있다.

\[
D_{\mathrm{FIFO},b}
\leq
\Delta_R + 1
\]

따라서 초기 설계에서는 다음 값을 안전한 상한으로 사용할 수 있다.

\[
D_{\mathrm{FIFO},b}
=
L_{\mathrm{pre}} - L_R + 1
\]

다만 실제 최소 depth는 input pattern과 reservation 결과를 cycle simulation하여 구하는 것이 정확하다.

### 12.2 FIFO ordering 조건

일반 FIFO를 사용하려면 read result의 생성 순서와 adder에서의 소비 순서가 같아야 한다.

latest-free scheduling이 request 순서를 뒤집을 수 있다면 다음 중 하나가 필요하다.

- same-bank request 간 read issue 순서를 유지한다.
- result에 tag를 붙이고 tag-indexed buffer를 사용한다.
- consume cycle별 slot을 가진 delay buffer를 사용한다.
- 작은 reorder buffer를 사용한다.

fixed-latency input pipeline과 순서 보존 scheduling을 사용한다면 bank별 FIFO로 구현할 수 있다.

---

## 13. Same-Address Dependency

서로 다른 input이 같은 accumulator address를 갱신할 수 있다면 read-after-write dependency를 고려해야 한다.

request `i`와 이전 request `j`가 같은 accumulator address를 사용한다고 하자.

이전 accumulation result가 SRAM에 write되기 전에 다음 read를 수행하면 stale value를 읽게 된다.

forwarding이 없다면 다음 조건이 필요하다.

\[
R_i > W_j
\]

따라서 request별 earliest read offset을 추가할 수 있다.

\[
k_i \geq k_{\min,i}
\]

최종 후보 범위는 다음과 같다.

\[
k_{\min,i} \leq k \leq \Delta_R
\]

free bitmap은 하위 invalid slot을 mask하여 생성한다.

```verilog
candidate =
    ~(read_reserved | write_reserved)
    & release_mask;
```

동일 address에 대한 accumulator forwarding을 지원하면 SRAM write 완료를 기다리지 않고 pipeline result를 직접 사용할 수 있다.

forwarding은 다음 효과가 있다.

- same-address RAW dependency 완화
- read request 수 감소
- reservation 충돌 감소
- FIFO depth 감소 가능
- backpressure-free 조건 완화

---

## 14. 추천 Hardware 구조

```text
                         Input Request
                               |
                 +-------------+-------------+
                 |                           |
                 v                           v
          Bank Selection              Write Reservation
                 |                      at offset Delta_W
                 v
       Read Candidate Generation
    ~(read_reserved | write_reserved)
                 |
                 v
       Latest-Free Priority Encoder
                 |
                 v
       Read Schedule Slot Allocation
                 |
          +------+------+
          |             |
          v             v
      ACC Bank 0     ACC Bank 1
          |             |
          v             v
    Read Result FIFO / Tagged Buffer
          \             /
           \           /
            v         v
         Accumulator Adder
                 |
              L_A + L_p
                 |
             ACC SRAM Write
```

bank별 scheduler는 다음 요소로 구성된다.

- read reservation bitmap
- write reservation bitmap
- read schedule metadata array
- latest-one priority encoder
- scheduling failure detector
- read result FIFO 또는 tagged buffer

---

## 15. Parameter Summary

| Parameter | 의미 |
|---|---|
| `L_pre` | input admission부터 accumulator adder 입력까지의 latency |
| `L_R` | ACC SRAM read latency |
| `L_A` | accumulator adder latency |
| `L_p` | accumulator output부터 ACC SRAM write input까지의 latency |
| `Delta_R` | read scheduling deadline offset, `L_pre - L_R` |
| `Delta_W` | write reservation offset, `L_pre + L_A + L_p` |
| `H` | reservation horizon, 일반적으로 `Delta_W + 1` |
| `k_i` | request `i`에 선택된 read issue offset |
| `R_i` | 실제 read issue cycle, `T_i + k_i` |
| `W_i` | 실제 write cycle, `T_i + Delta_W` |

---

## 16. Core Equations

read scheduling window:

\[
\boxed{
0 \leq k_i \leq L_{\mathrm{pre}} - L_R
}
\]

write reservation offset:

\[
\boxed{
\Delta_W =
L_{\mathrm{pre}} + L_A + L_p
}
\]

free slot:

\[
\boxed{
\mathrm{free}_b[k]
=
\neg \mathrm{read\_reserved}_b[k]
\land
\neg \mathrm{write\_reserved}_b[k]
}
\]

latest-free scheduling:

\[
\boxed{
k_i
=
\max
\left\{
k \in [0,L_{\mathrm{pre}}-L_R]
\mid
\mathrm{free}_{b_i}[k]=1
\right\}
}
\]

read result waiting time:

\[
\boxed{
H_i =
L_{\mathrm{pre}} - L_R - k_i
}
\]

보수적인 FIFO depth:

\[
\boxed{
D_{\mathrm{FIFO},b}
=
L_{\mathrm{pre}} - L_R + 1
}
\]

---

## 17. Pseudocode

```text
Constants:
    DELTA_R = L_pre - L_R
    DELTA_W = L_pre + L_A + L_p
    H       = DELTA_W + 1

State per bank:
    read_schedule[0 : H-1]
    write_schedule[0 : H-1]

Every cycle:

    1. Execute slot 0
       if read_schedule[0].valid:
           issue ACC SRAM read

       if write_schedule[0].valid:
           issue ACC SRAM write

    2. Shift reservation tables
       for k = 0 to H-2:
           read_schedule[k]  = read_schedule[k+1]
           write_schedule[k] = write_schedule[k+1]

       clear slot H-1

    3. For each newly admitted request i:
       b = target bank

       reserve write_schedule[b][DELTA_W]

       busy =
           read_valid_bitmap[b][0 : DELTA_R]
           OR
           write_valid_bitmap[b][0 : DELTA_R]

       candidate = NOT busy

       if candidate == 0:
           scheduling failure
       else:
           k = highest set bit of candidate
           reserve read_schedule[b][k]
           store read address and request tag
```

---

## 18. Verification Checklist

다음 항목을 RTL simulation과 formal assertion으로 확인하는 것이 좋다.

- 같은 bank에서 read와 write가 같은 cycle에 동시에 발생하지 않는다.
- 두 read가 같은 bank의 같은 cycle에 예약되지 않는다.
- 모든 read가 `C_A - L_R` 이전에 issue된다.
- read result가 해당 input의 adder 도착 cycle까지 보존된다.
- FIFO underflow와 overflow가 발생하지 않는다.
- scheduling failure가 허용된 input pattern에서 절대 발생하지 않는다.
- 같은 accumulator address의 RAW dependency가 보존된다.
- reservation shift와 신규 allocation이 같은 cycle에 정확히 처리된다.
- reset 이후 모든 reservation valid bit가 0이다.
- pipeline bubble이 발생해도 write reservation과 실제 write가 일치한다.

예시 assertion:

```systemverilog
assert property (@(posedge clk)
    !(acc_read_en[b] && acc_write_en[b])
);

assert property (@(posedge clk)
    input_valid |-> candidate_nonzero
);

assert property (@(posedge clk)
    read_result_valid |-> result_buffer_ready
);
```

---

## 19. 결론

reservation 기반 scheduling은 각 request의 read를 deadline 이전의 가장 늦은 빈 cycle에 배치한다.

이 방식은 다음의 간단한 logic으로 구현할 수 있다.

1. bank별 read/write reservation bitmap
2. free-slot bitmap 생성
3. latest-one priority encoder
4. 미래 read metadata schedule table
5. 조기 read result를 위한 FIFO 또는 tagged buffer

fixed-latency pipeline이라는 조건에서 미래 request의 write는 현재 request의 read window를 침범하지 않으므로, 복잡한 전역 scheduling 없이 online greedy allocation이 가능하다.

핵심 scheduling 식은 다음과 같다.

\[
\boxed{
k_i
=
\max
\left\{
k \in [0,L_{\mathrm{pre}}-L_R]
\mid
\text{bank } b_i
\text{가 cycle } T_i+k \text{에 free}
\right\}
}
\]
