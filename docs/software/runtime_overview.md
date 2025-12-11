# Vortex Runtime 구조 및 실행 흐름 분석

## 1. 개요

Vortex Runtime은 Host Application과 Vortex Hardware(또는 Simulator) 사이의 추상화 계층입니다. 사용자는 `vortex.h`에 정의된 공통 API를 사용하여 하드웨어를 제어하며, 실제 구현은 백엔드(Backend) 드라이버에 따라 달라집니다.

## 2. 런타임 아키텍처

Vortex 런타임은 **동적 로딩(Dynamic Loading)** 방식을 사용하여 유연성을 제공합니다.

```mermaid
graph TD
    App[User Application] -->|Calls| Stub[Stub Driver (runtime/stub)]
    Stub -->|dlopen| Backend{Backend Driver}
    
    Backend -->|libvortex-simx.so| SimX[SimX Simulator]
    Backend -->|libvortex-rtlsim.so| RTLSim[RTL Simulator]
    Backend -->|libvortex-opae.so| OPAE[Intel FPGA]
    Backend -->|libvortex-xrt.so| XRT[Xilinx FPGA]
```

### 2.1 Stub Driver (`runtime/stub`)

사용자 애플리케이션이 링크하는 기본 라이브러리입니다. 실제 드라이버가 아니라, 환경 변수에 따라 적절한 백엔드 드라이버를 로드하고 API 호출을 전달하는 **프록시(Proxy)** 역할을 합니다.

- **`vortex.cpp`**: `vx_dev_open` 호출 시 `VORTEX_DRIVER` 환경 변수를 확인하여 해당 `.so` 파일을 `dlopen`으로 로드합니다.
- **`utils.cpp`**: 커널 바이너리 업로드(`vx_upload_kernel_file`), 성능 카운터 덤프(`vx_dump_perf`) 등 백엔드 독립적인 유틸리티 함수를 제공합니다.

### 2.2 Callback Mechanism

Stub 드라이버는 `callbacks_t` 구조체를 통해 백엔드 드라이버의 함수 포인터를 관리합니다.

1.  **초기화**: `vx_dev_open` 호출 시 백엔드 라이브러리를 로드하고, 백엔드의 `vx_dev_init` 함수를 찾아 호출합니다.
2.  **등록**: 백엔드의 `vx_dev_init`은 자신의 구현 함수들(open, close, start 등)을 `callbacks_t` 구조체에 채워 넣습니다.
3.  **실행**: 이후 `vx_start` 등의 API 호출은 `g_callbacks.start(...)`와 같이 백엔드 함수로 전달됩니다.

## 3. 공통 인터페이스 (`runtime/include/vortex.h`)

모든 런타임 백엔드는 이 헤더에 정의된 API를 구현해야 합니다.

### 주요 API
- **Device Management**: `vx_dev_open`, `vx_dev_close`, `vx_dev_caps`
- **Memory Management**: `vx_mem_alloc`, `vx_mem_free`, `vx_copy_to_dev`, `vx_copy_from_dev`
- **Execution**: `vx_start`, `vx_ready_wait`
- **Low-level Access**: `vx_dcr_write`, `vx_mpm_query`

## 4. 공통 구현 (`runtime/common`)

백엔드 개발을 돕기 위해 공통적으로 사용되는 유틸리티와 콜백 구조가 제공됩니다.

- **`callbacks.inc`**: C API(`vx_*`)를 C++ 클래스(`vx_device`) 메서드로 매핑하는 래퍼(Wrapper) 구현입니다. 대부분의 백엔드(`rtlsim`, `simx`, `opae` 등)가 이 파일을 include하여 API 구현을 공유합니다.
- **`common.h`**: 공통 매크로, 에러 체크, 메모리 정렬 유틸리티 등을 정의합니다.

## 5. 런타임 백엔드 (Backends)

Vortex는 다양한 실행 환경을 지원하기 위해 여러 백엔드를 제공합니다.

### 5.1 SimX (`runtime/simx`)
- **설명**: Cycle-approximate C++ 시뮬레이터입니다.
- **특징**: RTL 시뮬레이션보다 빠르며, 아키텍처 탐색 및 소프트웨어 개발 초기 단계에 유용합니다.
- **구현**: `vx_device` 클래스가 내부적으로 `Processor`, `Arch`, `Memory` 객체를 생성하여 시뮬레이션을 수행합니다.

### 5.2 RTLSim (`runtime/rtlsim`)
- **설명**: Verilator를 사용한 Cycle-accurate RTL 시뮬레이터입니다.
- **특징**: 실제 하드웨어(Verilog)와 동일한 동작을 보장합니다. 하드웨어 검증 및 정확한 성능 측정에 사용됩니다.
- **구현**: Verilator가 생성한 C++ 모델(`VVortex`)을 구동합니다.

### 5.3 OPAE (`runtime/opae`)
- **설명**: Intel FPGA (PAC Arria 10, Stratix 10 등)용 드라이버입니다.
- **특징**: OPAE(Open Programmable Acceleration Engine) 라이브러리를 사용하여 FPGA와 통신합니다.
- **구현**: PCIe를 통해 FPGA 메모리에 접근하고 CSR을 제어합니다.

### 5.4 XRT (`runtime/xrt`)
- **설명**: Xilinx FPGA (Alveo 등)용 드라이버입니다.
- **특징**: Xilinx Runtime(XRT) 라이브러리를 사용합니다.
- **구현**: XRT API를 통해 커널을 로드하고 버퍼를 관리합니다.

## 6. 실행 흐름 예시 (vx_dev_open)

1.  **User App**: `vx_dev_open(&device)` 호출
2.  **Stub (`runtime/stub/vortex.cpp`)**:
    - `getenv("VORTEX_DRIVER")` 확인 (기본값: "simx")
    - `dlopen("libvortex-simx.so")` 실행
    - `dlsym("vx_dev_init")`으로 초기화 함수 주소 획득
    - `vx_dev_init(&g_callbacks)` 호출
3.  **Backend (`runtime/simx/vortex.cpp` + `callbacks.inc`)**:
    - `g_callbacks` 구조체에 자신의 함수들(`dev_open`, `mem_alloc` 등) 등록
4.  **Stub**:
    - `g_callbacks.dev_open(&device)` 호출 -> 실제 SimX 디바이스 생성
    - `dcr_initialize(device)` 호출 -> 기본 DCR 설정

## 7. 요약

- **Stub Driver**: 애플리케이션과 백엔드 사이의 중개자. 동적 로딩을 통해 재컴파일 없이 백엔드 교체 가능.
- **Callback 구조**: `callbacks_t`를 통해 C++ 객체 메서드를 C API로 노출.
- **유연성**: 환경 변수 하나로 시뮬레이터와 실제 FPGA 하드웨어를 오갈 수 있음.