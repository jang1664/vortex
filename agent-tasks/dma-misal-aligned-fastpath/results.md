# Misaligned DMA Aligned Fast Path and Outstanding-Slot Analysis

## Summary

`VX_dma_unit_misal`에 자연스럽게 64-byte aligned된 구간을 한 cycle에
처리하는 fast path를 추가했다. 기존 16-byte PACK 경로는 misaligned
prefix, 서로 다른 alignment phase, partial tail을 처리하는 fallback으로
유지했다.

대표 generation과 prefill workload 모두 xrt-vcs에서 출력 검증을
통과했다. End-to-end latency는 generation에서 4.04%, prefill에서 3.42%
감소했다.

## Implementation

변경 파일:

- `hw/rtl/core/VX_dma_unit_misal.sv`

Fast transfer width는 DCache와 LMEM bus 폭의 공통 단위로 정의했다.
현재 target configuration에서는 64 bytes이다.

```systemverilog
localparam int FAST_BYTES = MIN_BYTES;
```

Payload fast path는 다음 조건에서 활성화된다.

- Current source slot이 ready 상태이다.
- Source slot lane이 64-byte aligned이다.
- Destination lane이 64-byte aligned이다.
- Slot, payload, segment, destination beat에 각각 64 bytes 이상 남아 있다.

조건을 만족하면 source slot에서 고정된 64-byte half를 선택해 destination
accumulator의 고정된 half에 삽입한다.

- G2L: DCache 64B를 LMEM 128B의 lower 또는 upper half에 삽입
- L2G: LMEM 128B의 lower 또는 upper 64B를 선택해 DCache에 기록
- Padding: aligned 구간이면 64B zero-fill

Fast path가 불가능한 경우 기존 `MISALIGN_PACK_BYTES=16` 경로를 사용한다.
따라서 임의 byte offset을 처리하는 wide barrel shifter는 추가하지 않았다.

## Verification

사용 configuration:

```text
configs/naive_gemm_simd_th16_tcol32_hwexp_dcache.sh
MISALIGN_PACK_BYTES=16
DMA_RD_OUTSTANDING_SLOT=8
```

### Unit Regression

`dma_mem_unit_misal` VCS regression 결과:

| Result | Fast writes observed | Fallback writes observed |
|---:|---:|---:|
| 2,125 / 2,125 PASS | 1,960 | 58,640 |

Test sweep는 완전 aligned transfer, 서로 다른 source/destination offset,
odd-size tail, partial byte enable, padding을 포함한다.

### Integration Performance

| Workload | Previous pipeline | Aligned fast path | Reduction |
|---|---:|---:|---:|
| Generation: `M=1 K=256 N=256` | 14,791 cycles | 14,194 cycles | 4.04% |
| Prefill: `M=1024 K=256 N=256` | 206,863 cycles | 199,796 cycles | 3.42% |

두 workload 모두 output validation에서 `PASSED`를 확인했다.

Fast path가 PACK serialization을 줄이지만, 실제 workload에는 alignment
phase가 다른 transfer와 PACK 외부 대기가 남아 있어 전체 개선은 3-4%
수준이다.

## Outstanding-Slot Storage

Target configuration은 다음과 같은 source bus 폭을 사용한다.

- DCache: 64 bytes
- LMEM aggregate: 128 bytes
- Slot payload width: 128 bytes, 1,024 bits

Depth별 저장량은 다음과 같다.

| Outstanding slots | Payload | State/lane/remaining | Total slot arrays |
|---:|---:|---:|---:|
| 2 | 2,048 bits | 36 bits | 2,084 bits |
| 4 | 4,096 bits | 72 bits | 4,168 bits |
| 8 | 8,192 bits | 144 bits | 8,336 bits |

Depth 8에서는 payload가 slot storage의 98.3%를 차지한다.

현재 `slot_data_r`에는 다음 특성이 있다.

- Global reset에서 모든 entry를 zero clear한다.
- 새 DMA command 시작 시 모든 entry를 다시 zero clear한다.
- Response마다 전체 word를 zero clear한 후 bus-width slice를 기록한다.
- Writer가 `wr_expect_slot_r`로 비동기 indexed read한다.

기존 Synopsys mapped-area report에는 `slot_data_r_reg_*` clock gate가
나타나고 해당 DMA hierarchy 아래 RAM macro가 없다. 따라서 이 coding
pattern은 register array로 합성된 것으로 판단된다. 보유 report는 이전
slot-depth 설계이므로 현재 depth-8의 정확한 cell count를 얻으려면 새
synthesis가 필요하다.

기존 U55C utilization snapshot의 DMA category는 71,977 FF, 전체
Vortex는 402,181 FF이다. Depth-8 slot array 8,336 bits가 모두 FF로
구현된다고 보면 DMA FF의 약 11.6%, 전체 Vortex FF의 약 2.1%에 해당한다.

## U55C Recommendation

최종 PnR target은 Xilinx Alveo U55C이다. 깊이 8, 폭 1,024-bit인 배열을
BRAM이나 URAM으로 직접 구현하면 필요한 read width를 만들기 위해 여러
memory block을 병렬로 사용해야 하고 대부분의 depth가 낭비된다.

### Experiment 1: Resetless Distributed RAM

첫 번째 권장 실험은 다음과 같다.

1. `slot_data_r`의 reset 및 command-start clear를 제거한다.
2. Response 데이터를 zero-extended 1,024-bit word로 만든다.
3. Response당 payload array에 한 번만 full-word write한다.
4. 비동기 head read를 유지한다.
5. `ram_style="distributed"`를 지정해 LUTRAM 추론을 유도한다.

Slot state가 유효성을 관리하므로 stale payload는 읽히지 않는다. 이
방식은 tagged out-of-order response write와 한 cycle 64B fast read를
유지할 수 있다.

현재 FF 구현과 resetless LUTRAM 구현은 다음 항목으로 비교해야 한다.

- LUT
- FF
- BRAM/URAM
- WNS/Fmax
- 64B fast move throughput

### Experiment 2: Direction-Aware 64B Banks

추가 절감이 필요하면 payload를 64-byte bank 단위로 구성할 수 있다.

```text
G2L: DCache slot 0..7 -> 64B bank 0..7

L2G: LMEM slot 0 -> bank 0 + bank 1
     LMEM slot 1 -> bank 2 + bank 3
```

G2L은 eight outstanding slots를 유지하고, L2G은 현재 tag width가
지원하는 two outstanding slots를 유지한다. 두 방향이 동일한 eight
physical banks를 공유하므로 payload capacity는 8,192 bits에서 4,096
bits로 감소한다.

다만 distributed RAM에서는 매우 얕은 memory의 LUT packing 특성 때문에
저장 bit 수가 절반이 되어도 실제 LUT 사용량이 정확히 절반이 된다고
보장할 수 없다. 따라서 direction-aware banking은 두 번째 synthesis
experiment로 두는 것이 적절하다.

### State Metadata

2-bit slot state, lane, remaining metadata는 depth 8에서도 144 bits에
불과하다. 이를 ready bitmap 등으로 줄이는 것은 가능하지만 전체 자원에
미치는 영향은 작다. Payload mapping을 먼저 최적화해야 한다.

### Response Ordering Constraint

Tagged response slot을 작은 ordered FIFO로 대체해서는 안 된다. Cache와
memory response가 out of order로 도착할 수 있기 때문에 non-head response를
막으면 head response까지 진행하지 못하는 deadlock이 발생할 수 있다.

## Conclusion

64-byte aligned fast path는 기능 회귀를 유지하면서 generation과 prefill
latency를 각각 4.04%, 3.42% 줄였다. 다음 최적화는 U55C에 맞춰
`slot_data_r`를 resetless distributed RAM으로 추론시키는 A/B synthesis가
우선이다. BRAM/URAM 강제 매핑은 현재의 shallow-wide storage 형태에는
적합하지 않다.
