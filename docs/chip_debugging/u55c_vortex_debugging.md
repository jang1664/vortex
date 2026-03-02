# Vortex on U55C: 실칩 디버깅 가이드

이 문서는 `Vortex + XRT + Alveo U55C`를 기준으로, 실칩에서 바로 쓸 수 있는 디버깅 절차를 정리한 문서다.

정리 대상:
1. ILA 사용
2. kernel `printf` + COUT 경로 활용
3. 추가 방법 (SCOPE, PERF, XRT 프로파일)

---

## 0) 공통 전제

- 플랫폼: `xilinx_u55c_gen3x16_xdma_3_202210_1`
- xclbin 빌드 디렉토리 패턴: `hw/syn/xilinx/xrt/<PREFIX>_<PLATFORM>_<TARGET>/bin`
- 실칩 실행 예시:

```bash
FPGA_BIN_DIR=<build_dir>/bin TARGET=hw ./ci/blackbox.sh --driver=xrt --app=elunary
```

---

## 1) 방법 1: ILA(CHIPSCOPE)로 디버깅

### 1-1. 디버그 비트스트림 빌드

`DEBUG=1`로 빌드하면 XRT 합성 플로우에서 `-DCHIPSCOPE`가 켜지고, ILA debug 연동(`--debug.chipscope`)이 활성화된다.

```bash
cd hw/syn/xilinx/xrt
PREFIX=build_dbg_u55c NUM_CORES=2 TARGET=hw \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 DEBUG=1 make
```

생성물:
- `vortex_afu.xclbin`
- `vortex_afu.ltx` (probe 파일)

### 1-2. 런타임을 ILA 대기 모드로 빌드

XRT 런타임에 `CHIPSCOPE=1`을 주면 실행 시점에 아래 메시지에서 멈춘다.
- `Press ENTER to continue after setting up ILA trigger...`

```bash
make -C runtime/stub
CHIPSCOPE=1 make -C runtime/xrt
```

`blackbox.sh`를 쓸 때도 환경변수로 전달 가능:

```bash
CHIPSCOPE=1 FPGA_BIN_DIR=<build_dir>/bin TARGET=hw \
./ci/blackbox.sh --driver=xrt --app=elunary --debug=1
```

### 1-3. hw_server + Vivado 연결

터미널 A:

```bash
ls /dev/xfpga/xvc_pub*
debug_hw --xvc_pcie /dev/xfpga/xvc_pub.<deviceid> --hw_server
```

터미널 B (Vivado 디버그 GUI 연결):

```bash
debug_hw --vivado --host localhost --ltx_file <build_dir>/bin/vortex_afu.ltx &
```

또는 합성 디렉토리에서:

```bash
cd hw/syn/xilinx/xrt
PREFIX=build_dbg_u55c TARGET=hw PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 make chipscope
```

### 1-4. 실제 트리거 순서

1. 앱 실행 (CHIPSCOPE 대기 상태에서 멈춤)
2. Vivado Hardware Manager 접속
3. `ila_afu / ila_fetch / ila_issue / ila_lsu` 트리거 조건 설정
4. ILA Arm
5. 앱 터미널에서 Enter 입력
6. 캡처 확인, 필요 시 trigger 조건 조정 후 반복

### 1-5. ILA 코어별 관측 포인트

- `ila_afu`: AFU state/ap_start/ap_done/vx_busy/DCR write 흐름
- `ila_fetch`: 스케줄 입력, icache req/rsp
- `ila_issue`: decode/scoreboard/operands/writeback
- `ila_lsu`: execute ↔ LSU mem req/rsp

### 1-6. 프로브 신호를 바꾸는 경우 주의점

RTL에서 probe 패킹을 바꾸면 `package_kernel.tcl`의 ILA 폭(`C_PROBE*_WIDTH`)도 반드시 같이 맞춰야 한다.

관련 파일:
- `hw/rtl/afu/xrt/VX_afu_wrap.sv`
- `hw/rtl/core/VX_fetch.sv`
- `hw/rtl/core/VX_issue_slice.sv`
- `hw/rtl/core/VX_lsu_slice.sv`
- `hw/syn/xilinx/xrt/package_kernel.tcl`

불일치 시 synth/package 단계에서 에러가 난다.

---

## 2) 방법 2: kernel printf + COUT 경로 디버깅

핵심부터 말하면:
- **OPAE 경로**에는 COUT를 MMIO status로 꺼내는 로직이 있음.
- **U55C XRT 경로**에는 동일한 COUT MMIO status 레지스터가 없음.

즉, U55C(XRT)에서는 "MMIO COUT 상태 레지스터를 읽어 콘솔 스트리밍"이 기본 제공되지 않는다.

### 2-1. kernel printf 동작 방식

`vx_printf`는 결국 `vx_putchar`를 통해 아래 주소에 1바이트를 쓴다.

- `IO_COUT_ADDR = 0x40`
- `IO_COUT_SIZE = 64`
- 실제 write 주소: `IO_COUT_ADDR + (mhartid & (IO_COUT_SIZE-1))`

즉 hart별 1-byte 슬롯 기반이라, 빠른 출력은 쉽게 덮어써진다.

### 2-2. U55C(XRT)에서 가능한 실전 절차

#### A) COUT 메모리 윈도우를 host에서 읽는 방식

1. COUT 영역 reserve
2. 실행 전 0으로 초기화
3. 커널 실행
4. 실행 후(또는 주기적) `vx_copy_from_dev`로 COUT 64B를 읽어 해석

예시 코드:

```cpp
vx_buffer_h cout_buf = nullptr;
RT_CHECK(vx_mem_reserve(device, IO_COUT_ADDR, IO_COUT_SIZE, VX_MEM_READ_WRITE, &cout_buf));

std::array<uint8_t, IO_COUT_SIZE> zeros{};
RT_CHECK(vx_copy_to_dev(cout_buf, zeros.data(), 0, IO_COUT_SIZE));

// ... kernel run ...

std::array<uint8_t, IO_COUT_SIZE> snap{};
RT_CHECK(vx_copy_from_dev(snap.data(), cout_buf, 0, IO_COUT_SIZE));
for (size_t i = 0; i < snap.size(); ++i) {
  if (snap[i] != 0)
    printf("hart[%zu] last_char='%c' (0x%02x)\n", i, snap[i], snap[i]);
}
```

#### B) kernel printf 사용 팁

- 출력 스팸 줄이기: `if (blockIdx.x==0 && threadIdx.x==0) vx_printf(...)`
- 구간 태그를 짧게 넣기: `"[A]", "[B]"`
- 값 1~2개만 찍고, 상세 데이터는 global 메모리 debug buffer로 남기기

### 2-3. 제한사항

- hart별 1-byte 슬롯 구조라 전체 문자열 로그를 안정적으로 복원하기 어렵다.
- 따라서 U55C/XRT에서 printf는 "마지막 상태 힌트" 용도로 쓰는 것이 현실적이다.

---

## 3) 추가 방법 1: SCOPE(in-house on-chip trace, VCD 추출)

ILA와 별도로, Vortex 자체 scope 탭을 통해 `scope.vcd`를 뽑을 수 있다.

### 절차

1. 비트스트림 빌드 (`SCOPE=1`)

```bash
cd hw/syn/xilinx/xrt
PREFIX=build_scope_u55c NUM_CORES=2 TARGET=hw \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 SCOPE=1 make
```

2. 런타임 빌드 (`SCOPE=1`)

```bash
SCOPE=1 make -C runtime/xrt
```

3. 실행 (`SCOPE_JSON_PATH`는 build/bin/scope.json 사용)

```bash
SCOPE=1 FPGA_BIN_DIR=<build_dir>/bin TARGET=hw \
./ci/blackbox.sh --driver=xrt --app=elunary --scope
```

4. 결과: `scope.vcd` 생성

환경변수 튜닝:
- `SCOPE_DEPTH` : 캡처 깊이
- `SCOPE_TIMEOUT` : auto-stop 시간(초)

특징:
- 장점: 파일 기반으로 장시간/사후 분석이 쉬움
- 단점: 관측 신호가 `SCOPE_TAP`에 묶인 신호로 제한됨

---

## 4) 추가 방법 2: PERF/MPM 카운터 기반 병목 분석

기능 디버그가 끝난 뒤 병목 위치를 좁히는 데 가장 빠른 방법이다.

### 절차

1. 비트스트림 빌드 시 `PERF=1`

```bash
cd hw/syn/xilinx/xrt
PREFIX=build_perf_u55c NUM_CORES=2 TARGET=hw \
PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 PERF=1 make
```

2. 실행 시 profiling class 선택

- `VORTEX_PROFILING=1` : core/pipeline 중심
- `VORTEX_PROFILING=2` : memory system 중심

`blackbox` 사용 예:

```bash
FPGA_BIN_DIR=<build_dir>/bin TARGET=hw \
./ci/blackbox.sh --driver=xrt --app=elunary --perf=1
```

3. host 코드에서 `vx_dump_perf(device, stdout);` 출력 확인

특징:
- 장점: 재현 가능한 수치로 병목 지점 확인 가능
- 단점: cycle-level 파형 자체는 보여주지 않음

---

## 5) 추가 방법 3: XRT timeline/profile

`xrt.ini`의 Debug 옵션으로 커널 실행 타임라인과 데이터 전송 로그를 분석할 수 있다.

기본 설정(runtime/xrt/xrt.ini.in):
- `profile=true`
- `timeline_trace=true`
- `data_transfer_trace=fine`

실행 후 생성되는 run summary는 `vitis_analyzer`로 분석 가능하다.

```bash
vitis_analyzer <generated_run_summary>
```

용도:
- host enqueue 지연, 전송-실행 겹침, 데이터 이동 병목 확인

---

## 6) 실전 추천 순서

1. `PERF/MPM`으로 병목 범위를 먼저 줄인다.
2. 구간 식별용으로 `printf(COUT)`를 최소 출력으로 넣는다.
3. 원인 추적은 `ILA` 또는 `SCOPE`로 cycle-level 확인한다.

- 짧은 타이밍 이슈/handshake 문제: `ILA`
- 길게 누적되는 이벤트/사후 분석: `SCOPE`

---

## 7) 요약

- 질문하신 2가지 중, **ILA는 U55C(XRT)에서 즉시 실전 사용 가능**하다.
- **printf + COUT MMIO 레지스터 읽기**는 OPAE 쪽과 달리 XRT 경로에 기본 제공되지 않으므로,
  U55C에서는 `IO_COUT` 메모리 윈도우 읽기 방식으로 운용하는 것이 현실적이다.
- 추가로 `SCOPE`, `PERF`, `XRT timeline`까지 같이 쓰면 실칩 디버깅 시간이 크게 줄어든다.
