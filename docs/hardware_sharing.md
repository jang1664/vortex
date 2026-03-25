# Vortex Hardware Resource Sharing Analysis

Vortex 프로세서의 주요 하드웨어 리소스(CSR, GPR, Cache, Local Memory)가 어떤 단위로 공유되는지 분석한 문서입니다.

## 1. CSR (Control and Status Registers)

CSR은 종류에 따라 공유 범위가 다릅니다.

### 1.1 Core Shared (코어 단위 공유)
하나의 Core 내에 존재하는 모든 Warp와 Thread가 동일한 레지스터 인스턴스를 공유합니다.
*   **대상**: `VX_CSR_MSCRATCH`, Performance Counters (`MCYCLE`, `MINSTRET`, `MPM_*`), Configuration (`NUM_THREADS`, `NUM_WARPS`, `NUM_CORES`), 일부 System CSR 주소들.
*   **분석**:
    *   `mscratch`는 Core마다 1개 레지스터로 구현되어 Core 내 모든 Warp가 공유합니다.
    *   System CSR 주소들(예: `SATP`, `MSTATUS`, `MEPC`)은 현재 RTL에서 “읽기 0 / 쓰기 무시(do nothing)”로 처리됩니다(즉, 주소는 존재하되 실기능은 구현되지 않은 형태).
*   **출처**:
    *   `mscratch` 단일 레지스터 및 MSCRATCH R/W: [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L78-L181)
    *   System CSR 쓰기 무시: [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L133-L145)
    *   System CSR 읽기 0: [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L194-L206)

```systemverilog
// hw/rtl/core/VX_csr_data.sv (발췌)
reg [`XLEN-1:0] mscratch;

always @(posedge clk) begin
    if (reset) begin
        mscratch <= base_dcrs.startup_arg;
    end
    if (write_enable) begin
        case (write_addr)
            `VX_CSR_MSCRATCH: begin
                mscratch <= write_data;
            end
            default: begin
                // ...
            end
        endcase
    end
end

// read path (발췌)
`VX_CSR_MSCRATCH: read_data_rw_w = mscratch;
```

### 1.2 Warp Private (Warp 단위 독립)
각 Warp마다 별도의 레지스터 공간을 가집니다. 같은 Warp 내의 Thread들은 값을 공유하지만, 다른 Warp와는 독립적입니다.
*   **대상**: `FCSR`, `FFLAGS`, `FRM` (Floating Point Control), `WARP_ID`, `ACTIVE_THREADS`.
*   **분석**: `VX_csr_data.sv`에서 `fcsr`가 `NUM_WARPS` 크기의 배열로 선언되어 있습니다.
*   **출처**:
    *   `fcsr`가 Warp 수만큼 배열: [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L81-L122)
    *   `WARP_ID`, `ACTIVE_THREADS`가 `read_wid`(Warp ID)로 인덱싱: [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L178-L181)

```systemverilog
// hw/rtl/core/VX_csr_data.sv
reg [`NUM_WARPS-1:0][INST_FRM_BITS+`FP_FLAGS_BITS-1:0] fcsr, fcsr_n; // Warp 개수만큼 배열 (Warp Private)
```

### 1.3 Thread Private (Thread 단위 생성)
물리적인 저장 공간이 따로 있다기보다, 읽기 요청 시 하드웨어(Lane ID)에 따라 동적으로 생성되는 값입니다.
*   **대상**: `VX_CSR_THREAD_ID`, `VX_CSR_MHARTID`.
*   **분석**:
    *   `VX_CSR_THREAD_ID`는 `pid`(lane 묶음 내 위치)와 `NUM_LANES`를 조합해 lane별 thread id를 생성합니다.
    *   `VX_CSR_MHARTID`는 `CORE_ID`, `WARP_ID(read_wid)`, `THREAD_ID(wtid)`를 조합해 전역 하드웨어 thread id를 생성합니다.
*   **출처**: [hw/rtl/core/VX_csr_unit.sv](hw/rtl/core/VX_csr_unit.sv#L112-L139)

```systemverilog
// hw/rtl/core/VX_csr_unit.sv
for (genvar i = 0; i < NUM_LANES; ++i) begin : g_wtid
    if (PID_BITS != 0) begin : g_pid
        assign wtid[i] = `XLEN'(execute_if.data.pid * NUM_LANES + i);
    end else begin : g_no_pid
        assign wtid[i] = `XLEN'(i);
    end
end

for (genvar i = 0; i < NUM_LANES; ++i) begin : g_gtid
    assign gtid[i] = (`XLEN'(CORE_ID) << (NW_BITS + NT_BITS))
                   + (`XLEN'(execute_if.data.wid) << NT_BITS)
                   + wtid[i];
end
```

## 2. GPR (General Purpose Registers)

*   **공유 단위**:
    *   **Core Private**: GPR 저장소는 Core 내부(`VX_opc_unit`)에 존재하므로 코어 간 공유되지 않습니다.
    *   **논리적 Thread Private**: 각 thread는 독립적인 레지스터 집합을 가진 것처럼 보이지만, 물리적으로는 “Warp + 레지스터 번호” 단위로 묶어서 저장합니다.
*   **설명**:
    *   `BANK_DATA_WIDTH = XLEN * SIMD_WIDTH`로, 한 엔트리가 SIMD lanes(=thread lanes)들의 레지스터 값을 “벡터”로 들고 있습니다.
    *   `BANK_SIZE` 계산에 `PER_OPC_WARPS`가 포함되어 있어, warp 차원으로 레지스터 파일이 분할되어 있음을 보여줍니다.
    *   read 주소 생성에서 wid 계열 비트(PER_OPC_NW_BITS)가 주소에 포함되어, warp에 따라 다른 레지스터 공간을 사용합니다.
*   **출처**:
    *   bank 폭/크기 정의: [hw/rtl/core/VX_opc_unit.sv](hw/rtl/core/VX_opc_unit.sv#L43-L55)
    *   GPR RAM 및 warp 포함 주소 생성: [hw/rtl/core/VX_opc_unit.sv](hw/rtl/core/VX_opc_unit.sv#L259-L307)

```systemverilog
// hw/rtl/core/VX_opc_unit.sv
// GPR banks
for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_gpr_rams
    // ...
    VX_dp_ram #(
        .DATAW (BANK_DATA_WIDTH), // XLEN * SIMD_WIDTH
        .SIZE  (BANK_SIZE),       // (NUM_REGS * SIMD_COUNT * PER_OPC_WARPS) / NUM_BANKS
        // ...
    ) gpr_ram (
        // ...
        .raddr (gpr_rd_addr), // Warp ID + Reg Index
        .rdata (gpr_rd_data_st2[b])
    );
end
```

## 3. Local Memory (Shared Memory)

*   **공유 단위**: **Core Shared**
*   **설명**: 하나의 Core 내에 있는 모든 Warp와 Thread가 공유하는 메모리 공간입니다.
    *   `VX_core` 내부에 `VX_mem_unit`이 인스턴스화되고,
    *   그 `VX_mem_unit` 내부에 `VX_local_mem local_mem`이 1개 인스턴스화됩니다.
*   **출처**:
    *   `VX_core` 안의 `VX_mem_unit` 인스턴스: [hw/rtl/core/VX_core.sv](hw/rtl/core/VX_core.sv#L201-L219)
    *   `VX_mem_unit` 안의 `VX_local_mem` 인스턴스: [hw/rtl/core/VX_mem_unit.sv](hw/rtl/core/VX_mem_unit.sv#L107-L131)

```systemverilog
// hw/rtl/core/VX_mem_unit.sv
VX_local_mem #(
    .INSTANCE_ID(`SFORMATF(("%s-lmem", INSTANCE_ID))),
    .SIZE       (1 << `LMEM_LOG_SIZE),
    // ...
) local_mem (
    // ...
);
```

## 4. L1 Cache (I-Cache, D-Cache)

*   **공유 단위**: **Socket Shared**
*   **설명**: `VX_socket` 모듈에서 `VX_cache_cluster`가 인스턴스화되며, 소켓 내의 여러 Core(`SOCKET_SIZE`)들이 이 캐시 클러스터를 공유합니다.
*   **출처**: I/D cache 모두 `.NUM_INPUTS (`SOCKET_SIZE)`로 소켓 내 코어들을 입력으로 받음: [hw/rtl/VX_socket.sv](hw/rtl/VX_socket.sv#L78-L167)

```systemverilog
// hw/rtl/VX_socket.sv
VX_cache_cluster #(
    // ...
    .NUM_INPUTS     (`SOCKET_SIZE), // 소켓 내 코어 수만큼 입력 포트 존재
    // ...
) icache (
    // ...
    .core_bus_if    (per_core_icache_bus_if), // 코어들과 연결
    // ...
);
```

## 요약 표

| 리소스 | 공유 단위 | 비고 | 근거 |
| :--- | :--- | :--- | :--- |
| CSR (MSCRATCH) | Core Shared | Core 내 모든 Warp가 공유 | [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L78-L181) |
| CSR (System 일부 주소) | Core Shared (기능 미구현) | 읽기 0 / 쓰기 무시 | [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L133-L145) / [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L194-L206) |
| CSR (FPU) | Warp Private | Warp별 상태 유지 | [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L81-L122) |
| CSR (WARP_ID, ACTIVE_THREADS) | Warp Private | `read_wid`로 인덱싱 | [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L178-L181) |
| CSR (THREAD_ID, MHARTID) | Thread Private (동적 생성) | lane/pid 및 core/warp 조합 | [hw/rtl/core/VX_csr_unit.sv](hw/rtl/core/VX_csr_unit.sv#L112-L139) |
| GPR | Core Private + 논리적 Thread Private | SIMD lane 벡터로 저장, warp 포함 주소화 | [hw/rtl/core/VX_opc_unit.sv](hw/rtl/core/VX_opc_unit.sv#L43-L55) / [hw/rtl/core/VX_opc_unit.sv](hw/rtl/core/VX_opc_unit.sv#L259-L307) |
| Local Memory | Core Shared | Core 내부에 1개 인스턴스 | [hw/rtl/core/VX_core.sv](hw/rtl/core/VX_core.sv#L201-L219) / [hw/rtl/core/VX_mem_unit.sv](hw/rtl/core/VX_mem_unit.sv#L107-L131) |
| L1 Cache (I/D) | Socket Shared | 소켓 내 코어 입력(`SOCKET_SIZE`) 공유 | [hw/rtl/VX_socket.sv](hw/rtl/VX_socket.sv#L78-L167) |
