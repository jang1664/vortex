// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`ifndef VX_CONFIG_VH
`define VX_CONFIG_VH

`ifndef MIN
`define MIN(x, y)   (((x) < (y)) ? (x) : (y))
`endif

`ifndef MAX
`define MAX(x, y)   (((x) > (y)) ? (x) : (y))
`endif

`ifndef CLAMP
`define CLAMP(x, lo, hi)   (((x) > (hi)) ? (hi) : (((x) < (lo)) ? (lo) : (x)))
`endif

`ifndef UP
`define UP(x)   (((x) != 0) ? (x) : 1)
`endif

///////////////////////////////////////////////////////////////////////////////

`ifndef EXT_M_DISABLE
`define EXT_M_ENABLE
`endif

`ifndef EXT_F_DISABLE
`define EXT_F_ENABLE
`endif

`ifndef SV_DPI
`ifndef DPI_DISABLE
`define DPI_DISABLE
`endif
`endif

`ifndef FPU_FPNEW
`ifndef FPU_DSP
`ifndef FPU_DPI
`ifndef SYNTHESIS
`ifndef DPI_DISABLE
`define FPU_DPI
`else
`define FPU_DSP
`endif
`else
`define FPU_DSP
`endif
`endif
`endif
`endif

`ifdef XLEN_64
`ifndef FPU_DSP
`ifndef EXT_D_DISABLE
`define EXT_D_ENABLE
`endif
`endif
`endif

`ifndef EXT_ZICOND_DISABLE
`define EXT_ZICOND_ENABLE
`endif

`ifndef XLEN_32
`ifndef XLEN_64
`define XLEN_32
`endif
`endif

`ifdef XLEN_64
`define XLEN 64
`endif

`ifdef XLEN_32
`define XLEN 32
`endif

`ifdef EXT_D_ENABLE
`define FLEN_64
`else
`define FLEN_32
`endif

`ifdef FLEN_64
`define FLEN 64
`endif

`ifdef FLEN_32
`define FLEN 32
`endif

`ifdef XLEN_64
`ifdef FLEN_32
    `define FPU_RV64F
`endif
`endif

`ifndef VLEN
`define VLEN (4 * `XLEN)
`endif

`ifndef NUM_CLUSTERS
`define NUM_CLUSTERS 1
`endif

`ifndef NUM_CORES
`define NUM_CORES 1
`endif

`ifndef NUM_WARPS
`define NUM_WARPS 4
`endif

`ifndef NUM_THREADS
`define NUM_THREADS 4
`endif

`ifndef NUM_BARRIERS
`define NUM_BARRIERS `UP(`NUM_WARPS/2)
`endif

`ifndef SOCKET_SIZE
`define SOCKET_SIZE `MIN(4, `NUM_CORES)
`endif

`ifdef L1_DISABLE
    `define ICACHE_DISABLE
    `define DCACHE_DISABLE
`endif

`ifndef MEM_BLOCK_SIZE
`define MEM_BLOCK_SIZE 64
`endif

`ifndef MEM_ADDR_WIDTH
`ifdef XLEN_64
`define MEM_ADDR_WIDTH 34
`else
`define MEM_ADDR_WIDTH 32
`endif
`endif

`ifndef L1_LINE_SIZE
`define L1_LINE_SIZE `MEM_BLOCK_SIZE
`endif

`ifndef L2_LINE_SIZE
`define L2_LINE_SIZE `MEM_BLOCK_SIZE
`endif

`ifndef L3_LINE_SIZE
`define L3_LINE_SIZE `MEM_BLOCK_SIZE
`endif

// Platform memory parameters

`ifndef PLATFORM_MEMORY_NUM_BANKS
`define PLATFORM_MEMORY_NUM_BANKS 2
`endif

`ifndef PLATFORM_MEMORY_ADDR_WIDTH
`ifdef XLEN_64
    `define PLATFORM_MEMORY_ADDR_WIDTH 34
`else
    `define PLATFORM_MEMORY_ADDR_WIDTH 32
`endif
`endif

`ifndef PLATFORM_MEMORY_DATA_SIZE
`define PLATFORM_MEMORY_DATA_SIZE 64
`endif

`ifndef PLATFORM_MEMORY_INTERLEAVE
`define PLATFORM_MEMORY_INTERLEAVE 1
`endif

`ifdef XLEN_64

`ifndef STACK_BASE_ADDR
`define STACK_BASE_ADDR 64'h1ffc00000
`endif

`ifndef STARTUP_ADDR
`define STARTUP_ADDR    64'h080000000
`endif

`ifndef USER_BASE_ADDR
`define USER_BASE_ADDR  64'h000010000
`endif

`ifndef IO_BASE_ADDR
`define IO_BASE_ADDR    64'h000000040
`endif

`ifdef VM_ENABLE
`ifndef PAGE_TABLE_BASE_ADDR
`define PAGE_TABLE_BASE_ADDR 64'h0F0000000
`endif

`endif

`else // XLEN_32

`ifndef STACK_BASE_ADDR
`define STACK_BASE_ADDR 32'hFFFF0000
`endif

`ifndef STARTUP_ADDR
`define STARTUP_ADDR    32'h80000000
`endif

`ifndef USER_BASE_ADDR
`define USER_BASE_ADDR  32'h00010000
`endif

`ifndef IO_BASE_ADDR
`define IO_BASE_ADDR    32'h00000040
`endif

`ifdef VM_ENABLE
`ifndef PAGE_TABLE_BASE_ADDR
`define PAGE_TABLE_BASE_ADDR 32'hF0000000
`endif

`endif

`endif

`define IO_END_ADDR     `USER_BASE_ADDR

`ifndef LMEM_LOG_SIZE
`define LMEM_LOG_SIZE   21
`endif

`ifndef LMEM_BASE_ADDR
`define LMEM_BASE_ADDR  `STACK_BASE_ADDR
`endif

`ifndef LMEM_DMA_RD_PREFETCH_DEPTH
`define LMEM_DMA_RD_PREFETCH_DEPTH 4
`endif

`ifndef IO_COUT_ADDR
`define IO_COUT_ADDR    `IO_BASE_ADDR
`endif
`define IO_COUT_SIZE    64

`ifndef IO_MPM_ADDR
`define IO_MPM_ADDR     (`IO_COUT_ADDR + `IO_COUT_SIZE)
`endif

`ifndef STACK_LOG2_SIZE
`define STACK_LOG2_SIZE 13
`endif

`define RESET_DELAY     8

`ifndef STALL_TIMEOUT
`define STALL_TIMEOUT   (100000 * (1 ** (`L2_ENABLED + `L3_ENABLED)))
`endif

`ifndef SYNTHESIS
`ifndef DPI_DISABLE
`define IMUL_DPI
`define IDIV_DPI
`endif
`endif

`ifndef DEBUG_LEVEL
`define DEBUG_LEVEL 3
`endif

`ifndef MEM_PAGE_SIZE
`define MEM_PAGE_SIZE (4096)
`endif

`ifndef MEM_PAGE_LOG2_SIZE
`define MEM_PAGE_LOG2_SIZE (12)
`endif

// Virtual Memory Configuration ///////////////////////////////////////////////
`ifdef VM_ENABLE
    `ifdef XLEN_32
        `ifndef VM_ADDR_MODE
        `define VM_ADDR_MODE SV32  //or BARE
        `endif
        `ifndef PT_LEVEL
        `define PT_LEVEL (2)
        `endif
        `ifndef PTE_SIZE
        `define PTE_SIZE (4)
        `endif
        `ifndef NUM_PTE_ENTRY
        `define NUM_PTE_ENTRY (1024)
        `endif
        `ifndef PT_SIZE_LIMIT
        `define PT_SIZE_LIMIT (1<<23)
        `endif
    `else
        `ifndef VM_ADDR_MODE
        `define VM_ADDR_MODE SV39 //or BARE
        `endif
        `ifndef PT_LEVEL
        `define PT_LEVEL (3)
        `endif
        `ifndef PTE_SIZE
        `define PTE_SIZE (8)
        `endif
        `ifndef NUM_PTE_ENTRY
        `define NUM_PTE_ENTRY (512)
        `endif
        `ifndef PT_SIZE_LIMIT
        `define PT_SIZE_LIMIT (1<<25)
        `endif
    `endif

    `ifndef PT_SIZE
    `define PT_SIZE MEM_PAGE_SIZE
    `endif

    `ifndef TLB_SIZE
    `define TLB_SIZE (32)
    `endif

`endif

// Pipeline Configuration /////////////////////////////////////////////////////

`ifndef SIMD_WIDTH
`define SIMD_WIDTH      `NUM_THREADS
`endif

// Issue width
`ifndef ISSUE_WIDTH
`define ISSUE_WIDTH     `UP(`NUM_WARPS / 16)
`endif

// Operand collectors
`ifndef NUM_OPCS
`define NUM_OPCS        `UP(`NUM_WARPS / (4 * `ISSUE_WIDTH))
`endif

// Register File Banks
`ifndef NUM_GPR_BANKS
`define NUM_GPR_BANKS   4
`endif
`ifndef NUM_VGPR_BANKS
`define NUM_VGPR_BANKS  2
`endif

// Number of ALU units
`ifndef NUM_ALU_LANES
`define NUM_ALU_LANES   `SIMD_WIDTH
`endif
`ifndef NUM_ALU_BLOCKS
`define NUM_ALU_BLOCKS  `ISSUE_WIDTH
`endif

// Number of FPU units
`ifndef NUM_FPU_LANES
`define NUM_FPU_LANES   `SIMD_WIDTH
`endif
`ifndef NUM_FPU_BLOCKS
`define NUM_FPU_BLOCKS  `ISSUE_WIDTH
`endif

// Number of LSU units
`ifndef NUM_LSU_LANES
`define NUM_LSU_LANES   `SIMD_WIDTH
`endif
`ifndef NUM_LSU_BLOCKS
`define NUM_LSU_BLOCKS  1
`endif

// Number of SFU units
`ifndef NUM_SFU_LANES
`define NUM_SFU_LANES   `SIMD_WIDTH
`endif
`define NUM_SFU_BLOCKS  1

// Number of VPU units
`ifndef NUM_VPU_LANES
`define NUM_VPU_LANES   `SIMD_WIDTH
`endif
`ifndef NUM_VPU_BLOCKS
`define NUM_VPU_BLOCKS  `ISSUE_WIDTH
`endif

// Number of TCU units
`define NUM_TCU_LANES   `NUM_THREADS
`ifndef NUM_TCU_BLOCKS
`define NUM_TCU_BLOCKS  `ISSUE_WIDTH
`endif

// Size of Instruction Buffer
`ifndef IBUF_SIZE
`define IBUF_SIZE   4
`endif

// LSU line size
`ifndef LSU_LINE_SIZE
`define LSU_LINE_SIZE   `MIN(`NUM_LSU_LANES * (`XLEN / 8), `L1_LINE_SIZE)
`endif

// Size of LSU Core Request Queue
`ifndef LSUQ_IN_SIZE
`define LSUQ_IN_SIZE    (2 * (`SIMD_WIDTH / `NUM_LSU_LANES))
`endif

// Size of LSU Memory Request Queue
`ifndef LSUQ_OUT_SIZE
`define LSUQ_OUT_SIZE   `MAX(`LSUQ_IN_SIZE, `LSU_LINE_SIZE / (`XLEN / 8))
`endif

// Floating-Point Units ///////////////////////////////////////////////////////

// Size of FPU Request Queue
`ifndef FPUQ_SIZE
`define FPUQ_SIZE (2 * (`SIMD_WIDTH / `NUM_FPU_LANES))
`endif

// FNCP Latency
`ifndef LATENCY_FNCP
`define LATENCY_FNCP 2
`endif

// FMA Latency
`ifndef LATENCY_FMA
`ifdef FPU_DPI
`define LATENCY_FMA 4
`endif
`ifdef FPU_FPNEW
`define LATENCY_FMA 4
`endif
`ifdef FPU_DSP
`ifdef QUARTUS
`define LATENCY_FMA 4
`endif
`ifdef VIVADO
`define LATENCY_FMA 16
`endif
`ifndef LATENCY_FMA
`define LATENCY_FMA 4
`endif
`endif
`endif

// FDIV Latency
`ifndef LATENCY_FDIV
`ifdef FPU_DPI
`define LATENCY_FDIV 15
`endif
`ifdef FPU_FPNEW
`define LATENCY_FDIV 16
`endif
`ifdef FPU_DSP
`ifdef QUARTUS
`define LATENCY_FDIV 15
`endif
`ifdef VIVADO
`define LATENCY_FDIV 28
`endif
`ifndef LATENCY_FDIV
`define LATENCY_FDIV 16
`endif
`endif
`endif

// FSQRT Latency
`ifndef LATENCY_FSQRT
`ifdef FPU_DPI
`define LATENCY_FSQRT 10
`endif
`ifdef FPU_FPNEW
`define LATENCY_FSQRT 16
`endif
`ifdef FPU_DSP
`ifdef QUARTUS
`define LATENCY_FSQRT 10
`endif
`ifdef VIVADO
`define LATENCY_FSQRT 28
`endif
`ifndef LATENCY_FSQRT
`define LATENCY_FSQRT 16
`endif
`endif
`endif

// FCVT Latency
`ifndef LATENCY_FCVT
`define LATENCY_FCVT 5
`endif

// FMA Bandwidth ratio
`ifndef FMA_PE_RATIO
`define FMA_PE_RATIO 1
`endif

// FDIV Bandwidth ratio
`ifndef FDIV_PE_RATIO
`define FDIV_PE_RATIO 8
`endif

// FSQRT Bandwidth ratio
`ifndef FSQRT_PE_RATIO
`define FSQRT_PE_RATIO 8
`endif

// FCVT Bandwidth ratio
`ifndef FCVT_PE_RATIO
`define FCVT_PE_RATIO 8
`endif

// FNCP Bandwidth ratio
`ifndef FNCP_PE_RATIO
`define FNCP_PE_RATIO 2
`endif

// Icache Configurable Knobs //////////////////////////////////////////////////

// Cache Enable
`ifndef ICACHE_DISABLE
`define ICACHE_ENABLE
`endif

`ifndef ICACHE_ENABLE
    `define NUM_ICACHES 0
`endif

// Number of Cache Units
`ifndef NUM_ICACHES
`define NUM_ICACHES `UP(`SOCKET_SIZE / 4)
`endif

// Cache Size
`ifndef ICACHE_SIZE
`define ICACHE_SIZE 16384
`endif

// Core Response Queue Size
`ifndef ICACHE_CRSQ_SIZE
`define ICACHE_CRSQ_SIZE 2
`endif

// Miss Handling Register Size
`ifndef ICACHE_MSHR_SIZE
`define ICACHE_MSHR_SIZE 16
`endif

// Memory Request Queue Size
`ifndef ICACHE_MREQ_SIZE
`define ICACHE_MREQ_SIZE 4
`endif

// Memory Response Queue Size
`ifndef ICACHE_MRSQ_SIZE
`define ICACHE_MRSQ_SIZE 0
`endif

// Number of Associative Ways
`ifndef ICACHE_NUM_WAYS
`define ICACHE_NUM_WAYS 4
`endif

// Replacement Policy
`ifndef ICACHE_REPL_POLICY
`define ICACHE_REPL_POLICY 1
`endif

`ifndef ICACHE_MEM_PORTS
`define ICACHE_MEM_PORTS 1
`endif

// Dcache Configurable Knobs //////////////////////////////////////////////////

// Cache Enable
`ifndef DCACHE_DISABLE
`define DCACHE_ENABLE
`endif

`ifndef DCACHE_ENABLE
    `define NUM_DCACHES 0
    `define DCACHE_NUM_BANKS 1
`endif

// Number of Cache Units
`ifndef NUM_DCACHES
`define NUM_DCACHES `UP(`SOCKET_SIZE / 4)
`endif

// Cache Size
`ifndef DCACHE_SIZE
`define DCACHE_SIZE 16384
`endif

// Number of Banks
`ifndef DCACHE_NUM_BANKS
`define DCACHE_NUM_BANKS `MIN(DCACHE_NUM_REQS, 16)
`endif

// Core Response Queue Size
`ifndef DCACHE_CRSQ_SIZE
`define DCACHE_CRSQ_SIZE 2
`endif

// Miss Handling Register Size
`ifndef DCACHE_MSHR_SIZE
`define DCACHE_MSHR_SIZE 16
`endif

// Memory Request Queue Size
`ifndef DCACHE_MREQ_SIZE
`define DCACHE_MREQ_SIZE 4
`endif

// Memory Response Queue Size
`ifndef DCACHE_MRSQ_SIZE
`define DCACHE_MRSQ_SIZE 4
`endif

// Number of Associative Ways
`ifndef DCACHE_NUM_WAYS
`define DCACHE_NUM_WAYS 4
`endif

// Enable Cache Writeback
`ifndef DCACHE_WRITEBACK
`define DCACHE_WRITEBACK 0
`endif

// Enable Cache Dirty bytes
`ifndef DCACHE_DIRTYBYTES
`define DCACHE_DIRTYBYTES `DCACHE_WRITEBACK
`endif

// Replacement Policy
`ifndef DCACHE_REPL_POLICY
`define DCACHE_REPL_POLICY 1
`endif

// Number of Memory Ports
`ifndef L1_MEM_PORTS
`ifdef L1_DISABLE
`define L1_MEM_PORTS `MIN(DCACHE_NUM_REQS, `PLATFORM_MEMORY_NUM_BANKS)
`else
`define L1_MEM_PORTS `MIN(`DCACHE_NUM_BANKS, `PLATFORM_MEMORY_NUM_BANKS)
`endif
`endif

// LMEM Configurable Knobs ////////////////////////////////////////////////////

`ifndef LMEM_DISABLE
`define LMEM_ENABLE
`endif

`ifndef LMEM_ENABLE
    `define LMEM_NUM_BANKS 1
`endif

// Number of Banks
`ifndef LMEM_NUM_BANKS
`define LMEM_NUM_BANKS `NUM_LSU_LANES
`endif

// L2cache Configurable Knobs /////////////////////////////////////////////////

// Cache Size
`ifndef L2_CACHE_SIZE
`define L2_CACHE_SIZE 1048576
`endif

// Number of Banks
`ifndef L2_NUM_BANKS
`define L2_NUM_BANKS `MIN(L2_NUM_REQS, 16)
`endif

// Core Response Queue Size
`ifndef L2_CRSQ_SIZE
`define L2_CRSQ_SIZE 2
`endif

// Miss Handling Register Size
`ifndef L2_MSHR_SIZE
`define L2_MSHR_SIZE 16
`endif

// Memory Request Queue Size
`ifndef L2_MREQ_SIZE
`define L2_MREQ_SIZE 4
`endif

// Memory Response Queue Size
`ifndef L2_MRSQ_SIZE
`define L2_MRSQ_SIZE 4
`endif

// Number of Associative Ways
`ifndef L2_NUM_WAYS
`define L2_NUM_WAYS 8
`endif

// Enable Cache Writeback
`ifndef L2_WRITEBACK
`define L2_WRITEBACK 0
`endif

// Enable Cache Dirty bytes
`ifndef L2_DIRTYBYTES
`define L2_DIRTYBYTES `L2_WRITEBACK
`endif

// Replacement Policy
`ifndef L2_REPL_POLICY
`define L2_REPL_POLICY 1
`endif

// Number of Memory Ports
`ifndef L2_MEM_PORTS
`ifdef L2_ENABLE
`define L2_MEM_PORTS `MIN(`L2_NUM_BANKS, `PLATFORM_MEMORY_NUM_BANKS)
`else
`define L2_MEM_PORTS `MIN(L2_NUM_REQS, `PLATFORM_MEMORY_NUM_BANKS)
`endif
`endif

// L3cache Configurable Knobs /////////////////////////////////////////////////

// Cache Size
`ifndef L3_CACHE_SIZE
`define L3_CACHE_SIZE 2097152
`endif

// Number of Banks
`ifndef L3_NUM_BANKS
`define L3_NUM_BANKS `MIN(L3_NUM_REQS, 16)
`endif

// Core Response Queue Size
`ifndef L3_CRSQ_SIZE
`define L3_CRSQ_SIZE 2
`endif

// Miss Handling Register Size
`ifndef L3_MSHR_SIZE
`define L3_MSHR_SIZE 16
`endif

// Memory Request Queue Size
`ifndef L3_MREQ_SIZE
`define L3_MREQ_SIZE 4
`endif

// Memory Response Queue Size
`ifndef L3_MRSQ_SIZE
`define L3_MRSQ_SIZE 4
`endif

// Number of Associative Ways
`ifndef L3_NUM_WAYS
`define L3_NUM_WAYS 8
`endif

// Enable Cache Writeback
`ifndef L3_WRITEBACK
`define L3_WRITEBACK 0
`endif

// Enable Cache Dirty bytes
`ifndef L3_DIRTYBYTES
`define L3_DIRTYBYTES `L3_WRITEBACK
`endif

// Replacement Policy
`ifndef L3_REPL_POLICY
`define L3_REPL_POLICY 1
`endif

// Number of Memory Ports
`ifndef L3_MEM_PORTS
`ifdef L3_ENABLE
`define L3_MEM_PORTS `MIN(`L3_NUM_BANKS, `PLATFORM_MEMORY_NUM_BANKS)
`else
`define L3_MEM_PORTS `MIN(L3_NUM_REQS, `PLATFORM_MEMORY_NUM_BANKS)
`endif
`endif

// TCU Configurable Knobs /////////////////////////////////////////////////////

`ifndef TCU_DRL
`ifndef TCU_BHF
`ifndef TCU_DSP
`ifndef TCU_DPI

`ifndef SYNTHESIS
`ifndef DPI_DISABLE
`define TCU_DPI
`else
`define TCU_BHF
`endif
`else
`define TCU_DSP
`endif

`endif
`endif
`endif
`endif

// ISA Extensions /////////////////////////////////////////////////////////////

`ifdef ICACHE_ENABLE
    `define ICACHE_ENABLED 1
`else
    `define ICACHE_ENABLED 0
`endif

`ifdef DCACHE_ENABLE
    `define DCACHE_ENABLED 1
`else
    `define DCACHE_ENABLED 0
`endif

`ifdef LMEM_ENABLE
    `define LMEM_ENABLED 1
`else
    `define LMEM_ENABLED 0
`endif

`ifdef GBAR_ENABLE
    `define GBAR_ENABLED 1
`else
    `define GBAR_ENABLED 0
`endif

`ifdef L2_ENABLE
    `define L2_ENABLED 1
`else
    `define L2_ENABLED 0
`endif

`ifdef L3_ENABLE
    `define L3_ENABLED 1
`else
    `define L3_ENABLED 0
`endif

`ifdef EXT_A_ENABLE
    `define EXT_A_ENABLED   1
`else
    `define EXT_A_ENABLED   0
`endif

`ifdef EXT_C_ENABLE
    `define EXT_C_ENABLED   1
`else
    `define EXT_C_ENABLED   0
`endif

`ifdef EXT_D_ENABLE
    `define EXT_D_ENABLED   1
`else
    `define EXT_D_ENABLED   0
`endif

`ifdef EXT_F_ENABLE
    `define EXT_F_ENABLED   1
`else
    `define EXT_F_ENABLED   0
`endif

`ifdef EXT_M_ENABLE
    `define EXT_M_ENABLED   1
`else
    `define EXT_M_ENABLED   0
`endif

`ifdef EXT_V_ENABLE
    `define EXT_V_ENABLED   1
`else
    `define EXT_V_ENABLED   0
`endif

`ifdef EXT_ZICOND_ENABLE
    `define EXT_ZICOND_ENABLED 1
`else
    `define EXT_ZICOND_ENABLED 0
`endif

`ifdef EXT_TCU_ENABLE
    `define EXT_TCU_ENABLED 1
`else
    `define EXT_TCU_ENABLED 0
`endif

`define ISA_STD_A           0
`define ISA_STD_C           2
`define ISA_STD_D           3
`define ISA_STD_E           4
`define ISA_STD_F           5
`define ISA_STD_H           7
`define ISA_STD_I           8
`define ISA_STD_N           13
`define ISA_STD_Q           16
`define ISA_STD_S           18
`define ISA_STD_V           21

`define ISA_EXT_ICACHE      0
`define ISA_EXT_DCACHE      1
`define ISA_EXT_L2CACHE     2
`define ISA_EXT_L3CACHE     3
`define ISA_EXT_LMEM        4
`define ISA_EXT_ZICOND      5
`define ISA_EXT_TCU         6

`define MISA_EXT  (`ICACHE_ENABLED  << `ISA_EXT_ICACHE) \
                | (`DCACHE_ENABLED  << `ISA_EXT_DCACHE) \
                | (`L2_ENABLED      << `ISA_EXT_L2CACHE) \
                | (`L3_ENABLED      << `ISA_EXT_L3CACHE) \
                | (`LMEM_ENABLED    << `ISA_EXT_LMEM) \
                | (`EXT_ZICOND_ENABLED << `ISA_EXT_ZICOND) \
                | (`EXT_TCU_ENABLED << `ISA_EXT_TCU) \

`define MISA_STD  (`EXT_A_ENABLED <<  0) /* A - Atomic Instructions extension */ \
                | (0 <<  1) /* B - Tentatively reserved for Bit operations extension */ \
                | (`EXT_C_ENABLED <<  2) /* C - Compressed extension */ \
                | (`EXT_D_ENABLED <<  3) /* D - Double precsision floating-point extension */ \
                | (0 <<  4) /* E - RV32E base ISA */ \
                | (`EXT_F_ENABLED << 5) /* F - Single precsision floating-point extension */ \
                | (0 <<  6) /* G - Additional standard extensions present */ \
                | (0 <<  7) /* H - Hypervisor mode implemented */ \
                | (1 <<  8) /* I - RV32I/64I/128I base ISA */ \
                | (0 <<  9) /* J - Reserved */ \
                | (0 << 10) /* K - Reserved */ \
                | (0 << 11) /* L - Tentatively reserved for Bit operations extension */ \
                | (`EXT_M_ENABLED << 12) /* M - Integer Multiply/Divide extension */ \
                | (0 << 13) /* N - User level interrupts supported */ \
                | (0 << 14) /* O - Reserved */ \
                | (0 << 15) /* P - Tentatively reserved for Packed-SIMD extension */ \
                | (0 << 16) /* Q - Quad-precision floating-point extension */ \
                | (0 << 17) /* R - Reserved */ \
                | (0 << 18) /* S - Supervisor mode implemented */ \
                | (0 << 19) /* T - Tentatively reserved for Transactional Memory extension */ \
                | (1 << 20) /* U - User mode implemented */ \
                | (`EXT_V_ENABLED << 21) /* V - Tentatively reserved for Vector extension */ \
                | (0 << 22) /* W - Reserved */ \
                | (1 << 23) /* X - Non-standard extensions present */ \
                | (0 << 24) /* Y - Reserved */ \
                | (0 << 25) /* Z - Reserved */

// Device identification //////////////////////////////////////////////////////

`define VENDOR_ID           0
`define ARCHITECTURE_ID     0
`define IMPLEMENTATION_ID   0

// GEMM Unit Parameters ///////////////////////////////////////////////////////

// ------------------------------------------------------
// common FP bitwidths
// ------------------------------------------------------
`define FP32_WIDTH 32             // Total FP32 bitwidth
`define FP32_EXP_WIDTH 8          // Exponent width (FP32)
`define FP32_MAN_WIDTH 23         // Mantissa width (FP32)
`define FP16_WIDTH 16             // Total FP16 bitwidth
`define FP16_EXP_WIDTH 5          // Exponent width (FP16)
`define FP16_MAN_WIDTH 10         // Mantissa width (FP16)

// -------------------------------------------------------
// Input Format (FP16) Parameters
// -------------------------------------------------------
// Input activation format: FP16 (1 sign + 5 exp + 10 mantissa)
`define IFP_WIDTH 16              // Total input floating-point bitwidth
`define IFP_SIGN_WIDTH 1          // Sign bit width
`define IFP_EXP_WIDTH 5           // Exponent width (FP16)
`define IFP_MAN_WIDTH 10          // Mantissa width (FP16)
`define HIDDEN_WIDTH 1            // Hidden bit (implicit 1) for normalized FP

// -------------------------------------------------------
// Weight & Quantization Parameters
// -------------------------------------------------------
// Quantized weight and zero-point parameters
`define W_BIT_WIDTH 4             // Weight bitwidth (INT4)
`define ZP_WIDTH 16               // Zero-point bitwidth
`define SCALE_WIDTH 16            // Scale factor bitwidth (FP16)

// Quantization direction modes
`define QDIR_COL 0                // Per-column quantization (scale applied at output)
`define QDIR_ROW 1                // Per-row quantization (scale applied at input)

// -------------------------------------------------------
// Block Floating-Point (Prealigner) Parameters
// -------------------------------------------------------
// Extra bits for precision preservation during FP16->INT conversion
// Accounts for: weight bits + guard bits + FP32/FP16 mantissa difference
`define EXTRA_BIT_WIDTH (`W_BIT_WIDTH + 2 + (23-10)) // 19

// Aligned mantissa widths after block floating-point conversion
`define ALIGNED_MAN_FULL_WIDTH (`HIDDEN_WIDTH + `IFP_MAN_WIDTH + `EXTRA_BIT_WIDTH) // 30
`define SIGNED_ALIGNED_MAN_FULL_WIDTH (`ALIGNED_MAN_FULL_WIDTH + 1) // 31
`define ALIGNED_MAN_VALI_WIDTH (`HIDDEN_WIDTH + `IFP_MAN_WIDTH) // 11 (valid data width)

/*
SEL_BLOCK_NUM is determined by finding the maximum number of blocks needed.
Refer below code:
```
import math
def get_block_num(block_size, shift, bitwidth):
    return ((shift + bitwidth - 1) // block_size) - (shift // block_size) + 1

full_bitwidth = 30
for block_size in range(1, full_bitwidth+1):
  shift = [i for i in range(block_size)]
  block_nums = [get_block_num(block_size, s, full_bitwidth) for s in shift]
  max_block_num = max(block_nums)
  offset = max_block_num - (math.ceil(full_bitwidth / block_size))
  print(f"block size : {block_size:2}, offset : {offset}")
```
*/
`define BLOCK_SIZE 1

// Padded widths (aligned to BLOCK_SIZE boundary)
`define ALIGNED_MAN_PADDED_FULL_WIDTH (((`ALIGNED_MAN_FULL_WIDTH + `BLOCK_SIZE - 1) / `BLOCK_SIZE) * `BLOCK_SIZE) // 30
`define SIGNED_ALIGNED_MAN_PADDED_FULL_WIDTH (`ALIGNED_MAN_PADDED_FULL_WIDTH + 1) // 31

// Block indexing parameters for alignment shift
`define BLOCK_NUM  (`ALIGNED_MAN_PADDED_FULL_WIDTH / `BLOCK_SIZE)
`define SEL_BLOCK_NUM_ ((`ALIGNED_MAN_VALI_WIDTH + `BLOCK_SIZE - 1) / `BLOCK_SIZE)
`define SEL_BLOCK_NUM_INCR_ ((`BLOCK_SIZE == 1) ? 0 : 1)
`define SEL_BLOCK_NUM (`SEL_BLOCK_NUM_ + `SEL_BLOCK_NUM_INCR_)
`define BLK_IDX_NUM (`BLOCK_NUM - `SEL_BLOCK_NUM + 1)
`define BLOCK_IDX_WIDTH `CLOG2(`BLK_IDX_NUM)
`define SEL_BLOCK_WIDTH (`SEL_BLOCK_NUM * `BLOCK_SIZE + 1)

// -------------------------------------------------------
// MXU (Matrix Multiply Unit) Dimensions
// -------------------------------------------------------
// Matrix dimensions: MXU computes [MXU_ROW x K] * [K x MXU_COL]
`define MXU_ROW 32                // Number of input rows (activation vector length)
`define MXU_COL 32                // Number of output columns (output vector length)
`define MXU_MAX_DIM `MAX(`MXU_ROW, `MXU_COL)

// Tiling parameters for parallel processing
`define MXU_ROW_TILE 1            // Row tile size for pipelined processing
`define MXU_COL_TILE 1            // Column tile size for pipelined processing
`define MXU_WLOAD_NUM 4           // Number of weight loads per cycle

// -------------------------------------------------------
// MXU Pipeline Configuration
// -------------------------------------------------------
// Pipeline stage enable flags and intervals
`define MXU_PIPE_MUL_EN 1         // Enable pipeline register after multiplier
`define MXU_PIPE_ALIGN_EN 1       // Enable pipeline register after alignment shift
`define MXU_PIPE_ADD_INTV 2       // Pipeline insertion interval in adder tree (every N stages)
`define ACT_REDUCE_PIPE_INTV 2    // Pipeline interval for activation reduce tree

// -------------------------------------------------------
// Internal Datapath Bitwidths
// -------------------------------------------------------
// MXU output width: aligned_mantissa + weight_bits + log2(reduction_count)
`define O_BIT_WIDTH (`SIGNED_ALIGNED_MAN_PADDED_FULL_WIDTH + `W_BIT_WIDTH + `CLOG2(`MXU_ROW)) // 39

// Activation reduce tree (for zero-point subtraction path)
`define ACT_REDUCE_IN_WIDTH (`SIGNED_ALIGNED_MAN_FULL_WIDTH + `ZP_WIDTH)
`define ACT_REDUCE_OUT_WIDTH (`ACT_REDUCE_IN_WIDTH + `CLOG2(`MXU_ROW))

// Zero-point multiply widths
`define ZP_TRANS_WIDTH (`ZP_WIDTH + 3)
`define ZP_MUL_IN_WIDTH (`SIGNED_ALIGNED_MAN_FULL_WIDTH + `CLOG2(`MXU_ROW))
`define ZP_MUL_OUT_WIDTH (`ZP_MUL_IN_WIDTH + `ZP_WIDTH)

// Pre-processor output width (after zero-point correction)
`define PRE_PROC_OUT_DW (`SIGNED_ALIGNED_MAN_PADDED_FULL_WIDTH + `ZP_WIDTH + `CLOG2(`MXU_ROW))

// Merger output width (MXU output + pre-processor output)
`define MERGE_OUT_BW (`O_BIT_WIDTH + 1)

// -------------------------------------------------------
// Data Transfer Sizes (in bytes)
// -------------------------------------------------------
`define GEMM_INPUT_DATA_SIZE      ((`IFP_WIDTH/8)*`MXU_ROW)             // 64 bytes (32 FP16 inputs)
`define GEMM_WEIGHT_DATA_SIZE     ((`MXU_COL*`MXU_WLOAD_NUM*`W_BIT_WIDTH)/8) // 64 bytes (4*32 INT4 weights)
`define GEMM_SCALE_ZERO_DATA_SIZE ((`SCALE_WIDTH*`MXU_COL)/8)           // 64 bytes (32 FP16 scales)
`define GEMM_OUTPUT_DATA_SIZE     ((`FP16_WIDTH/8)*`MXU_COL)                          // 64 bytes (32 FP16 outputs)
`define GEMM_PSUM_DATA_SIZE       ((`FP32_WIDTH/8)*`MXU_COL)                          // 128 bytes (32 FP32 psums)

// -------------------------------------------------------
// Accumulator Memory Configuration
// -------------------------------------------------------
`ifndef GEMM_ACC_MEM_DEPTH
`define GEMM_ACC_MEM_DEPTH 1024 // == SIZE/512
`endif
`define GEMM_ACC_MEM_BANK_NUM 4
`define GEMM_ACC_MEM_TOT_SIZE ((`GEMM_ACC_MEM_DEPTH) * (`GEMM_PSUM_DATA_SIZE) * `GEMM_ACC_MEM_BANK_NUM) // 512KB
`define GEMM_ACC_MEM_ADDR_WIDTH `CLOG2(`GEMM_ACC_MEM_TOT_SIZE)
`define GEMM_ACC_MEM_BANK_WIDTH (`MXU_COL * `GEMM_ACC_MEM_BANK_NUM) // 64 bytes per bank
`define GEMM_ACC_MEM_BANK_ADDR_WIDTH (`GEMM_ACC_MEM_ADDR_WIDTH - `CLOG2(`GEMM_ACC_MEM_BANK_NUM))
`define GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH (`GEMM_ACC_MEM_BANK_ADDR_WIDTH - `CLOG2(`GEMM_PSUM_DATA_SIZE))
`define GEMM_ACC_MAX_CNT `CLOG2((2*`GEMM_ACC_MEM_DEPTH))

// -------------------------------------------------------
// Configuration Registers
// -------------------------------------------------------
`ifndef NUM_DMA_CHANNELS
`define NUM_DMA_CHANNELS 8        // Number of DMA AXI channels per core (TMEM banks)
`endif
`ifndef TMEM_BANK_SIZE
`define TMEM_BANK_SIZE (64 * 1024) // 64KB
`endif

// HBM interleave stride (bytes): consecutive MEM_BLOCK_SIZE blocks round-robin
// across all DMA channels before advancing to the next stripe within one HBM bank.
`define HBM_BUS_STRIDE (`MEM_BLOCK_SIZE * `NUM_DMA_CHANNELS)

`define GEMM_CFG_REG_NUM 40       // Number of GEMM configuration registers
`define DMA_CFG_REG_NUM 18        // Number of DMA configuration registers
`ifdef XLEN_64
`define GEMM_REG_BASE_ADDR 64'h0000_0000_0000_1080 // Base byte address for GEMM config registers
`define DMA_REG_BASE_ADDR 64'h0000_0000_0000_1480  // Base byte address for DMA config registers
`else
`define GEMM_REG_BASE_ADDR 64'h0000_FFFF_0000_0000 // Base byte address for GEMM config registers
`define DMA_REG_BASE_ADDR 64'h0000_FFFF_FFFF_0000  // Base byte address for DMA config registers
`endif

`define MM_MAX_LOG_DIM 20 // Maximum log2 dimension size for matrix (1M)
`define MM_MAX_LOG_TILEDIM 10 // Maximum log2 tile dimension size (1K)

// job frontend number of entries
`define JOB_MMIO_NUM_ENTRIES 4

// job frontend reg idx
`define JOB_MMIO_CONTROL_REG_IDX 0

// job frontend bitwidth
`define JOB_MMIO_ENTRYID_W 4
`define JOB_MMIO_OWNER_W   4
`define JOB_MMIO_GEN_W     16

// job frontend control reg bit fields
`define JOB_MMIO_CTRL_VALID_BIT   0
`define JOB_MMIO_CTRL_OCCUPY_BIT  1
`define JOB_MMIO_CTRL_WORKING_BIT 2
`define JOB_MMIO_CTRL_OWNER_LSB   3
`define JOB_MMIO_CTRL_GEN_LSB     (`JOB_MMIO_CTRL_OWNER_LSB + `JOB_MMIO_OWNER_W)

`define JOB_MMIO_ALLOC_SUCC_BIT 0
`define JOB_MMIO_ALLOC_ENTRY_LSB 1
`define JOB_MMIO_ALLOC_ENTRY_BITS `JOB_MMIO_ENTRYID_W
`define JOB_MMIO_ALLOC_OWNER_LSB (`JOB_MMIO_ALLOC_ENTRY_LSB + `JOB_MMIO_ALLOC_ENTRY_BITS)
`define JOB_MMIO_ALLOC_OWNER_BITS `JOB_MMIO_OWNER_W
`define JOB_MMIO_ALLOC_GEN_LSB (`JOB_MMIO_ALLOC_OWNER_LSB + `JOB_MMIO_ALLOC_OWNER_BITS)
`define JOB_MMIO_ALLOC_GEN_BITS `JOB_MMIO_GEN_W

// gemm fsm dataflow
`define GEMM_FSM_MT 128
`define GEMM_FSM_NT 128
`define GEMM_FSM_KT 128
`define GEMM_FSM_MXU_KT 32
`define GEMM_FSM_MXU_NT 32

// Output scaling mode (uncomment to enable FP16 output scaling)
// `define GEMM_UNIT_FP16_OUT_SCALE

`endif // VX_CONFIG_VH
