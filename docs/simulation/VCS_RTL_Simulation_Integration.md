# VCS 기반 RTL 시뮬레이션 통합 가이드

## 목차
1. [개요](#개요)
2. [Verilator vs VCS 비교](#verilator-vs-vcs-비교)
3. [아키텍처 설계](#아키텍처-설계)
4. [Socket 기반 구현](#socket-기반-구현)
5. [DPI-C 인터페이스](#dpi-c-인터페이스)
6. [Shared Memory 대안](#shared-memory-대안)
7. [실행 방법](#실행-방법)
8. [Makefile 통합](#makefile-통합)
9. [디버깅 및 고급 기능](#디버깅-및-고급-기능)

---

## 개요

### 목적
- **ASIC 검증**: Post-synthesis netlist + SDF annotation을 통한 타이밍 시뮬레이션
- **전체 스택 유지**: OpenCL → PoCL → Vortex Runtime → VCS RTL simulation end-to-end 통합
- **기존 코드 재사용**: OpenCL 애플리케이션 및 Runtime API 변경 없이 시뮬레이터만 교체

### 필요성
- Verilator: Cycle-accurate, fast, but no SDF annotation support
- VCS: Event-driven, slower, but supports SDF annotation for timing analysis
- ASIC 설계 검증을 위해 VCS 필요, 하지만 OpenCL 스택 유지 필요

### 핵심 과제
Verilator는 **single-process** (RTL이 C++로 컴파일되어 같은 프로세스):
```cpp
// processor.cpp (Verilator)
Vrtlsim_shim* device_;  // 직접 멤버 접근 가능
device_->clk = 0;       // 신호 직접 조작
```

VCS는 **multi-process** (Host와 Simulator가 별도 프로세스):
- Host: OpenCL app + libvortex.so
- Simulator: VCS simv (SystemVerilog testbench + DUT)
- **문제**: 프로세스 간 통신(IPC) 필요

---

## Verilator vs VCS 비교

| 특성 | Verilator | VCS |
|------|-----------|-----|
| 시뮬레이션 방식 | Compile-based (RTL → C++) | Event-driven |
| 프로세스 모델 | Single-process | Multi-process |
| 신호 접근 | 직접 멤버 접근 (`device_->clk`) | DPI-C 함수 호출 |
| SDF Annotation | 지원 안 함 | 지원 ✅ |
| 타이밍 검증 | Cycle-accurate만 가능 | Gate-level + timing 가능 |
| 속도 | 빠름 (수십 MHz) | 느림 (수백 kHz) |
| 파형 분석 | VCD (gtkwave) | FSDB (Verdi) |
| 용도 | Functional verification | ASIC timing verification |

### 통합 방식 차이

**Verilator**:
```
┌─────────────────────────────────────┐
│ Host Process                        │
│ ┌──────────────┐  ┌──────────────┐ │
│ │ OpenCL App   │→ │ libvortex.so │ │
│ └──────────────┘  └──────┬───────┘ │
│                          ↓          │
│                  ┌───────────────┐  │
│                  │ processor.cpp │  │
│                  └───────┬───────┘  │
│                          ↓          │
│                  ┌───────────────┐  │
│                  │ Vrtlsim_shim* │  │ ← RTL이 C++로 컴파일됨
│                  │ (Verilated)   │  │
│                  └───────────────┘  │
└─────────────────────────────────────┘
```

**VCS (제안 아키텍처)**:
```
┌────────────────┐                 ┌─────────────────┐
│ Host Process   │                 │ VCS simv Process│
│ ┌────────────┐ │                 │ ┌─────────────┐ │
│ │ OpenCL App │ │                 │ │ Testbench   │ │
│ └─────┬──────┘ │                 │ │ (SV)        │ │
│       ↓        │                 │ └──────┬──────┘ │
│ ┌────────────┐ │   Socket/SHM    │        ↓        │
│ │libvortex   │─┼─────────────────┼→┌──────────────┐│
│ │-vcs.so     │←┼─────────────────┼─│ DPI-C Server ││
│ └────────────┘ │                 │ │ (vcs_server) ││
│                │                 │ └──────┬───────┘│
│                │                 │        ↓        │
│                │                 │ ┌──────────────┐│
│                │                 │ │ DUT (Vortex) ││
│                │                 │ └──────────────┘│
└────────────────┘                 └─────────────────┘
```

---

## 아키텍처 설계

### 전체 흐름

1. **Host Process** (OpenCL Application):
   - OpenCL 커널 컴파일 → PoCL → Vortex Runtime
   - `vx_start(device, kernel_bin)` 호출
   - `libvortex-vcs.so`가 Socket으로 VCS에 메시지 전송

2. **VCS simv Process** (RTL Simulator):
   - Socket server로 명령 수신
   - DPI-C callback을 통해 Testbench에 전달
   - Testbench FSM이 DUT 제어 (kernel loading, execution)
   - 완료 후 Socket으로 응답

3. **동기화**:
   - `vx_ready_wait()`: Host가 block되어 VCS 완료 대기
   - VCS가 kernel done → Socket 메시지 → Host return

### 핵심 컴포넌트

#### 1. Host Side: `runtime/vcs/vortex_vcs.cpp`
```cpp
// vx_device 구조체 (VCS용)
struct vx_device {
    int sockfd;  // Socket file descriptor
    // ... 기타 상태
};

// Socket 초기화
extern "C" int vx_dev_open(vx_device_h* hdevice) {
    vx_device* device = new vx_device();
    
    // Socket 연결
    device->sockfd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(5555);
    inet_pton(AF_INET, "127.0.0.1", &server_addr.sin_addr);
    
    connect(device->sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr));
    
    *hdevice = device;
    return 0;
}

// Kernel 실행 요청
extern "C" int vx_start(vx_device_h hdevice) {
    vx_device* device = (vx_device*)hdevice;
    
    // 메시지 전송: "START kernel_addr kernel_size"
    char msg[256];
    snprintf(msg, sizeof(msg), "START %llx %d", 
             device->kernel_addr, device->kernel_size);
    send(device->sockfd, msg, strlen(msg), 0);
    
    return 0;
}

// 완료 대기
extern "C" int vx_ready_wait(vx_device_h hdevice, uint64_t timeout) {
    vx_device* device = (vx_device*)hdevice;
    
    // VCS로부터 "DONE" 메시지 수신
    char buffer[256];
    recv(device->sockfd, buffer, sizeof(buffer), 0);
    
    if (strncmp(buffer, "DONE", 4) == 0) {
        return 0;  // Success
    }
    return -1;  // Error
}
```

#### 2. VCS Side: DPI-C Server (`sim/vcs/vcs_server.cpp`)
```cpp
#include <svdpi.h>
#include <queue>
#include <string>

// 명령 큐 (Global)
static std::queue<std::string> command_queue;
static int server_sockfd = -1;
static bool server_running = false;

// Socket server thread
void* socket_server_thread(void* arg) {
    server_sockfd = socket(AF_INET, SOCK_STREAM, 0);
    
    struct sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(5555);
    server_addr.sin_addr.s_addr = INADDR_ANY;
    
    bind(server_sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr));
    listen(server_sockfd, 1);
    
    server_running = true;
    
    while (server_running) {
        int client_sock = accept(server_sockfd, NULL, NULL);
        
        char buffer[256];
        while (true) {
            int n = recv(client_sock, buffer, sizeof(buffer) - 1, 0);
            if (n <= 0) break;
            
            buffer[n] = '\0';
            
            // 명령 큐에 추가
            command_queue.push(std::string(buffer));
            
            // "DONE" 응답 (실제로는 testbench가 완료 시 호출)
            // send(client_sock, "DONE", 4, 0);
        }
    }
    
    return NULL;
}

// DPI-C: Server 시작
extern "C" void dpi_start_server() {
    pthread_t thread;
    pthread_create(&thread, NULL, socket_server_thread, NULL);
}

// DPI-C: 명령 확인
extern "C" int dpi_has_command() {
    return !command_queue.empty() ? 1 : 0;
}

// DPI-C: 명령 가져오기
extern "C" void dpi_get_command(char* cmd, int max_len) {
    if (!command_queue.empty()) {
        std::string str = command_queue.front();
        command_queue.pop();
        strncpy(cmd, str.c_str(), max_len - 1);
        cmd[max_len - 1] = '\0';
    }
}

// DPI-C: 완료 응답 전송
extern "C" void dpi_send_done() {
    // 실제로는 client_sock을 저장해두고 사용
    // send(client_sock, "DONE", 4, 0);
}
```

#### 3. Testbench: `sim/vcs/rtlsim_vcs_tb.sv`
```systemverilog
module rtlsim_vcs_tb;
    // DPI-C imports
    import "DPI-C" function void dpi_start_server();
    import "DPI-C" function int dpi_has_command();
    import "DPI-C" function void dpi_get_command(output string cmd);
    import "DPI-C" function void dpi_send_done();
    
    // DUT signals
    logic clk;
    logic reset;
    
    // DUT instance
    Vortex_axi dut (
        .clk(clk),
        .reset(reset),
        // ... 기타 신호
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100MHz
    end
    
    // Server 시작
    initial begin
        dpi_start_server();
    end
    
    // 명령 처리 FSM
    typedef enum {IDLE, LOAD_KERNEL, RUN_KERNEL, WAIT_DONE} state_t;
    state_t state = IDLE;
    
    string cmd;
    
    always @(posedge clk) begin
        case (state)
            IDLE: begin
                if (dpi_has_command()) begin
                    dpi_get_command(cmd);
                    
                    // "START ..." 파싱
                    if (cmd.substr(0, 5) == "START") begin
                        // Kernel address/size 추출
                        // ...
                        state <= LOAD_KERNEL;
                    end
                end
            end
            
            LOAD_KERNEL: begin
                // AXI write로 kernel binary를 메모리에 로드
                // ...
                state <= RUN_KERNEL;
            end
            
            RUN_KERNEL: begin
                // CSR write로 kernel 시작
                // ...
                state <= WAIT_DONE;
            end
            
            WAIT_DONE: begin
                // DUT의 done 신호 대기
                if (dut.done) begin
                    dpi_send_done();  // Host에 완료 통보
                    state <= IDLE;
                end
            end
        endcase
    end
endmodule
```

---

## Socket 기반 구현

### 프로토콜 설계

#### 메시지 포맷

**Host → VCS**:
```
START <kernel_addr> <kernel_size>
UPLOAD <addr> <size> <data...>
CSR_WRITE <addr> <value>
CSR_READ <addr>
```

**VCS → Host**:
```
DONE
CSR_DATA <value>
ERROR <message>
```

#### 구현 세부사항

**Host Side (완전한 구현)**:
```cpp
// runtime/vcs/vortex_vcs.cpp
#include <vortex.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <cstring>

struct vx_device {
    int sockfd;
    uint64_t kernel_addr;
    uint32_t kernel_size;
};

extern "C" int vx_dev_open(vx_device_h* hdevice) {
    vx_device* device = new vx_device();
    
    // Socket 생성
    device->sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (device->sockfd < 0) {
        delete device;
        return -1;
    }
    
    // Server 연결
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(5555);
    inet_pton(AF_INET, "127.0.0.1", &server_addr.sin_addr);
    
    if (connect(device->sockfd, (struct sockaddr*)&server_addr, 
                sizeof(server_addr)) < 0) {
        close(device->sockfd);
        delete device;
        return -1;
    }
    
    *hdevice = device;
    return 0;
}

extern "C" int vx_dev_close(vx_device_h hdevice) {
    vx_device* device = (vx_device*)hdevice;
    close(device->sockfd);
    delete device;
    return 0;
}

extern "C" int vx_upload_kernel_bytes(vx_device_h hdevice, 
                                       const void* content, 
                                       uint64_t size) {
    vx_device* device = (vx_device*)hdevice;
    
    // VCS에 UPLOAD 명령 전송
    char header[256];
    snprintf(header, sizeof(header), "UPLOAD %llu", (unsigned long long)size);
    send(device->sockfd, header, strlen(header), 0);
    
    // 바이너리 데이터 전송
    send(device->sockfd, content, size, 0);
    
    // 응답 대기
    char response[256];
    recv(device->sockfd, response, sizeof(response), 0);
    
    device->kernel_size = size;
    return 0;
}

extern "C" int vx_start(vx_device_h hdevice) {
    vx_device* device = (vx_device*)hdevice;
    
    char msg[256];
    snprintf(msg, sizeof(msg), "START");
    send(device->sockfd, msg, strlen(msg), 0);
    
    return 0;
}

extern "C" int vx_ready_wait(vx_device_h hdevice, uint64_t timeout) {
    vx_device* device = (vx_device*)hdevice;
    
    // Timeout 설정
    struct timeval tv;
    tv.tv_sec = timeout / 1000000;
    tv.tv_usec = timeout % 1000000;
    setsockopt(device->sockfd, SOL_SOCKET, SO_RCVTIMEO, 
               &tv, sizeof(tv));
    
    // DONE 메시지 수신
    char buffer[256];
    int n = recv(device->sockfd, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) return -1;
    
    buffer[n] = '\0';
    if (strncmp(buffer, "DONE", 4) == 0) {
        return 0;
    }
    
    return -1;
}

// CSR 접근
extern "C" int vx_mem_write(vx_device_h hdevice, 
                             uint64_t addr, 
                             uint64_t value, 
                             uint64_t size) {
    vx_device* device = (vx_device*)hdevice;
    
    char msg[256];
    snprintf(msg, sizeof(msg), "CSR_WRITE %llx %llx", 
             (unsigned long long)addr, (unsigned long long)value);
    send(device->sockfd, msg, strlen(msg), 0);
    
    return 0;
}
```

**VCS Side (개선된 구현)**:
```cpp
// sim/vcs/vcs_server.cpp
#include <svdpi.h>
#include <pthread.h>
#include <queue>
#include <string>
#include <vector>

// 글로벌 상태
static std::queue<std::string> g_command_queue;
static pthread_mutex_t g_queue_mutex = PTHREAD_MUTEX_INITIALIZER;
static int g_client_sockfd = -1;
static pthread_mutex_t g_sock_mutex = PTHREAD_MUTEX_INITIALIZER;

// Server thread
void* socket_server_thread(void* arg) {
    int server_sockfd = socket(AF_INET, SOCK_STREAM, 0);
    
    // Reuse address
    int opt = 1;
    setsockopt(server_sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(5555);
    server_addr.sin_addr.s_addr = INADDR_ANY;
    
    bind(server_sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr));
    listen(server_sockfd, 1);
    
    printf("[VCS Server] Listening on port 5555...\n");
    
    while (true) {
        int client_sock = accept(server_sockfd, NULL, NULL);
        printf("[VCS Server] Client connected\n");
        
        pthread_mutex_lock(&g_sock_mutex);
        g_client_sockfd = client_sock;
        pthread_mutex_unlock(&g_sock_mutex);
        
        char buffer[4096];
        while (true) {
            int n = recv(client_sock, buffer, sizeof(buffer) - 1, 0);
            if (n <= 0) break;
            
            buffer[n] = '\0';
            
            // 명령 큐에 추가
            pthread_mutex_lock(&g_queue_mutex);
            g_command_queue.push(std::string(buffer));
            pthread_mutex_unlock(&g_queue_mutex);
            
            printf("[VCS Server] Received: %s\n", buffer);
        }
        
        pthread_mutex_lock(&g_sock_mutex);
        g_client_sockfd = -1;
        pthread_mutex_unlock(&g_sock_mutex);
        
        close(client_sock);
        printf("[VCS Server] Client disconnected\n");
    }
    
    return NULL;
}

// DPI-C functions
extern "C" void dpi_start_server() {
    pthread_t thread;
    pthread_create(&thread, NULL, socket_server_thread, NULL);
    pthread_detach(thread);
}

extern "C" int dpi_has_command() {
    pthread_mutex_lock(&g_queue_mutex);
    int has_cmd = !g_command_queue.empty() ? 1 : 0;
    pthread_mutex_unlock(&g_queue_mutex);
    return has_cmd;
}

extern "C" void dpi_get_command(char* cmd, int max_len) {
    pthread_mutex_lock(&g_queue_mutex);
    if (!g_command_queue.empty()) {
        std::string str = g_command_queue.front();
        g_command_queue.pop();
        strncpy(cmd, str.c_str(), max_len - 1);
        cmd[max_len - 1] = '\0';
    } else {
        cmd[0] = '\0';
    }
    pthread_mutex_unlock(&g_queue_mutex);
}

extern "C" void dpi_send_done() {
    pthread_mutex_lock(&g_sock_mutex);
    if (g_client_sockfd >= 0) {
        const char* msg = "DONE";
        send(g_client_sockfd, msg, strlen(msg), 0);
        printf("[VCS Server] Sent DONE\n");
    }
    pthread_mutex_unlock(&g_sock_mutex);
}

extern "C" void dpi_send_response(const char* msg) {
    pthread_mutex_lock(&g_sock_mutex);
    if (g_client_sockfd >= 0) {
        send(g_client_sockfd, msg, strlen(msg), 0);
    }
    pthread_mutex_unlock(&g_sock_mutex);
}
```

---

## DPI-C 인터페이스

### DPI-C 기본 개념

DPI-C (Direct Programming Interface for C)는 SystemVerilog와 C/C++ 간 양방향 호출을 가능하게 합니다.

#### Import (SV → C)
SystemVerilog에서 C 함수 호출:
```systemverilog
// SV에서 선언
import "DPI-C" function int my_c_function(int arg);

// SV에서 사용
int result = my_c_function(42);
```

```cpp
// C에서 구현
extern "C" int my_c_function(int arg) {
    return arg * 2;
}
```

#### Export (C → SV)
C에서 SystemVerilog task 호출:
```systemverilog
// SV에서 선언 및 구현
export "DPI-C" task my_sv_task;
task my_sv_task(int value);
    $display("Called from C: %d", value);
endtask
```

```cpp
// C에서 호출
extern "C" void my_sv_task(int value);

void some_c_function() {
    my_sv_task(123);
}
```

### Vortex VCS DPI-C 인터페이스 설계

#### 함수 목록

| 함수명 | 방향 | 설명 |
|--------|------|------|
| `dpi_start_server()` | SV → C | Socket server 시작 |
| `dpi_has_command()` | SV → C | 명령 큐 확인 |
| `dpi_get_command()` | SV → C | 명령 가져오기 |
| `dpi_send_done()` | SV → C | 완료 메시지 전송 |
| `dpi_mem_read()` | SV → C | 메모리 읽기 (DRAM 시뮬레이터) |
| `dpi_mem_write()` | SV → C | 메모리 쓰기 |
| `dpi_console_write()` | SV → C | Console output (printf) |

#### 메모리 인터페이스

```cpp
// vcs_memory.cpp
#include <svdpi.h>
#include <map>

// DRAM 시뮬레이터 (간단한 맵 기반)
static std::map<uint64_t, uint8_t> g_memory;

extern "C" void dpi_mem_write(uint64_t addr, uint64_t data, int size) {
    for (int i = 0; i < size; i++) {
        g_memory[addr + i] = (data >> (i * 8)) & 0xFF;
    }
}

extern "C" uint64_t dpi_mem_read(uint64_t addr, int size) {
    uint64_t data = 0;
    for (int i = 0; i < size; i++) {
        data |= ((uint64_t)g_memory[addr + i]) << (i * 8);
    }
    return data;
}

// Kernel binary 업로드
extern "C" void dpi_upload_kernel(const char* data, int size, uint64_t base_addr) {
    for (int i = 0; i < size; i++) {
        g_memory[base_addr + i] = data[i];
    }
    printf("[DPI] Uploaded %d bytes to 0x%llx\n", size, base_addr);
}
```

```systemverilog
// rtlsim_vcs_tb.sv
import "DPI-C" function void dpi_mem_write(longint addr, longint data, int size);
import "DPI-C" function longint dpi_mem_read(longint addr, int size);
import "DPI-C" function void dpi_upload_kernel(string data, int size, longint base_addr);

// AXI read 처리
always @(posedge clk) begin
    if (axi_arvalid && axi_arready) begin
        longint data = dpi_mem_read(axi_araddr, axi_arlen * 8);
        axi_rdata <= data;
        axi_rvalid <= 1;
    end
end

// AXI write 처리
always @(posedge clk) begin
    if (axi_awvalid && axi_awready && axi_wvalid && axi_wready) begin
        dpi_mem_write(axi_awaddr, axi_wdata, axi_wstrb);
        axi_bvalid <= 1;
    end
end
```

---

## Shared Memory 대안

### 개요
Socket보다 **훨씬 빠른** IPC 방법이지만 구현이 복잡합니다.

### 장단점

**장점**:
- **고성능**: Memory copy만 필요, kernel context switch 없음
- **Low latency**: Socket보다 10-100배 빠름
- **대용량 데이터**: Kernel binary 전송에 효율적

**단점**:
- **복잡한 동기화**: Semaphore/mutex 필요
- **플랫폼 의존성**: Linux (POSIX), Windows (Named shared memory)
- **디버깅 어려움**: Race condition, deadlock

### 구현 예시

#### 공유 메모리 구조체
```cpp
// shared_memory.h
#define SHM_NAME "/vortex_vcs_shm"
#define SHM_SIZE (64 * 1024 * 1024)  // 64MB

struct vortex_shm {
    // 제어 플래그
    volatile uint32_t host_cmd_ready;   // Host가 명령 작성 완료
    volatile uint32_t vcs_cmd_ack;      // VCS가 명령 수신 확인
    volatile uint32_t vcs_done;         // VCS 실행 완료
    
    // 명령 데이터
    char command[256];
    
    // Kernel binary
    uint32_t kernel_size;
    uint8_t kernel_data[SHM_SIZE - 1024];
};
```

#### Host Side
```cpp
// runtime/vcs/vortex_vcs_shm.cpp
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <semaphore.h>

struct vx_device {
    int shm_fd;
    vortex_shm* shm;
    sem_t* sem_host;
    sem_t* sem_vcs;
};

extern "C" int vx_dev_open(vx_device_h* hdevice) {
    vx_device* device = new vx_device();
    
    // Shared memory 생성
    device->shm_fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0666);
    ftruncate(device->shm_fd, SHM_SIZE);
    
    device->shm = (vortex_shm*)mmap(NULL, SHM_SIZE, 
                                     PROT_READ | PROT_WRITE, 
                                     MAP_SHARED, device->shm_fd, 0);
    
    // Semaphore 생성
    device->sem_host = sem_open("/vortex_sem_host", O_CREAT, 0666, 0);
    device->sem_vcs = sem_open("/vortex_sem_vcs", O_CREAT, 0666, 0);
    
    // 초기화
    memset(device->shm, 0, SHM_SIZE);
    
    *hdevice = device;
    return 0;
}

extern "C" int vx_upload_kernel_bytes(vx_device_h hdevice, 
                                       const void* content, 
                                       uint64_t size) {
    vx_device* device = (vx_device*)hdevice;
    
    // Kernel binary를 shared memory에 복사
    device->shm->kernel_size = size;
    memcpy(device->shm->kernel_data, content, size);
    
    // VCS에 UPLOAD 명령 전송
    strcpy(device->shm->command, "UPLOAD");
    __sync_synchronize();  // Memory barrier
    device->shm->host_cmd_ready = 1;
    
    // VCS signal
    sem_post(device->sem_vcs);
    
    // VCS 완료 대기
    sem_wait(device->sem_host);
    
    device->shm->host_cmd_ready = 0;
    return 0;
}

extern "C" int vx_start(vx_device_h hdevice) {
    vx_device* device = (vx_device*)hdevice;
    
    strcpy(device->shm->command, "START");
    __sync_synchronize();
    device->shm->host_cmd_ready = 1;
    
    sem_post(device->sem_vcs);
    
    return 0;
}

extern "C" int vx_ready_wait(vx_device_h hdevice, uint64_t timeout) {
    vx_device* device = (vx_device*)hdevice;
    
    // VCS 완료 대기
    sem_wait(device->sem_host);
    
    if (device->shm->vcs_done) {
        device->shm->vcs_done = 0;
        device->shm->host_cmd_ready = 0;
        return 0;
    }
    
    return -1;
}
```

#### VCS Side
```cpp
// sim/vcs/vcs_shm_server.cpp
static vortex_shm* g_shm = nullptr;
static sem_t* g_sem_host = nullptr;
static sem_t* g_sem_vcs = nullptr;

void* shm_server_thread(void* arg) {
    // Shared memory attach
    int shm_fd = shm_open(SHM_NAME, O_RDWR, 0666);
    g_shm = (vortex_shm*)mmap(NULL, SHM_SIZE, 
                               PROT_READ | PROT_WRITE, 
                               MAP_SHARED, shm_fd, 0);
    
    // Semaphore attach
    g_sem_host = sem_open("/vortex_sem_host", 0);
    g_sem_vcs = sem_open("/vortex_sem_vcs", 0);
    
    while (true) {
        // Host 명령 대기
        sem_wait(g_sem_vcs);
        
        if (g_shm->host_cmd_ready) {
            printf("[VCS SHM] Received: %s\n", g_shm->command);
            
            // 명령 처리 (testbench가 polling)
            // ...
            
            // Host에 ACK
            g_shm->vcs_cmd_ack = 1;
        }
    }
    
    return NULL;
}

extern "C" void dpi_start_shm_server() {
    pthread_t thread;
    pthread_create(&thread, NULL, shm_server_thread, NULL);
    pthread_detach(thread);
}

extern "C" int dpi_has_command() {
    return (g_shm && g_shm->host_cmd_ready) ? 1 : 0;
}

extern "C" void dpi_get_command(char* cmd, int max_len) {
    if (g_shm && g_shm->host_cmd_ready) {
        strncpy(cmd, g_shm->command, max_len - 1);
        cmd[max_len - 1] = '\0';
        g_shm->vcs_cmd_ack = 1;
    }
}

extern "C" void dpi_send_done() {
    if (g_shm) {
        g_shm->vcs_done = 1;
        __sync_synchronize();
        sem_post(g_sem_host);
    }
}

extern "C" void dpi_get_kernel_data(uint8_t* buffer, int max_size) {
    if (g_shm) {
        int size = (g_shm->kernel_size < max_size) ? 
                   g_shm->kernel_size : max_size;
        memcpy(buffer, g_shm->kernel_data, size);
    }
}
```

### 성능 비교

| IPC 방식 | Latency (us) | Bandwidth (MB/s) | 복잡도 |
|----------|--------------|------------------|--------|
| Socket (localhost) | 10-50 | 1000-5000 | 낮음 |
| Shared Memory | 0.1-1 | 10000-50000 | 높음 |
| UNIX Domain Socket | 1-10 | 5000-10000 | 중간 |

**권장 사항**:
- **개발/디버깅**: Socket 사용 (간단, 안정적)
- **성능 중요**: Shared Memory 사용 (대용량 kernel binary)

---

## 실행 방법

### 빌드

#### VCS 시뮬레이터 컴파일
```bash
# sim/vcs/ 디렉토리에서
cd sim/vcs

# DPI-C 코드 컴파일
g++ -fPIC -shared -o libvcs_server.so vcs_server.cpp vcs_memory.cpp \
    -I$VCS_HOME/include -lpthread

# VCS 컴파일
vcs -full64 -sverilog \
    -timescale=1ns/1ps \
    +define+SIMULATION \
    -debug_access+all \
    rtlsim_vcs_tb.sv \
    ../../hw/rtl/Vortex_axi.sv \
    ../../hw/rtl/**/*.sv \
    -LDFLAGS "-L. -lvcs_server -lpthread" \
    -o simv

# Post-synthesis SDF annotation (ASIC)
vcs -full64 -sverilog \
    -timescale=1ns/1ps \
    +define+SDF_ANNOTATION \
    -debug_access+all \
    rtlsim_vcs_tb.sv \
    vortex_post_synth.v \
    -sdf max:rtlsim_vcs_tb.dut:vortex.sdf \
    -LDFLAGS "-L. -lvcs_server -lpthread" \
    -o simv_sdf
```

#### Runtime 라이브러리 빌드
```bash
# runtime/vcs/ 디렉토리에서
cd runtime/vcs

g++ -fPIC -shared -o libvortex-vcs.so \
    vortex_vcs.cpp \
    -I../../include \
    -lpthread

# Shared memory 버전
g++ -fPIC -shared -o libvortex-vcs-shm.so \
    vortex_vcs_shm.cpp \
    -I../../include \
    -lpthread -lrt
```

### 실행 절차

#### 방법 1: 두 개의 터미널 사용

**Terminal 1 - VCS Simulator 실행**:
```bash
cd sim/vcs

# 시뮬레이터 시작 (백그라운드)
./simv +verbose +trace=trace.vcd &

# 또는 Verdi 파형 보기
./simv -gui +verbose +trace=trace.fsdb

# SDF annotation (ASIC timing)
./simv_sdf +verbose +trace=trace.fsdb
```

**Terminal 2 - OpenCL Application 실행**:
```bash
cd tests/opencl/sgemm

# VCS runtime 사용 설정
export LD_LIBRARY_PATH=../../../runtime/vcs:$LD_LIBRARY_PATH
export VORTEX_RUNTIME=vcs

# OpenCL 애플리케이션 실행
./sgemm

# 또는 직접 라이브러리 지정
LD_PRELOAD=../../../runtime/vcs/libvortex-vcs.so ./sgemm
```

#### 방법 2: 자동화 스크립트

```bash
#!/bin/bash
# run_vcs_test.sh

# VCS 시뮬레이터 백그라운드 실행
cd sim/vcs
./simv +verbose +trace=trace.vcd &
VCS_PID=$!

# 시뮬레이터 준비 대기
sleep 2

# OpenCL 애플리케이션 실행
cd ../../tests/opencl/sgemm
export LD_LIBRARY_PATH=../../../runtime/vcs:$LD_LIBRARY_PATH
./sgemm

# 종료
kill $VCS_PID
```

### 환경 변수

| 변수명 | 설명 | 예시 |
|--------|------|------|
| `VORTEX_RUNTIME` | 사용할 runtime 선택 | `vcs`, `rtlsim`, `simx` |
| `VCS_PORT` | Socket 포트 번호 | `5555` (기본값) |
| `VCS_TIMEOUT` | 타임아웃 (초) | `300` (5분) |
| `VCS_SHM_NAME` | Shared memory 이름 | `/vortex_vcs_shm` |
| `VCS_TRACE` | 파형 파일 경로 | `trace.fsdb` |
| `VCS_VERBOSE` | 상세 로그 출력 | `1` (활성화) |

---

## Makefile 통합

### 전체 Makefile 구조

```makefile
# sim/vcs/Makefile

# VCS 설정
VCS = vcs
VCS_FLAGS = -full64 -sverilog -timescale=1ns/1ps +define+SIMULATION
VCS_DEBUG_FLAGS = -debug_access+all +memcbk +vcs+dumparrays
VCS_LDFLAGS = -LDFLAGS "-L. -lvcs_server -lpthread"

# RTL 소스
RTL_DIR = ../../hw/rtl
RTL_SOURCES = $(shell find $(RTL_DIR) -name "*.sv" -o -name "*.v")

# DPI-C 소스
DPI_SOURCES = vcs_server.cpp vcs_memory.cpp
DPI_LIB = libvcs_server.so

# Testbench
TB_TOP = rtlsim_vcs_tb
TB_SOURCES = $(TB_TOP).sv

# 출력
SIMV = simv
SIMV_SDF = simv_sdf

# 기본 타겟
.PHONY: all clean run

all: $(SIMV)

# DPI-C 라이브러리 빌드
$(DPI_LIB): $(DPI_SOURCES)
	@echo "Building DPI-C library..."
	g++ -fPIC -shared -o $@ $(DPI_SOURCES) \
	    -I$(VCS_HOME)/include -lpthread -Wall -Wextra

# 시뮬레이터 컴파일
$(SIMV): $(DPI_LIB) $(TB_SOURCES) $(RTL_SOURCES)
	@echo "Compiling VCS simulator..."
	$(VCS) $(VCS_FLAGS) $(VCS_DEBUG_FLAGS) \
	    $(TB_SOURCES) $(RTL_SOURCES) \
	    $(VCS_LDFLAGS) -o $@

# SDF annotation (ASIC)
$(SIMV_SDF): $(DPI_LIB) $(TB_SOURCES) vortex_post_synth.v vortex.sdf
	@echo "Compiling VCS simulator with SDF..."
	$(VCS) $(VCS_FLAGS) $(VCS_DEBUG_FLAGS) \
	    +define+SDF_ANNOTATION \
	    $(TB_SOURCES) vortex_post_synth.v \
	    -sdf max:$(TB_TOP).dut:vortex.sdf \
	    $(VCS_LDFLAGS) -o $@

# 실행
run: $(SIMV)
	@echo "Running VCS simulation..."
	./$(SIMV) +verbose +trace=trace.vcd

# GUI 실행 (Verdi)
run-gui: $(SIMV)
	@echo "Running VCS with Verdi..."
	./$(SIMV) -gui +verbose +trace=trace.fsdb

# SDF 시뮬레이션
run-sdf: $(SIMV_SDF)
	@echo "Running SDF simulation..."
	./$(SIMV_SDF) +verbose +trace=trace_sdf.fsdb

# 정리
clean:
	rm -rf $(SIMV) $(SIMV_SDF) $(DPI_LIB)
	rm -rf csrc simv.daidir DVEfiles
	rm -f ucli.key vc_hdrs.h
	rm -f *.vcd *.fsdb *.log

# 도움말
help:
	@echo "Makefile targets:"
	@echo "  all       - Build VCS simulator"
	@echo "  run       - Run simulation (VCD)"
	@echo "  run-gui   - Run with Verdi (FSDB)"
	@echo "  run-sdf   - Run SDF simulation"
	@echo "  clean     - Clean build artifacts"
```

### Runtime Makefile

```makefile
# runtime/vcs/Makefile

CXX = g++
CXXFLAGS = -fPIC -Wall -Wextra -O2
INCLUDES = -I../../include
LDFLAGS = -shared -lpthread

# Socket 버전
LIB_SOCKET = libvortex-vcs.so
SOURCES_SOCKET = vortex_vcs.cpp

# Shared memory 버전
LIB_SHM = libvortex-vcs-shm.so
SOURCES_SHM = vortex_vcs_shm.cpp

.PHONY: all clean

all: $(LIB_SOCKET) $(LIB_SHM)

$(LIB_SOCKET): $(SOURCES_SOCKET)
	@echo "Building $@..."
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(INCLUDES) -o $@ $(SOURCES_SOCKET)

$(LIB_SHM): $(SOURCES_SHM)
	@echo "Building $@..."
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(INCLUDES) -o $@ $(SOURCES_SHM) -lrt

clean:
	rm -f $(LIB_SOCKET) $(LIB_SHM)

install: all
	cp $(LIB_SOCKET) $(LIB_SHM) /usr/local/lib/
	ldconfig
```

### 최상위 Makefile 통합

```makefile
# 최상위 Makefile에 추가

.PHONY: vcs-build vcs-run vcs-clean

vcs-build:
	$(MAKE) -C runtime/vcs all
	$(MAKE) -C sim/vcs all

vcs-run: vcs-build
	@echo "Starting VCS simulator..."
	cd sim/vcs && ./simv +verbose &
	@sleep 2
	@echo "Running OpenCL test..."
	cd tests/opencl/sgemm && \
	    LD_LIBRARY_PATH=../../../runtime/vcs:$$LD_LIBRARY_PATH \
	    ./sgemm

vcs-clean:
	$(MAKE) -C runtime/vcs clean
	$(MAKE) -C sim/vcs clean
```

---

## 디버깅 및 고급 기능

### 파형 분석

#### VCD (gtkwave)
```bash
# VCD 생성
./simv +trace=trace.vcd

# gtkwave로 열기
gtkwave trace.vcd
```

#### FSDB (Verdi) - 권장
```systemverilog
// testbench에 추가
initial begin
    $fsdbDumpfile("trace.fsdb");
    $fsdbDumpvars(0, rtlsim_vcs_tb);
    $fsdbDumpMDA();  // Multi-dimensional array 덤프
end
```

```bash
# Verdi 실행
verdi -ssf trace.fsdb -nologo &

# 또는 시뮬레이션과 함께
./simv -gui +trace=trace.fsdb
```

### SDF Annotation (타이밍 검증)

#### SDF 파일 준비
```bash
# Synthesis 후 SDF 파일 생성 (Design Compiler)
dc_shell> write_sdf vortex.sdf

# 또는 P&R 후 (ICC/Innovus)
innovus> write_sdf vortex.sdf
```

#### VCS에서 SDF 적용
```bash
vcs -full64 -sverilog \
    +define+SDF_ANNOTATION \
    -debug_access+all \
    rtlsim_vcs_tb.sv \
    vortex_post_synth.v \
    -sdf max:rtlsim_vcs_tb.dut:vortex.sdf \  # Max timing
    -sdf min:rtlsim_vcs_tb.dut:vortex_min.sdf \  # Min timing
    -o simv_sdf

# 실행
./simv_sdf +verbose +trace=trace_sdf.fsdb
```

#### Timing violation 확인
```systemverilog
// testbench에 추가
initial begin
    $sdf_annotate("vortex.sdf", dut, , , "MAXIMUM");
    
    // Timing check 활성화
    $timeformat(-9, 2, " ns", 10);
    $printtimescale(dut);
end

// Setup/hold violation 모니터링
always @(negedge clk) begin
    if ($setuphold(posedge clk, data, 0.1ns, 0.05ns)) begin
        $display("ERROR: Setup/Hold violation at time %t", $time);
    end
end
```

### 커버리지 분석

#### Code coverage
```bash
# Coverage 옵션으로 컴파일
vcs -full64 -sverilog \
    -cm line+cond+fsm+tgl+branch \
    -cm_dir coverage.vdb \
    rtlsim_vcs_tb.sv $(RTL_SOURCES) \
    -o simv_cov

# 실행
./simv_cov -cm line+cond+fsm+tgl+branch

# Coverage 리포트
urg -dir coverage.vdb -format both
firefox urgReport/dashboard.html
```

#### Functional coverage
```systemverilog
// testbench에 covergroup 추가
covergroup cg_opcodes @(posedge clk);
    opcode: coverpoint dut.core.decode.opcode {
        bins arithmetic[] = {ADD, SUB, MUL, DIV};
        bins memory[] = {LOAD, STORE};
        bins branch[] = {BEQ, BNE, JAL};
    }
endgroup

cg_opcodes cg_inst = new();
```

### 디버깅 팁

#### Assert 추가
```systemverilog
// testbench에 assertion 추가
assert_no_x_on_valid: assert property (
    @(posedge clk) disable iff (reset)
    axi_wvalid |-> !$isunknown(axi_wdata)
) else $error("X detected on AXI write data");

assert_response_timeout: assert property (
    @(posedge clk) disable iff (reset)
    axi_arvalid |-> ##[1:100] axi_rvalid
) else $error("AXI read response timeout");
```

#### Printf 디버깅
```cpp
// DPI-C에서 testbench로 메시지 전달
extern "C" void dpi_debug_print(const char* msg) {
    printf("[DPI DEBUG] %s\n", msg);
    fflush(stdout);
}
```

```systemverilog
import "DPI-C" function void dpi_debug_print(string msg);

always @(posedge clk) begin
    if (debug_enable) begin
        dpi_debug_print($sformatf("PC=0x%h, instr=0x%h", pc, instruction));
    end
end
```

#### GDB로 DPI-C 디버깅
```bash
# 디버그 심볼로 컴파일
g++ -g -fPIC -shared -o libvcs_server.so vcs_server.cpp -lpthread

# GDB attach
./simv &
gdb -p $(pgrep simv)

# Breakpoint 설정
(gdb) break dpi_get_command
(gdb) continue
```

### 성능 프로파일링

#### VCS 프로파일링
```bash
# 프로파일링 옵션으로 실행
./simv +vcs+profile+all

# 리포트 확인
cat profile.txt
```

#### DPI-C 프로파일링
```cpp
#include <chrono>

extern "C" void dpi_get_command(char* cmd, int max_len) {
    auto start = std::chrono::high_resolution_clock::now();
    
    // ... 실제 작업 ...
    
    auto end = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
    
    printf("[PROFILE] dpi_get_command: %lld us\n", duration.count());
}
```

### 고급 최적화

#### 병렬 시뮬레이션
```bash
# Multi-core 시뮬레이션
vcs -full64 -sverilog \
    +vcs+initreg+random \
    -partcomp \  # Parallel compilation
    -j8 \        # 8 threads
    rtlsim_vcs_tb.sv $(RTL_SOURCES) \
    -o simv_parallel

./simv_parallel +ntb_random_seed=1234
```

#### 증분 컴파일
```bash
# 첫 컴파일
vcs -full64 -sverilog -save simv_snapshot \
    rtlsim_vcs_tb.sv $(RTL_SOURCES)

# 일부 수정 후 재컴파일 (빠름)
vcs -full64 -sverilog -restore simv_snapshot \
    rtlsim_vcs_tb.sv $(RTL_SOURCES)
```

---

## 요약

### 핵심 차이점

| 항목 | Verilator | VCS |
|------|-----------|-----|
| 프로세스 | Single | Multi |
| 통신 방식 | 직접 멤버 접근 | Socket/SHM IPC |
| 타이밍 | Cycle-accurate | Gate-level + SDF |
| 용도 | Functional | ASIC timing |
| 속도 | 빠름 | 느림 |

### 구현 체크리스트

- [ ] `sim/vcs/` 디렉토리 생성
- [ ] DPI-C 서버 구현 (`vcs_server.cpp`, `vcs_memory.cpp`)
- [ ] Testbench 작성 (`rtlsim_vcs_tb.sv`)
- [ ] Runtime 라이브러리 구현 (`runtime/vcs/vortex_vcs.cpp`)
- [ ] Makefile 작성 및 통합
- [ ] 테스트 실행 (OpenCL app)
- [ ] 파형 분석 (Verdi)
- [ ] SDF annotation 적용 및 타이밍 검증
- [ ] Coverage 분석
- [ ] 성능 최적화 (필요 시 Shared Memory 전환)

### 다음 단계

1. **기본 구현**: Socket 기반 프로토타입 완성
2. **기능 검증**: OpenCL 애플리케이션으로 functional test
3. **타이밍 검증**: SDF annotation으로 ASIC timing 확인
4. **성능 최적화**: Shared Memory로 전환 (필요 시)
5. **자동화**: CI/CD 스크립트 작성

---

*문서 작성일: 2025-12-22*
*Vortex GPGPU Project - VCS RTL Simulation Integration Guide*
