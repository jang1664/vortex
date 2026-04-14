# FSDB Terminal Analyzer

Verdi FSDB 유틸리티(`fsdbdebug`, `fsdbextract`, `fsdbreport`)를 래핑한 터미널 기반 파형 분석 도구.
GUI 없이 계층 탐색, 신호 검색, value change 덤프, 성능 metric 계산을 수행한다.

## 실행

```bash
PYTHONPATH=tools python -m fsdb_cli <command> [options]
```

## Python 라이브러리 사용

CLI 없이 notebook / 스크립트에서 바로 import해서 쓸 수 있다.

```python
import sys
sys.path.insert(0, "tools")

import fsdb_cli as fsdb

info = fsdb.info("build/sim/xrtsim_vcs/vcs_cosim.fsdb")
print(info.max_time)

report = fsdb.report(
    "build/sim/xrtsim_vcs/vcs_cosim.fsdb",
    ["/tb/dut/u_core/in_flight"],
    bt="100ns",
    et="10us",
)
events = report.events()

time_unit, residency = fsdb.metric_state(
    "build/sim/xrtsim_vcs/vcs_cosim.fsdb",
    "/tb/dut/u_core/in_flight",
    bt="100ns",
    et="10us",
)

ratio = fsdb.signal_ratio(
    "build/sim/xrtsim_vcs/vcs_cosim.fsdb",
    "/tb/dut/u_core/merger_in_valid",
    "/tb/dut/u_core/in_flight",
    bt="100ns",
    et="10us",
)
```

주요 API:
- `fsdb.info`
- `fsdb.hierarchy`
- `fsdb.find_signals`
- `fsdb.report`
- `fsdb.events`
- `fsdb.load_csv`
- `fsdb.metric_state`
- `fsdb.metric_stall`
- `fsdb.metric_latency`
- `fsdb.active_time`
- `fsdb.active_time_where`
- `fsdb.count_where`
- `fsdb.derive_signal`
- `fsdb.signal_ratio`
- `fsdb.transition_count`
- `fsdb.first_high_window`

## Python 후처리 분석

CLI는 그대로 두고, 복잡한 분석은 Python API에서 `CsvReport` / `Event`를 후처리하는 방식으로 확장할 수 있다.

```python
import sys
sys.path.insert(0, "tools")

import fsdb_cli as fsdb

A = "/tb/dut/signal_a"
B = "/tb/dut/signal_b"

# 1) FSDB에서 직접 읽기
rep = fsdb.report("dump.fsdb", [A, B], bt="100ns", et="10us")
evs = rep.events()

# 2) 이미 저장된 CSV를 다시 불러오기
# rep = fsdb.load_csv("dump.csv")
# evs = rep.events()

# 3) derived signal 추가
evs2 = fsdb.derive_signal(
    evs,
    "A_and_B",
    lambda ev: ev.values.get(A, "0") in ("1", "1'b1")
            and ev.values.get(B, "0") in ("1", "1'b1"),
)

# 4) 조건을 만족한 event 개수
cnt = fsdb.count_where(
    evs2,
    lambda ev: ev.values["A_and_B"] == "1",
)

# 5) 조건이 true였던 총 시간
busy_time = fsdb.active_time_where(
    evs2,
    lambda ev: ev.values["A_and_B"] == "1",
)

# 6) 전이 횟수
rising_cnt = fsdb.transition_count(
    evs2,
    "A_and_B",
    from_values=("0", "1'b0", ""),
    to_values=("1", "1'b1"),
)
```

권장 흐름:
- FSDB -> `report(...)` 또는 `load_csv(...)`
- `CsvReport.events()`로 carried-forward 상태 이벤트 생성
- `derive_signal(...)`, `count_where(...)`, `active_time_where(...)` 같은 Python 함수로 분석

## 명령어

### `info` — FSDB 메타데이터

```bash
python -m fsdb_cli info <fsdb>
```

FSDB 버전, 시간 범위, scope/신호 수, 시뮬레이터 정보 등을 출력.

### `hier` — 계층 구조 탐색

```bash
python -m fsdb_cli hier <fsdb> [scope] [-l N]
```

- `scope`: 시작 scope 경로 (생략 시 루트)
- `-l N`: 하위 depth (기본 1, 0=무제한)

```bash
# 루트 하위 1단계
python -m fsdb_cli hier dump.fsdb

# 특정 모듈 하위 2단계
python -m fsdb_cli hier dump.fsdb /tb/dut/u_core -l 2
```

### `find` — 신호 검색

```bash
python -m fsdb_cli find <fsdb> <pattern>
```

정규식으로 신호 이름을 검색. 대소문자 무시.

```bash
python -m fsdb_cli find dump.fsdb "clk|reset"
python -m fsdb_cli find dump.fsdb "valid"
python -m fsdb_cli find dump.fsdb "dma_ctrl.*req"
```

### `cut` — FSDB 추출

```bash
python -m fsdb_cli cut <fsdb> -s <scope> [--level N] [-bt T] [-et T] [-o out.fsdb]
```

scope 및 시간 범위로 잘라낸 작은 FSDB를 생성. 대형 FSDB 분석 전 데이터를 줄일 때 사용.

```bash
# scope + time window 추출
python -m fsdb_cli cut dump.fsdb -s /tb/dut/u_core --level 0 -bt 10us -et 20us -o core.fsdb
```

### `events` — Value Change 덤프

```bash
python -m fsdb_cli events <fsdb> -s <sig> [-s <sig2> ...] [-bt T] [-et T] [--csv]
```

지정 신호들의 값 변화를 정렬된 테이블로 출력.

- `--csv`: CSV 형식 출력 (다른 툴로 파이핑할 때 유용)

```bash
# 테이블 출력
python -m fsdb_cli events dump.fsdb \
  -s /tb/dut/req_valid \
  -s /tb/dut/req_ready \
  -bt 100ns -et 1000ns

# CSV 출력
python -m fsdb_cli events dump.fsdb \
  -s /tb/dut/state \
  -bt 0 -et 10us --csv
```

### `metric` — 성능 분석

```bash
python -m fsdb_cli metric <fsdb> <type> [signal options] [-bt T] [-et T]
```

#### `latency` — 핸드셰이크 레이턴시

req rising edge → ack assertion 사이 시간 측정.

```bash
python -m fsdb_cli metric dump.fsdb latency \
  -req /tb/dut/req_valid -ack /tb/dut/req_ready \
  -bt 100ns -et 10us
```

#### `stall` — 스톨 비율

valid=1 && ready=0 구간의 비율.

```bash
python -m fsdb_cli metric dump.fsdb stall \
  -valid /tb/dut/valid -ready /tb/dut/ready \
  -bt 100ns -et 10us
```

#### `state` — FSM State 체류율

각 state 값이 유지된 시간 비율.

```bash
python -m fsdb_cli metric dump.fsdb state \
  -signal /tb/dut/fsm_state \
  -bt 100ns -et 10us
```

## 백엔드 도구 매핑

| 명령어 | 백엔드 | 비고 |
|--------|--------|------|
| `info` | `fsdbdebug -info` | |
| `hier` | `fsdbdebug -scope` | |
| `find` | `fsdbdebug -tree` | |
| `cut` | `fsdbextract` | |
| `events` | `fsdbreport -csv` | `LD_PRELOAD` 자동 적용 |
| `metric` | `fsdbreport -csv` | `LD_PRELOAD` 자동 적용 |

## 파일 구조

```
tools/fsdb_cli/
  __init__.py      # 패키지
  __main__.py      # python -m 진입점
  cli.py           # argparse 서브커맨드
  backends.py      # fsdbdebug/extract/report subprocess 래퍼
  parsers.py       # 백엔드 stdout → structured data 파싱
  analyzers.py     # metric 계산 (latency, stall, state residency)
```

## 요구사항

- Python 3.10+ (표준 라이브러리만 사용)
- Verdi 설치: `fsdbdebug`, `fsdbextract`, `fsdbreport`가 PATH에 있어야 함
- `fsdbreport` 실행에 `/usr/lib/x86_64-linux-gnu/libstdc++.so.6` 필요 (자동 적용)

## 참고 문서

- `/tool/Program/synopsys/verdi/U-2023.03-SP2-9/doc/verdi.pdf`
- `/tool/Program/synopsys/verdi/U-2023.03-SP2-9/doc/reference.pdf`
