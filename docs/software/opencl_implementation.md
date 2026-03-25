# OpenCL Implementation on Vortex

## 1. 개요

Vortex는 OpenCL 1.2 지원을 위해 **PoCL (Portable Computing Language)**을 사용합니다. PoCL은 OpenCL 표준 API를 구현하는 오픈소스 프레임워크로, Vortex는 PoCL의 **Custom Device Driver** 형태로 통합되어 있습니다.

이 문서는 OpenCL 애플리케이션이 Vortex 하드웨어에서 실행되기까지의 전체 소프트웨어 스택과 실행 흐름을 설명합니다.

## 2. 소프트웨어 스택 구조

```mermaid
graph TD
    UserApp[User Application]
    
    subgraph "OpenCL Framework (PoCL)"
        libOpenCL[libOpenCL.so]
        VortexDrv[Vortex Device Driver (Internal to PoCL)]
        LLVM[LLVM Compiler (Vortex Backend)]
    end
    
    subgraph "Vortex Runtime"
        Stub[Stub Driver (libvortex.so)]
        Backend[Backend Driver (libvortex-*.so)]
    end
    
    subgraph "Hardware / Simulation"
        HW[Vortex GPU / Simulator]
    end

    UserApp -->|OpenCL API| libOpenCL
    libOpenCL -->|Compile Kernel| LLVM
    libOpenCL -->|Control Device| VortexDrv
    
    VortexDrv -->|Vortex API (vx_*)| Stub
    Stub -->|Dynamic Load| Backend
    Backend -->|DCR / Memory| HW
```

### 2.1 계층별 역할

1.  **User Application**: 표준 OpenCL API(`clEnqueueNDRangeKernel` 등)를 사용하여 알고리즘을 구현합니다.
2.  **PoCL (libOpenCL.so)**:
    *   **Platform Layer**: Context, Command Queue, Memory Object 등을 관리합니다.
    *   **Compiler**: 내장된 LLVM을 사용하여 OpenCL C 커널 코드를 **RISC-V 바이너리**로 컴파일합니다.
    *   **Device Driver**: Vortex 하드웨어를 제어하기 위한 로직을 포함하며, Vortex Runtime API를 호출합니다.
3.  **Vortex Runtime (libvortex.so)**:
    *   PoCL과 하드웨어 백엔드 사이의 중개자 역할을 합니다.
    *   `VORTEX_DRIVER` 환경 변수에 따라 실제 백엔드(SimX, RTLSim, FPGA)를 로드합니다.
4.  **Backend Driver**:
    *   실제 하드웨어 또는 시뮬레이터와 통신합니다.

## 3. 실행 흐름 상세 (Execution Flow)

사용자가 벡터 덧셈(Vector Add) 커널을 실행하는 과정을 예로 들어 설명합니다.

### Step 1: 초기화 (Initialization)
*   **OpenCL**: `clGetPlatformIDs`, `clCreateContext`
*   **Action**: PoCL이 로드되면서 내부적으로 Vortex 드라이버를 초기화합니다.
*   **Vortex API**: `vx_dev_open()`
    *   PoCL 드라이버는 이 함수를 호출하여 Vortex 런타임에 연결 핸들(`vx_device_h`)을 획득합니다.

### Step 2: 메모리 할당 (Memory Allocation)
*   **OpenCL**: `clCreateBuffer`
*   **Action**: 디바이스 메모리 공간을 확보합니다.
*   **Vortex API**: `vx_mem_alloc()`
    *   Vortex의 Global Memory 영역에서 요청된 크기만큼 할당받습니다.

### Step 3: 데이터 전송 (Data Transfer)
*   **OpenCL**: `clEnqueueWriteBuffer`
*   **Action**: 호스트 데이터를 디바이스 메모리로 복사합니다.
*   **Vortex API**: `vx_copy_to_dev()`
    *   PCIe(FPGA) 또는 공유 메모리(Simulator)를 통해 데이터를 전송합니다.

### Step 4: 커널 컴파일 (Kernel Compilation)
*   **OpenCL**: `clBuildProgram`
*   **Action**: OpenCL C 소스 코드를 RISC-V ELF 바이너리로 변환합니다.
*   **Compiler**: LLVM Vortex Backend
    *   Target: `riscv32-unknown-elf` (or 64-bit)
    *   CPU: `vortex` (Vortex 특수 명령어 및 CSR 지원)

### Step 5: 커널 실행 (Kernel Execution)
*   **OpenCL**: `clEnqueueNDRangeKernel`
*   **Action**: 커널 바이너리를 로드하고 실행을 시작합니다.
*   **Vortex API**:
    1.  `vx_upload_kernel_bytes()`: 컴파일된 ELF 바이너리를 디바이스의 Instruction Memory로 업로드합니다.
    2.  `vx_dcr_write()`: 필요한 하드웨어 설정(CSR)을 수행합니다.
    3.  `vx_start()`: 프로세서 실행을 트리거합니다.

### Step 6: 결과 회수 (Result Retrieval)
*   **OpenCL**: `clEnqueueReadBuffer`
*   **Action**: 연산 결과를 호스트로 가져옵니다.
*   **Vortex API**: `vx_copy_from_dev()`

## 4. PoCL 구현 코드 위치

Vortex를 지원하는 PoCL 드라이버 코드는 **Vortex 저장소 내부에 포함되어 있지 않습니다**. 이는 외부 Toolchain의 일부로 설치됩니다.

*   **설치 위치**: `ci/toolchain_install.sh` 스크립트에 의해 다운로드 및 설치됩니다.
*   **소스 코드 (개념적 위치)**: PoCL 소스 트리의 `lib/CL/devices/vortex` (가상의 경로) 등에 위치하며, 빌드 시 `libOpenCL.so`에 포함됩니다.
*   **인터페이스**: PoCL 드라이버는 Vortex 저장소의 `runtime/include/vortex.h` 헤더를 사용하여 구현됩니다.

### 인터페이스 예시 (`runtime/include/vortex.h`)

PoCL 드라이버는 아래 API를 사용하여 Vortex를 제어합니다.

```c
// 디바이스 연결
int vx_dev_open(vx_device_h* hdevice);

// 메모리 관리
int vx_mem_alloc(vx_device_h hdevice, uint64_t size, int flags, vx_buffer_h* hbuffer);
int vx_copy_to_dev(vx_buffer_h hbuffer, const void* host_ptr, uint64_t dst_offset, uint64_t size);

// 실행 제어
int vx_start(vx_device_h hdevice, vx_buffer_h hkernel, vx_buffer_h harguments);
int vx_ready_wait(vx_device_h hdevice, uint64_t timeout);
```

## 5. 결론

Vortex의 OpenCL 지원은 **PoCL 프레임워크**와 **Vortex Runtime**의 긴밀한 통합으로 이루어집니다. PoCL은 복잡한 OpenCL 상태 관리와 컴파일을 담당하고, Vortex Runtime은 하드웨어 제어라는 단순하고 명확한 역할에 집중함으로써 효율적인 계층 구조를 형성하고 있습니다.
