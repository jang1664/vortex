# One-Cycle-Early ACC Read Scheduling Derivation

## 1. 목적

이 문서는 2-bank ping-pong accumulation SRAM을 사용하는 GEMM unit에서, read-modify-write 충돌을 피하기 위한 간단한 rule-based scheduling 방식을 유도한다.

목표는 다음과 같다.

- 복잡한 reservation table이나 전역 scheduler를 사용하지 않는다.
- 현재 packet과 pipeline 내부의 특정 과거 packet 하나만 비교한다.
- conflict가 없으면 nominal cycle에 read한다.
- conflict가 있으면 read를 정확히 1 cycle 앞당긴다.
- strict ping-pong bank mapping 조건에서 1-cycle early만으로 충분함을 보인다.

---

## 2. 구조와 가정

각 input packet `i`에 대해 다음을 가정한다.

1. packet `i`는 cycle \(T_i\)에 GEMM unit에 들어온다.
2. input에서 accumulator adder 입력까지의 latency는 \(L_{\mathrm{pre}}\)이다.
3. ACC SRAM read latency는 \(L_R\)이다.
4. accumulator adder latency는 \(L_A\)이다.
5. accumulator output에서 ACC SRAM write input까지의 latency는 \(L_p\)이다.
6. ACC SRAM은 두 개의 single-port bank로 구성된다.
7. packet index에 따라 bank가 교대한다.

\[
b_i = i \bmod 2
\]

8. 한 cycle에는 최대 하나의 packet만 들어온다.
9. packet 순서는 유지된다.
10. accumulation pipeline latency는 고정이며 내부 stall로 write cycle이 변하지 않는다.
11. 각 packet은 대상 bank에 대해 read 1회와 write 1회를 발생시킨다.

---

## 3. Nominal Read Cycle

packet \(i\)가 accumulator adder에 도착하는 cycle은 다음과 같다.

\[
C_A(i)=T_i+L_{\mathrm{pre}}
\]

ACC SRAM read latency가 \(L_R\)이므로, read result가 \(C_A(i)\)에 도착하려면 nominal read request는 다음 cycle에 issue되어야 한다.

\[
R_i^{(0)}
=
C_A(i)-L_R
\]

따라서

\[
\boxed{
R_i^{(0)}
=
T_i+L_{\mathrm{pre}}-L_R
}
\]

이다.

---

## 4. Write Cycle

packet \(j\)의 accumulation result는 accumulator adder와 post-accumulation path를 지난 뒤 ACC SRAM에 write된다.

write cycle은 다음과 같다.

\[
W_j
=
C_A(j)+L_A+L_p
\]

따라서

\[
\boxed{
W_j
=
T_j+L_{\mathrm{pre}}+L_A+L_p
}
\]

이다.

---

## 5. Nominal Read와 Write가 충돌하는 Packet 거리

packet \(i\)의 nominal read와 과거 packet \(j\)의 write가 같은 cycle에 같은 bank를 사용하면 conflict가 발생한다.

cycle conflict 조건은 다음과 같다.

\[
R_i^{(0)}=W_j
\]

각 식을 대입하면

\[
T_i+L_{\mathrm{pre}}-L_R
=
T_j+L_{\mathrm{pre}}+L_A+L_p
\]

양변에서 \(L_{\mathrm{pre}}\)를 제거하면

\[
T_i-T_j
=
L_A+L_p+L_R
\]

다음 상수를 정의한다.

\[
\boxed{
K=L_A+L_p+L_R
}
\]

그러면 packet \(i\)의 nominal read와 같은 cycle에 write하는 packet은 정확히 \(K\) cycle 전에 들어온 packet이다.

\[
\boxed{
T_i-T_j=K
}
\]

즉 nominal read conflict를 확인하기 위해 전체 pipeline을 검사할 필요가 없다.

현재 packet보다 정확히 \(K\) cycle 앞에 들어온 pipeline entry 하나만 확인하면 된다.

---

## 6. Nominal Conflict 조건

현재 packet의 bank를 \(b_i\)라고 하자.

\(K\) cycle 전 pipeline entry의 valid와 bank를 각각 다음과 같이 표시한다.

\[
v_K,\qquad b_K
\]

nominal read conflict 조건은 다음과 같다.

\[
\boxed{
C_i
=
v_K
\land
(b_K=b_i)
}
\]

- \(C_i=0\): nominal cycle에 read 가능
- \(C_i=1\): nominal cycle에 같은 bank write가 있으므로 read를 이동해야 함

---

## 7. One-Cycle-Early Read

nominal cycle이 막혀 있으면 read를 1 cycle 앞당긴다.

\[
R_i^{(1)}
=
R_i^{(0)}-1
\]

따라서

\[
\boxed{
R_i^{(1)}
=
T_i+L_{\mathrm{pre}}-L_R-1
}
\]

이 위치가 다른 과거 packet \(h\)의 write와 충돌하려면 다음 조건이 필요하다.

\[
R_i^{(1)}=W_h
\]

식을 대입하면

\[
T_i+L_{\mathrm{pre}}-L_R-1
=
T_h+L_{\mathrm{pre}}+L_A+L_p
\]

따라서

\[
T_i-T_h
=
L_A+L_p+L_R+1
\]

즉,

\[
\boxed{
T_i-T_h=K+1
}
\]

이다.

따라서 nominal cycle과 one-cycle-early cycle이 모두 write로 막히려면, 현재 packet보다 \(K\) cycle 전과 \(K+1\) cycle 전의 두 packet이 모두 현재 packet과 같은 bank에 write해야 한다.

---

## 8. Ping-Pong Mapping에서 연속 Same-Bank Write가 불가능함

bank mapping은 packet index parity에 따라 결정된다.

\[
b_i=i\bmod2
\]

따라서 서로 다른 두 packet이 같은 bank를 사용하려면 index 차이가 짝수여야 한다.

\[
b_i=b_j
\quad\Longrightarrow\quad
(i-j)\bmod2=0
\]

서로 다른 packet에 대해서는 최소 index 차이가 2이다.

\[
b_i=b_j,\quad i\neq j
\quad\Longrightarrow\quad
|i-j|\geq2
\]

한 cycle에 최대 한 packet만 들어오고 packet 순서가 유지되므로, 같은 bank packet의 input cycle 간격도 최소 2 cycle이다.

\[
b_i=b_j,\quad i\neq j
\quad\Longrightarrow\quad
|T_i-T_j|\geq2
\]

모든 packet의 write latency가 동일하므로 write cycle 간격은 input cycle 간격과 같다.

\[
W_i-W_j=T_i-T_j
\]

따라서 같은 bank의 서로 다른 write 사이에는 최소 2 cycle의 간격이 존재한다.

\[
\boxed{
b_i=b_j,\quad i\neq j
\quad\Longrightarrow\quad
|W_i-W_j|\geq2
}
\]

즉, 동일 bank에 대한 write가 연속된 두 cycle에 발생할 수 없다.

\[
\boxed{
\neg
\left(
\mathrm{write}_b[t]
\land
\mathrm{write}_b[t-1]
\right)
}
\]

---

## 9. 최대 1-Cycle Early로 충분함

현재 packet의 nominal read cycle을 \(t\)라고 하자.

\[
t=R_i^{(0)}
\]

nominal read가 conflict라는 것은 해당 bank에 다음 write가 존재한다는 의미다.

\[
\mathrm{write}_{b_i}[t]=1
\]

같은 bank의 write는 연속된 두 cycle에 존재할 수 없으므로

\[
\mathrm{write}_{b_i}[t-1]=0
\]

이다.

따라서 nominal cycle이 same-bank write로 막혀 있더라도 바로 이전 cycle은 write conflict가 없다.

즉 write conflict만 고려하면 필요한 최대 early shift는 다음과 같다.

\[
\boxed{
E_{\max}=1
}
\]

---

## 10. Read-Read Conflict가 새로 발생하지 않음

같은 bank를 사용하는 두 packet \(i\)와 \(j\)를 생각하자.

same-bank packet의 input cycle 간격은 최소 2이다.

\[
|T_i-T_j|\geq2
\]

nominal read cycle은 input cycle에 동일한 상수 offset을 더한 값이므로 nominal read cycle 간격도 동일하다.

\[
R_i^{(0)}-R_j^{(0)}
=
T_i-T_j
\]

따라서

\[
\left|
R_i^{(0)}-R_j^{(0)}
\right|
\geq2
\]

각 packet의 read는 최대 1 cycle만 앞당겨진다.

\[
R_i=R_i^{(0)}-e_i
\]

\[
e_i\in\{0,1\}
\]

뒤 packet만 1 cycle 당겨지고 앞 packet은 당겨지지 않는 경우가 read 간격을 가장 많이 줄이는 최악의 경우다.

\[
R_i-R_j
=
\left(R_i^{(0)}-R_j^{(0)}\right)
-
(e_i-e_j)
\]

최소 nominal 간격이 2이고 최대 shift 차이가 1이므로

\[
R_i-R_j\geq2-1=1
\]

따라서 같은 bank의 두 read가 같은 cycle에 배치되지는 않는다.

\[
\boxed{
R_i\neq R_j
}
\]

즉 one-cycle-early rule은 새로운 read-read conflict를 만들지 않는다.

---

## 11. 최종 Scheduling Rule

다음 상수를 정의한다.

\[
\boxed{
K=L_A+L_p+L_R
}
\]

현재 packet보다 \(K\) cycle 앞의 pipeline entry를 확인한다.

early-read 여부는 다음과 같다.

\[
\boxed{
e_i
=
v_K
\land
(b_K=b_i)
}
\]

여기서 \(e_i\)는 Boolean 값으로 해석한다.

- 조건이 거짓이면 \(e_i=0\)
- 조건이 참이면 \(e_i=1\)

최종 read issue cycle은 다음과 같다.

\[
\boxed{
R_i
=
T_i+L_{\mathrm{pre}}-L_R-e_i
}
\]

즉 rule은 다음 한 문장으로 정리된다.

> \(K=L_A+L_p+L_R\) cycle 전 packet이 valid이고 현재 packet과 같은 bank를 사용하면 read를 1 cycle 앞당기고, 그렇지 않으면 nominal cycle에 read한다.

---

## 12. RTL 형태

```systemverilog
localparam int K =
    L_A + L_P + L_R;

logic early_read;

assign early_read =
    history_valid[K]
    && (history_bank[K] == input_bank);

assign read_issue_offset =
    L_PRE - L_R - early_read;
```

read request metadata를 pipeline으로 전달한다면 다음처럼 구성할 수 있다.

```systemverilog
typedef struct packed {
    logic                  valid;
    logic                  bank;
    logic [ACC_ADDR_W-1:0] address;
} packet_meta_t;

packet_meta_t history [0:HISTORY_DEPTH-1];
```

매 cycle input metadata를 history에 넣고 shift한다.

```systemverilog
always_ff @(posedge clk) begin
    if (reset) begin
        for (int k = 0; k < HISTORY_DEPTH; k++)
            history[k] <= '0;
    end
    else begin
        history[0] <= input_meta;

        for (int k = 1; k < HISTORY_DEPTH; k++)
            history[k] <= history[k-1];
    end
end
```

현재 packet의 scheduling logic은 `history[K]` entry 하나만 참조한다.

---

## 13. 필요한 History Depth

nominal conflict를 판단하기 위해 확인해야 하는 가장 오래된 packet은 \(K\) cycle 전 packet이다.

따라서 history entry를 현재 cycle input과 별도로 관리한다면 최소 history depth는 다음과 같다.

\[
\boxed{
H_{\mathrm{history}}=K+1
}
\]

index가 다음과 같이 정의된 경우다.

```text
history[0] = 1 cycle 전 packet
history[1] = 2 cycle 전 packet
...
history[K-1] = K cycle 전 packet
```

이 경우 실제 array depth는 \(K\)로도 표현할 수 있다. 구현 시 index 정의에 따라 off-by-one을 주의해야 한다.

핵심적으로 필요한 lookback distance는 다음과 같다.

\[
\boxed{
K=L_A+L_p+L_R
}
\]

---

## 14. FIFO 요구량

conflict가 없으면 read result는 nominal timing에 맞춰 도착한다.

\[
e_i=0
\]

이 경우 별도 대기 시간이 없다.

conflict가 있으면 read를 1 cycle 앞당긴다.

\[
e_i=1
\]

따라서 read result는 accumulator adder가 사용하기 1 cycle 전에 도착한다.

각 bank에서 같은 cycle에 두 early-read result가 생성되지 않고, read 순서도 유지된다는 조건에서는 bank별 depth-1 buffer로 충분하다.

\[
\boxed{
D_{\mathrm{FIFO},b}=1
}
\]

단, same-cycle enqueue/dequeue 처리 방식에 따라 bypass logic 또는 1-entry skid buffer 형태로 구현할 수 있다.

---

## 15. 이 보장이 깨지는 조건

다음 조건 중 하나라도 성립하면 \(E_{\max}=1\) 보장은 다시 검토해야 한다.

### 15.1 한 cycle에 여러 packet이 들어오는 경우

같은 bank에 대응하는 여러 packet이 같은 cycle에 admission될 수 있으면 same-bank write 간격이 1 cycle 미만 또는 동일 cycle이 될 수 있다.

### 15.2 Bank mapping이 strict alternating이 아닌 경우

예를 들어 다음과 같은 bank sequence에서는 same-bank packet이 연속될 수 있다.

```text
0, 0, 1, 1, 0, 0, ...
```

이 경우 같은 bank write가 연속 cycle에 존재할 수 있으므로 2 cycle 이상의 early shift가 필요할 수 있다.

### 15.3 Variable-latency pipeline

pipeline stall이나 replay로 write cycle이 이동하면 동일 bank write 간 최소 간격이 보존되지 않을 수 있다.

### 15.4 Packet reordering

pipeline 내부에서 packet 순서가 바뀌면 index parity와 temporal bank sequence의 관계가 깨질 수 있다.

### 15.5 Read가 bank를 여러 cycle 점유하는 경우

SRAM read request가 1 cycle보다 긴 port occupancy를 요구하면 단순 same-cycle conflict 모델이 성립하지 않는다.

### 15.6 동일 address에 대한 RAW dependency

같은 accumulator address를 연속적으로 갱신하는 경우, bank conflict와 별도로 이전 write 완료 또는 forwarding 여부를 확인해야 한다.

---

## 16. 일반화

same-bank write 사이의 최소 cycle 간격을 \(S_b\)라고 정의하자.

\[
S_b
=
\min_{\substack{i\neq j\\b_i=b_j}}
|W_i-W_j|
\]

현재 strict ping-pong 구조에서는

\[
S_b\geq2
\]

이다.

single-cycle SRAM access에서 nominal cycle이 write로 막혀 있을 때 바로 이전 cycle이 free임을 보장하려면 다음 조건이면 충분하다.

\[
\boxed{
S_b\geq2
}
\]

따라서 strict ping-pong은 이 조건을 만족하는 특수한 경우다.

반대로 같은 bank write가 최대 \(B_{\max}\) cycle 연속될 수 있다면 필요한 최대 early shift는 다음과 같이 bound할 수 있다.

\[
\boxed{
E_{\max}=B_{\max}
}
\]

strict ping-pong에서는

\[
B_{\max}=1
\]

이므로

\[
E_{\max}=1
\]

이다.

---

## 17. 최종 결론

2-bank strict ping-pong accumulation 구조에서 다음 조건이 성립한다고 하자.

- 한 cycle에 최대 한 packet admission
- packet 순서 유지
- bank mapping은 \(b_i=i\bmod2\)
- fixed-latency accumulation pipeline
- single-cycle SRAM read/write port occupancy
- packet당 read 1회와 write 1회

그러면 nominal read와 충돌할 수 있는 packet의 lookback distance는 다음과 같다.

\[
\boxed{
K=L_A+L_p+L_R
}
\]

현재 packet보다 정확히 \(K\) cycle 전 packet 하나만 확인하면 nominal write conflict를 판단할 수 있다.

최종 scheduling rule은 다음과 같다.

\[
\boxed{
R_i
=
T_i+L_{\mathrm{pre}}-L_R
-
\left[
v_K\land(b_K=b_i)
\right]
}
\]

strict ping-pong mapping에서는 same-bank write가 연속 cycle에 존재하지 않으므로, conflict 발생 시 정확히 1 cycle만 read를 앞당기면 충분하다.

\[
\boxed{
E_{\max}=1
}
\]

따라서 복잡한 reservation table 없이 다음 hardware만으로 scheduling을 구현할 수 있다.

1. \(K\)-cycle packet history
2. valid bit 비교
3. bank equality comparator
4. nominal offset에서 Boolean 1을 빼는 간단한 control logic
5. early-read result를 위한 bank별 1-entry buffer
