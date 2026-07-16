# DMA 최적화 실험 규칙

Created: 2026-07-17

- 적용 대상: aligned DMA, misaligned DMA 및 관련 request/response buffer
- 목적: 각 구조 변경의 기능, 자원 사용량, timing 영향을 재현 가능하게 비교
- 원칙: 이전 실험 결과를 덮어쓰지 않고 모든 구조 변경을 독립된 실험으로 기록

## 필수 규칙

### 1. 구조 변경 전 현재 RTL을 백업한다

Bug fix가 아닌 datapath, storage, pipeline, handshake 또는 module hierarchy의 실제 구조를 변경할 때는 수정 전에 기존 파일을 백업한다.

- 백업은 RTL을 수정하기 전에 만든다.
- 변경할 모든 기존 파일을 백업한다.
- 백업은 원래 repo-relative 경로를 보존한다.
- Git history나 현재 working-tree diff만으로 백업을 대체하지 않는다.
- 새로 추가하는 파일은 백업 대신 experiment manifest에 `new file`로 기록한다.
- Bug fix와 구조 변경이 섞여 있으면 구조 변경 실험으로 취급하고 백업한다.
- 동일한 설계를 다시 실험하더라도 이전 experiment directory를 덮어쓰지 않는다.

### 2. 테스트는 unittest 이후 `xrt-vcs-sim` 순서로 실행한다

각 단계는 gate다. 앞 단계가 실패하면 다음 단계로 진행하지 않는다.

```text
relevant RTL unittest
        |
        | PASS
        v
xrt-vcs-sim blackbox
        |
        | PASS
        v
Vivado OOC synthesis
```

- 먼저 변경된 DMA 경로를 직접 검증하는 unittest를 실행한다.
- Misaligned DMA 변경에는 misalignment, width conversion, padding, partial beat, backpressure case를 포함한다.
- Unittest가 통과한 뒤 configure된 build directory에서 `ci/run_black.sh xrt-vcs-sim`을 사용한다.
- Simulation과 synthesis 전에 해당 실험의 `configs/` 설정을 source한다.
- Unittest 및 blackbox test의 command, config, app, arguments, 결과와 log 경로를 manifest에 기록한다.
- 실패한 실험도 삭제하지 않고 `FAIL` 상태와 실패 log를 보존한다.
- Test failure를 resource 개선 결과로 상쇄하지 않는다. 기능 검증을 통과하지 못한 합성 결과는 채택 후보가 아니다.

### 3. 자원 비교는 Vivado Out-of-Context synthesis로 수행한다

DMA 구조 변경의 1차 resource 평가는 Vivado OOC synthesis 결과를 사용한다.

- `synth_design -mode out_of_context`를 사용한다.
- 기존 `hw/syn/xilinx/dut/project.tcl`의 OOC 설정과 hierarchical `report_utilization` 방식을 따른다.
- DMA 전용 OOC top 또는 wrapper를 사용하고 비교하는 모든 실험에서 동일한 top을 유지한다.
- Device part, Vivado version, RTL defines, parameters, include list, clock constraint와 synthesis option을 고정한다.
- 기준 device는 별도 변경 사유가 없으면 `xcu55c-fsvh2892-2L-e`를 사용한다.
- Resource 비교의 primary report는 post-synthesis hierarchical utilization report다.
- Timing summary도 함께 저장하여 LUT/FF 감소가 큰 combinational path 악화와 바뀌지 않았는지 확인한다.
- OOC top, config 또는 tool version이 달라진 결과는 같은 표에서 직접 비교하지 않는다.

OOC synthesis가 통과해도 전체 design의 placement와 routing 결과를 보장하지 않는다. 채택 후보는 이후 전체 XRT synthesis에서 hierarchy 이동, BRAM column congestion과 WNS를 다시 확인한다.

### 4. 모든 report를 저장하고 직전 design 및 고정 baseline과 비교한다

새로운 구조를 실험할 때마다 raw report와 요약 결과를 새로운 experiment directory에 저장한다.

- Raw Vivado report를 수정하거나 요약 파일로 대체하지 않는다.
- 직전 design과 비교한다.
- 최초 baseline과도 비교하여 여러 단계의 누적 효과를 확인한다.
- 이전 experiment directory와 report를 덮어쓰지 않는다.
- 실패하거나 채택하지 않은 design도 비교 이력으로 보존한다.
- 수치가 동일하더라도 report와 comparison을 남긴다.

## Experiment ID와 저장 위치

각 구조 실험은 다음 ID를 사용한다.

```text
YYYYMMDD-NNN-short-name
```

예:

```text
20260717-001-misal-response-sram
20260717-002-misal-assembly-sram
```

실험 artifact는 다음 위치에 저장한다.

```text
docs/future_optim/dma_experiments/<experiment-id>/
```

권장 directory 구조:

```text
<experiment-id>/
  manifest.md
  before/
    hw/rtl/...                 # 구조 변경 전 RTL 백업
  tests/
    unittest.log
    xrt-vcs-sim.log
  ooc/
    post_synth_util.rpt
    post_synth_timing_summary.rpt
    vivado.log
    sources.txt
  comparison.md
```

Checkpoint, waveform처럼 크기가 큰 파일은 기본 보존 대상이 아니다. 재현에 반드시 필요하거나 failure 분석에 사용한 경우에만 별도 위치를 manifest에 기록한다.

## Manifest 필수 항목

각 experiment의 `manifest.md`에는 다음 정보를 기록한다.

| 항목 | 내용 |
|---|---|
| Experiment ID | directory와 동일한 ID |
| 목적 | 검증하려는 구조 변경과 예상 효과 |
| Parent design | 직전 비교 대상 experiment ID |
| Baseline design | 고정 baseline experiment ID |
| 변경 파일 | 수정, 추가, 삭제 예정인 repo-relative path |
| 백업 완료 | backup path와 생성 시각 |
| Config | source한 config file과 주요 define/parameter |
| Git state | commit hash와 실험 시작 시 working-tree 상태 |
| Vivado | version, device part, OOC top, clock constraint |
| Unittest | command, 결과, log path |
| `xrt-vcs-sim` | app/arguments, command, 결과, log path |
| OOC synthesis | 결과와 raw report path |
| 결론 | keep, reject, investigate 중 하나와 근거 |

Working tree에 기존 사용자 변경이 있으면 이를 manifest에 기록하고 DMA 실험 변경과 섞이지 않도록 한다.

## 실험 절차

### Step 1: Baseline 선택

1. 현재 실험이 파생되는 parent experiment를 정한다.
2. 장기 비교에 사용할 fixed baseline experiment를 정한다.
3. Parent와 baseline의 config, OOC top, tool version이 현재 실험과 비교 가능한지 확인한다.
4. 비교 조건이 다르면 새로운 baseline series를 만든다.

### Step 2: Manifest와 백업 생성

1. 새 experiment ID와 directory를 생성한다.
2. 변경 목적과 예상되는 LUT/FF/BRAM/throughput 변화를 먼저 기록한다.
3. 수정할 기존 RTL을 `before/` 아래에 repo-relative 경로를 보존하여 복사한다.
4. Backup file과 원본의 checksum이 같은지 확인한다.
5. 백업 완료 전에는 구조 변경을 시작하지 않는다.

### Step 3: 구조 변경

- 한 experiment에서는 하나의 주요 구조 가설만 검증한다.
- 기능 변경과 resource 최적화를 가능한 한 분리한다.
- 여러 단계의 변경이 필요하면 response SRAM, assembly SRAM, request-buffer 분리처럼 experiment를 나눈다.
- 실험 도중 목적이 달라지면 기존 experiment를 재사용하지 않고 새 ID를 만든다.

### Step 4: Unittest gate

변경 범위에 맞는 unittest를 실행한다.

DMA 관련 기본 후보:

- `hw/unittest/dma`
- `hw/unittest/dma_engine`
- `hw/unittest/dma_mem_unit`
- `hw/unittest/dma_mem_unit_misal`
- `hw/unittest/lmem_dma`
- `hw/unittest/lmem_dma_misal`

모든 test를 기계적으로 실행하는 대신 변경된 interface와 datapath를 직접 커버하는 test set을 manifest에 명시한다. Unittest build와 실행은 configure된 build directory에서 수행하고 host compiler 규칙을 따른다.

### Step 5: `xrt-vcs-sim` gate

Unittest가 모두 통과한 뒤 `ci/run_black.sh xrt-vcs-sim`으로 RTL blackbox를 실행한다.

- Parent design과 같은 app 및 arguments를 최소 한 세트 포함한다.
- DMA 변경을 실제로 사용하는 workload를 선택한다.
- Timeout, assertion, X propagation, data mismatch를 모두 failure로 처리한다.
- 실패하면 synthesis로 진행하지 않고 log와 현재 판단을 저장한다.

### Step 6: Vivado OOC synthesis

두 test gate가 통과한 뒤 OOC synthesis를 실행한다.

필수 산출물:

- hierarchical post-synthesis utilization
- post-synthesis timing summary
- Vivado log
- 실제 compile에 사용한 source list
- tool/config/top/part 정보

`report_utilization`에는 hierarchy와 hierarchy percentage를 포함한다. DMA top 합계뿐 아니라 변경한 child module과 buffer/SRAM hierarchy도 확인할 수 있어야 한다.

### Step 7: 비교 및 결론

`comparison.md`에서 현재 design을 parent와 fixed baseline에 각각 비교한다.

필수 resource 항목:

- LUT
- LUT as Logic
- LUT as Memory
- FF
- RAMB36 또는 equivalent BRAM total
- URAM
- DSP
- OOC timing slack 또는 worst path delay

필요하면 다음 항목도 추가한다.

- Dynamic mux 또는 elastic-buffer child hierarchy
- Response/assembly SRAM별 BRAM 수
- Synthesis warning 수
- Unconstrained path 여부

## Comparison 표준 형식

```markdown
| Metric | Baseline | Parent | Current | Delta vs Parent | Delta vs Baseline |
|---|---:|---:|---:|---:|---:|
| LUT | | | | | |
| LUT as Memory | | | | | |
| FF | | | | | |
| RAMB36 | | | | | |
| URAM | | | | | |
| DSP | | | | | |
| Worst slack | | | | | |
```

Resource delta는 다음 방향으로 해석한다.

```text
delta = current - reference
```

- LUT/FF/DSP는 음수면 감소다.
- BRAM/URAM은 양수면 증가다.
- Timing slack은 양의 방향으로 커질수록 좋다.
- 절대 delta와 percentage delta를 함께 기록한다.
- Resource가 좋아져도 timing이나 기능이 악화되면 trade-off를 결론에 명시한다.

## 비교 가능성 규칙

다음 항목이 같아야 resource 수치를 직접 비교할 수 있다.

| 비교 조건 | 요구 사항 |
|---|---|
| RTL scope | 같은 OOC top과 wrapper hierarchy |
| Configuration | 같은 config file과 compile define |
| Parameters | port width, outstanding, PACK size 등 동일 |
| Tool | 같은 Vivado version |
| Device | 같은 FPGA part |
| Constraints | 같은 clock와 XDC |
| Synthesis | 같은 mode, directives와 options |

조건이 하나라도 다르면 `not directly comparable`로 표시한다. 필요한 경우 조건 변경 전 마지막 design을 기존 series의 종료점으로 남기고 새로운 baseline series를 시작한다.

## 실험 완료 조건

다음 항목이 모두 충족되어야 experiment를 완료로 판단한다.

- 구조 변경 전 RTL backup 존재
- Manifest의 변경 파일과 backup 목록 일치
- Relevant unittest PASS
- `xrt-vcs-sim` PASS
- Vivado OOC synthesis 완료
- Raw utilization/timing report와 Vivado log 저장
- Parent 및 fixed baseline 비교 완료
- 기능, resource, timing을 포함한 keep/reject/investigate 결론 기록

Bug fix만 수행하여 구조 백업을 생략한 경우에도 test 결과는 기록한다. Bug fix 이후 생성된 design이 다음 구조 실험의 parent가 되면 그 구조 실험을 시작할 때 새 baseline backup과 report를 만든다.

## 채택 규칙

새 DMA design은 다음 조건을 만족할 때만 채택 후보로 삼는다.

1. Relevant unittest와 `xrt-vcs-sim`이 모두 통과한다.
2. OOC report에서 목표 resource가 실제로 감소하거나 의도한 BRAM trade-off가 확인된다.
3. Timing이 악화되었다면 resource 이득과 함께 명시적으로 평가한다.
4. Parent와 fixed baseline 모두에 대한 비교 자료가 존재한다.
5. 다음 실험이 이전 결과를 재현할 수 있을 만큼 config와 artifact가 보존되어 있다.

OOC 결과가 좋은 design은 최종적으로 전체 XRT synthesis와 post-physopt hierarchical utilization에서 다시 검증한 뒤 production 방향으로 확정한다.
