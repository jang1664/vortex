# `libs/VX_priority_encoder.sv` — Priority Encoder

## 개요

N비트 입력에서 가장 우선순위가 높은 활성 비트를 찾아 인덱스와 one-hot 인코딩을 출력하는 조합 논리 모듈.

## 모듈 파라미터

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| `N` | 1 | 입력 비트 수 |
| `REVERSE` | 0 | 우선순위 방향: 0=LSB, 1=MSB |
| `MODEL` | 1 | 구현 모델 선택 (0~3) |

## 인터페이스

| 신호 | 방향 | 폭 | 설명 |
|------|------|-----|------|
| `data_in` | input | N | 요청 비트맵 |
| `onehot_out` | output | N | 선택된 비트 (one-hot) |
| `index_out` | output | log2(N) | 선택된 비트 인덱스 |
| `valid_out` | output | 1 | 유효한 비트 존재 여부 |

## 동작 원리

### LSB 우선 (REVERSE=0)

가장 낮은 인덱스의 활성 비트를 선택:

```
data_in = 8'b0101_0100
               ↑
               bit 2 (가장 낮은 활성 비트)

index_out  = 3'd2
onehot_out = 8'b0000_0100
valid_out  = 1
```

### MSB 우선 (REVERSE=1)

가장 높은 인덱스의 활성 비트를 선택:

```
data_in = 8'b0101_0100
           ↑
           bit 6 (가장 높은 활성 비트)

index_out  = 3'd6
onehot_out = 8'b0100_0000
valid_out  = 1
```

## 구현 모델

### MODEL 0: 루프 기반

```systemverilog
always @(*) begin
    for (integer i = N-1; i >= 0; --i) begin
        if (data_in[i]) begin
            index_w  = i;
            onehot_w = 1 << i;
        end
    end
end
```

- 단순한 구현
- 합성 도구가 최적화
- 시뮬레이션에서 명확한 동작

### MODEL 1: Higher Priority Register 체인

```systemverilog
// 자신보다 우선순위 높은 비트가 있는지 추적
higher_pri_regs[0] = 0;
higher_pri_regs[1] = data_in[0];
higher_pri_regs[2] = data_in[0] | data_in[1];
...
higher_pri_regs[i] = OR(data_in[0:i-1]);

// 우선순위 높은 비트가 없는 것만 통과
onehot_out = data_in & ~higher_pri_regs;
```

예시:
```
data_in         = 8'b0101_0100
higher_pri_regs = 8'b0111_1100  (각 위치에서 하위 비트들의 OR)
~higher_pri_regs= 8'b1000_0011
onehot_out      = 8'b0000_0100  (bit 2만 통과)
```

### MODEL 2: Scan 기반

```systemverilog
VX_scan #(.OP("|")) scan (...);  // prefix OR
onehot_out = scan_lo & {(~scan_lo[N-2:0]), 1'b1};
```

- Prefix OR로 첫 번째 1 이후 모든 비트를 1로 설정
- 경계에서 변화하는 지점 감지

### MODEL 3: 2의 보수 트릭

```systemverilog
onehot_out = data_in & -data_in;
```

- 가장 효율적인 구현
- 2의 보수 특성 활용: `-x = ~x + 1`

예시:
```
data_in  = 8'b0101_0100
-data_in = 8'b1010_1100  (2의 보수)
AND      = 8'b0000_0100  (가장 낮은 1비트만 남음)
```

원리:
```
x        = ...1000  (마지막 1과 그 뒤의 0들)
~x       = ...0111
~x + 1   = ...1000  (캐리가 마지막 1 위치까지 전파)
x & -x   = ...1000  (마지막 1비트만 남음)
```

## 특수 케이스 최적화

### N=1

```systemverilog
assign onehot_out = data_in;
assign index_out  = '0;
assign valid_out  = data_in;
```

### N=2

```systemverilog
// LSB 우선
assign onehot_out = {data_in[1] && ~data_in[0], data_in[0]};
assign index_out  = ~data_in[0];
assign valid_out  = (| data_in);
```

## 사용 예시

```systemverilog
VX_priority_encoder #(
    .N       (8),
    .REVERSE (0),    // LSB 우선
    .MODEL   (1)
) encoder (
    .data_in    (requests),
    .index_out  (selected_idx),
    .onehot_out (selected_mask),
    .valid_out  (has_request)
);
```

## 관련 모듈

- [VX_priority_arbiter.sv](VX_priority_arbiter.md) - 이 인코더를 사용하는 중재기
- [VX_lzc.sv](../../../hw/rtl/libs/VX_lzc.sv) - Leading Zero Count
- [VX_find_first.sv](../../../hw/rtl/libs/VX_find_first.sv) - 첫 번째 유효 데이터 찾기
- [VX_scan.sv](../../../hw/rtl/libs/VX_scan.sv) - Prefix 연산

## 타이밍 특성

- 순수 조합 논리 (레지스터 없음)
- 지연: O(log N) ~ O(N), 모델에 따라 다름
- MODEL 3이 가장 빠름 (덧셈기 지연만)
