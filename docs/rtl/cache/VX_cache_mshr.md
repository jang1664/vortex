# `VX_cache_mshr.sv` — MSHR 상세 분석

파일: `hw/rtl/cache/VX_cache_mshr.sv`

## 1. 역할

MSHR (Miss Status Holding Register)는 캐시 miss 시 pending 요청을 저장하고, 메모리 fill이 완료되면 해당 요청들을 순서대로 **replay**하는 모듈입니다.

핵심 특징:
- **Free-list 기반 할당**: 빈 슬롯을 priority encoder로 찾아 할당
- **Linked list 기반 pending chain**: 같은 캐시 라인에 대한 여러 miss를 연결
- **FIFO 순서 보장**: pending 요청은 도착 순서대로 dequeue
- **뱅크 파이프라인과 강하게 결합**: 할당/finalize/dequeue가 파이프라인 스테이지와 동기화

## 2. 파라미터

| 파라미터 | 설명 |
|----------|------|
| `MSHR_SIZE` | 엔트리 수 (기본 4) |
| `DATA_WIDTH` | 저장할 요청 데이터 폭 (wsel + byteen + data + tag + req_idx) |
| `LINE_SIZE`, `NUM_BANKS` | 주소 계산용 |
| `WRITEBACK` | writeback 모드 여부 (pending 판단 로직에 영향) |

## 3. 인터페이스

### Fill (메모리 응답 수신)
```
fill_valid   — fill 응답 유효
fill_id      — fill 대상 MSHR 엔트리 ID (memory tag에서 추출)
fill_addr    — (output) 해당 엔트리의 주소 (태그 갱신에 사용)
```

### Dequeue (Replay 출력)
```
dequeue_valid — replay할 요청이 있음
dequeue_addr  — replay 요청 주소
dequeue_rw    — read/write
dequeue_data  — 저장된 요청 데이터 (wsel, byteen, data, tag, idx)
dequeue_id    — 현재 dequeue 중인 엔트리 ID
dequeue_ready — 뱅크가 replay를 수락
```

### Allocate (새 엔트리 할당)
```
allocate_valid   — 할당 요청 유효
allocate_addr    — 요청 주소
allocate_rw      — read/write
allocate_data    — 저장할 데이터
allocate_id      — (output) 할당된 슬롯 ID
allocate_pending — (output) 같은 라인에 이미 pending 중인 요청 있음
allocate_previd  — (output) pending chain의 이전 엔트리 ID
allocate_ready   — (output) 할당 가능한 빈 슬롯 있음
```

### Finalize (할당 확정/취소)
```
finalize_valid      — finalize 유효
finalize_is_release — 이 엔트리를 release (hit이었으므로 miss가 아님)
finalize_is_pending — 이 엔트리가 pending chain에 추가됨
finalize_id         — 대상 엔트리 ID
finalize_previd     — pending chain에서 이전 엔트리 ID
```

## 4. 내부 자료구조

```systemverilog
reg [CS_LINE_ADDR_WIDTH-1:0] addr_table [0:MSHR_SIZE-1];  // 각 엔트리의 주소
reg [MSHR_ADDR_WIDTH-1:0]    next_index [0:MSHR_SIZE-1];  // linked list: 다음 엔트리 포인터
reg [MSHR_SIZE-1:0]          valid_table;   // 각 엔트리 유효 여부
reg [MSHR_SIZE-1:0]          next_table;    // 각 엔트리에 다음 엔트리가 있는지
reg [MSHR_SIZE-1:0]          write_table;   // 각 엔트리가 write 요청인지

VX_dp_ram mshr_store (...);  // 요청 데이터 저장 (wsel, byteen, data, tag, idx)
```

## 5. 동작 상세

### 5.1 할당 (Allocate)

코어 요청이 뱅크 파이프라인 Stage 0에 진입할 때 호출됩니다.

```
1. Priority encoder가 valid_table_n에서 빈 슬롯(~valid)을 찾아 allocate_id_n 결정
2. addr_matches: valid_table에서 같은 주소를 가진 엔트리 검색
3. allocate_pending = (| addr_matches)  → 이미 같은 라인에 대한 miss가 있음
4. allocate_previd = priority_encoder(addr_matches & ~next_table_x) → pending chain의 tail
5. allocate_fire 시:
   - addr_table[allocate_id] ← allocate_addr
   - write_table[allocate_id] ← allocate_rw
   - valid_table_n[allocate_id] ← 1
   - next_table_n[allocate_id] ← 0  (새 엔트리는 chain의 끝)
   - mshr_store에 allocate_data 기록
```

### 5.2 Finalize

뱅크 파이프라인 Stage 1에서 hit/miss 결정 후 호출됩니다.

```
Case 1: Hit (finalize_is_release = 1)
  - valid_table_n[finalize_id] ← 0  (슬롯 반환)
  - MSHR에서 제거됨

Case 2: Miss, pending 있음 (finalize_is_pending = 1)
  - next_table_x[finalize_previd] ← 1  (이전 엔트리에 next 연결)
  - next_index[finalize_previd] ← finalize_id  (linked list 연결)
  - 이 엔트리는 pending chain에 추가됨
  - fill request는 전송하지 않음 (이미 같은 라인에 대한 fill이 진행중)

Case 3: Miss, pending 없음
  - 엔트리 유지 (valid 상태)
  - fill request 전송 (뱅크 Stage 2에서)
```

### 5.3 Fill + Dequeue (Replay)

메모리 fill 응답이 도착하면 호출됩니다.

```
1. fill_valid 수신:
   - dequeue_val_n ← 1
   - dequeue_id_n ← fill_id  (fill을 트리거한 첫 번째 엔트리)

2. Dequeue 순회 (replay):
   매 사이클 dequeue_fire 시:
   - valid_table_n[dequeue_id] ← 0  (엔트리 release)
   - replay 요청이 뱅크 파이프라인에 재투입
   - if (next_table[dequeue_id]):
       dequeue_id_n ← next_index[dequeue_id]  (다음 pending으로 이동)
     else if (finalize_valid && finalize_is_pending && finalize_previd == dequeue_id):
       dequeue_id_n ← finalize_id  (동시에 도착한 새 pending 처리)
     else:
       dequeue_val_n ← 0  (chain 끝, dequeue 종료)
```

### 5.4 Pending 판단 (Write-Through 특수 처리)

```systemverilog
// Writeback 모드: 모든 pending 엔트리가 pending으로 판단
allocate_pending = |addr_matches;

// Write-through 모드: write 엔트리는 pending에서 제외
// 이유: write-through에서는 write가 독립적으로 메모리에 전송되므로,
// write miss에 대해 fill을 기다릴 필요가 없을 수 있음
allocate_pending = |(addr_matches & ~write_table);
```

## 6. 런타임 검증

```systemverilog
// 이미 사용 중인 슬롯에 할당하지 않는지
RUNTIME_ASSERT(~(allocate_fire && valid_table[allocate_id_r]))

// 유효하지 않은 엔트리를 release하지 않는지
RUNTIME_ASSERT(~(finalize_valid && ~valid_table[finalize_id]))

// 유효하지 않은 엔트리에 fill하지 않는지
RUNTIME_ASSERT(~(fill_valid && ~valid_table[fill_id]))
```

## 7. Linked List 예시

```
상황: 주소 0x100에 대해 3개의 연속 miss 발생

Step 1: 첫 번째 요청 (ID=0)
  valid_table[0]=1, addr_table[0]=0x100, next_table[0]=0
  → pending=0, fill request 전송

Step 2: 두 번째 요청 (ID=1)
  valid_table[1]=1, addr_table[1]=0x100, next_table[1]=0
  → pending=1 (addr_matches[0]=1), previd=0
  → finalize: next_table[0]=1, next_index[0]=1
  Chain: 0 → 1

Step 3: 세 번째 요청 (ID=2)
  valid_table[2]=1, addr_table[2]=0x100, next_table[2]=0
  → pending=1 (addr_matches[0,1]=1), previd=1 (tail)
  → finalize: next_table[1]=1, next_index[1]=2
  Chain: 0 → 1 → 2

Step 4: Fill 도착 (fill_id=0)
  dequeue_id=0 → replay → release → dequeue_id=1 (next_index[0])
  dequeue_id=1 → replay → release → dequeue_id=2 (next_index[1])
  dequeue_id=2 → replay → release → dequeue 종료
```

## 8. 설계 핵심 포인트

1. **Pre-allocation 패턴**: MSHR 슬롯은 tag lookup 전에 할당되고, hit이면 즉시 반환됩니다. 이는 MSHR full 상태에서의 파이프라인 진입을 방지합니다.

2. **finalize_is_pending 최적화**: `finalize_is_pending`은 hit/miss와 무관하게 assert될 수 있습니다. 이는 timing critical path를 줄이기 위한 것으로, 잘못된 next_table 업데이트는 다음 `allocate_fire`에서 초기화됩니다.

3. **뱅크 파이프라인과의 강한 결합**: allocate(Stage 0), finalize(Stage 1), dequeue(Input Select)가 뱅크 파이프라인 스테이지와 정확히 동기화되어야 합니다. 한쪽만 수정하면 동작이 깨질 수 있습니다.

4. **mshr_store**: 실제 요청 데이터(wsel, byteen, data, tag, idx)는 별도 dual-port RAM에 저장됩니다. 이는 control logic(valid_table, next_table 등)과 data storage를 분리하여 SRAM 활용을 최적화합니다.
