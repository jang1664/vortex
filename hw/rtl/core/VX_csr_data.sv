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

`include "VX_define.vh"

`ifdef EXT_F_ENABLE
`include "VX_fpu_define.vh"
`endif

`ifdef XLEN_64
    `define CSR_READ_64(addr, dst, src) \
        addr : dst = `XLEN'(src)
`else
    `define CSR_READ_64(addr, dst, src) \
        addr : dst = src[31:0]; \
        addr+12'h80 : dst = 32'(src[$bits(src)-1:32])
`endif

module VX_csr_data
import VX_gpu_pkg::*;
`ifdef EXT_F_ENABLE
import VX_fpu_pkg::*;
`endif
#(
    parameter `STRING INSTANCE_ID = "",
    parameter CORE_ID = 0
) (
    input wire                          clk,
    input wire                          reset,

    input base_dcrs_t                   base_dcrs,

`ifdef PERF_ENABLE
    input sysmem_perf_t                 sysmem_perf,
    input pipeline_perf_t               pipeline_perf,
    input accel_perf_t                  accel_perf,
`endif

    VX_commit_csr_if.slave              commit_csr_if,

`ifdef EXT_F_ENABLE
    VX_fpu_csr_if.slave                 fpu_csr_if [`NUM_FPU_BLOCKS],
`endif

    input wire [PERF_CTR_BITS-1:0]      cycles,
    input wire [`NUM_WARPS-1:0]         active_warps,
    input wire [`NUM_WARPS-1:0][`NUM_THREADS-1:0] thread_masks,

    input wire                          read_enable,
    input wire [UUID_WIDTH-1:0]         read_uuid,
    input wire [NW_WIDTH-1:0]           read_wid,
    input wire [`VX_CSR_ADDR_BITS-1:0]  read_addr,
    output wire [`XLEN-1:0]             read_data_ro,
    output wire [`XLEN-1:0]             read_data_rw,
`ifdef PERF_ENABLE
    output wire [8:1][`XLEN-1:0]        read_data_mpm,
`endif

    input wire                          write_enable,
    input wire [UUID_WIDTH-1:0]         write_uuid,
    input wire [NW_WIDTH-1:0]           write_wid,
    input wire [`VX_CSR_ADDR_BITS-1:0]  write_addr,
    input wire [`XLEN-1:0]              write_data
);

    `UNUSED_VAR (reset)
    `UNUSED_VAR (write_wid)
    `UNUSED_VAR (write_data)

    // CSRs Write /////////////////////////////////////////////////////////////

    reg [`XLEN-1:0] mscratch;

`ifdef EXT_F_ENABLE
    reg [`NUM_WARPS-1:0][INST_FRM_BITS+`FP_FLAGS_BITS-1:0] fcsr, fcsr_n;
    wire [`NUM_FPU_BLOCKS-1:0]              fpu_write_enable;
    wire [`NUM_FPU_BLOCKS-1:0][NW_WIDTH-1:0] fpu_write_wid;
    fflags_t [`NUM_FPU_BLOCKS-1:0]          fpu_write_fflags;

    for (genvar i = 0; i < `NUM_FPU_BLOCKS; ++i) begin : g_fpu_write
        assign fpu_write_enable[i] = fpu_csr_if[i].write_enable;
        assign fpu_write_wid[i]    = fpu_csr_if[i].write_wid;
        assign fpu_write_fflags[i] = fpu_csr_if[i].write_fflags;
    end

    always @(*) begin
        fcsr_n = fcsr;
        for (integer i = 0; i < `NUM_FPU_BLOCKS; ++i) begin
            if (fpu_write_enable[i]) begin
                fcsr_n[fpu_write_wid[i]][`FP_FLAGS_BITS-1:0] = fcsr[fpu_write_wid[i]][`FP_FLAGS_BITS-1:0]
                                                             | fpu_write_fflags[i];
            end
        end
        if (write_enable) begin
            case (write_addr)
                `VX_CSR_FFLAGS: fcsr_n[write_wid][`FP_FLAGS_BITS-1:0] = write_data[`FP_FLAGS_BITS-1:0];
                `VX_CSR_FRM:    fcsr_n[write_wid][INST_FRM_BITS+`FP_FLAGS_BITS-1:`FP_FLAGS_BITS] = write_data[INST_FRM_BITS-1:0];
                `VX_CSR_FCSR:   fcsr_n[write_wid] = write_data[`FP_FLAGS_BITS+INST_FRM_BITS-1:0];
            default:;
            endcase
        end
    end

    for (genvar i = 0; i < `NUM_FPU_BLOCKS; ++i) begin : g_fpu_csr_read_frm
        assign fpu_csr_if[i].read_frm = fcsr[fpu_csr_if[i].read_wid][INST_FRM_BITS+`FP_FLAGS_BITS-1:`FP_FLAGS_BITS];
    end

    always @(posedge clk) begin
        if (reset) begin
            fcsr <= '0;
        end else begin
            fcsr <= fcsr_n;
        end
    end
`endif

    always @(posedge clk) begin
        if (reset) begin
            mscratch <= base_dcrs.startup_arg;
        end
        if (write_enable) begin
            case (write_addr)
            `ifdef EXT_F_ENABLE
                `VX_CSR_FFLAGS,
                `VX_CSR_FRM,
                `VX_CSR_FCSR,
            `endif
                `VX_CSR_SATP,
                `VX_CSR_MSTATUS,
                `VX_CSR_MNSTATUS,
                `VX_CSR_MEDELEG,
                `VX_CSR_MIDELEG,
                `VX_CSR_MIE,
                `VX_CSR_MTVEC,
                `VX_CSR_MEPC,
                `VX_CSR_PMPCFG0,
                `VX_CSR_PMPADDR0: begin
                    // do nothing!
                end
                `VX_CSR_MSCRATCH: begin
                    mscratch <= write_data;
                end
                default: begin
                    `VX_ASSERT(0, ("%t: *** %s invalid CSR write address: %0h (#%0d)", $time, INSTANCE_ID, write_addr, write_uuid));
                end
            endcase
        end
    end

    // CSRs read //////////////////////////////////////////////////////////////

    reg [`XLEN-1:0] read_data_ro_w;
    reg [`XLEN-1:0] read_data_rw_w;
    reg read_addr_valid_w;

`ifdef PERF_ENABLE
    function automatic [`XLEN-1:0] read_mpm_class(
        input logic [7:0] mpm_class,
        input logic [`VX_CSR_ADDR_BITS-1:0] addr
    );
        read_mpm_class = '0;
        case (mpm_class)
        `VX_DCR_MPM_CLASS_CORE: begin
            case (addr)
            `CSR_READ_64(`VX_CSR_MPM_SCHED_ID, read_mpm_class, pipeline_perf.sched.idles);
            `CSR_READ_64(`VX_CSR_MPM_SCHED_ST, read_mpm_class, pipeline_perf.sched.stalls);
            `CSR_READ_64(`VX_CSR_MPM_IBUF_ST, read_mpm_class, pipeline_perf.issue.ibf_stalls);
            `CSR_READ_64(`VX_CSR_MPM_SCRB_ST, read_mpm_class, pipeline_perf.issue.scb_stalls);
            `CSR_READ_64(`VX_CSR_MPM_OPDS_ST, read_mpm_class, pipeline_perf.issue.opd_stalls);
            `CSR_READ_64(`VX_CSR_MPM_SCRB_ALU, read_mpm_class, pipeline_perf.issue.units_uses[EX_ALU]);
            `CSR_READ_64(`VX_CSR_MPM_SCRB_LSU, read_mpm_class, pipeline_perf.issue.units_uses[EX_LSU]);
            `CSR_READ_64(`VX_CSR_MPM_SCRB_SFU, read_mpm_class, pipeline_perf.issue.units_uses[EX_SFU]);
        `ifdef EXT_F_ENABLE
            `CSR_READ_64(`VX_CSR_MPM_SCRB_FPU, read_mpm_class, pipeline_perf.issue.units_uses[EX_FPU]);
        `endif
        `ifdef EXT_TCU_ENABLE
            `CSR_READ_64(`VX_CSR_MPM_SCRB_TCU, read_mpm_class, pipeline_perf.issue.units_uses[EX_TCU]);
        `endif
            `CSR_READ_64(`VX_CSR_MPM_SCRB_CSRS, read_mpm_class, pipeline_perf.issue.sfu_uses[SFU_CSRS]);
            `CSR_READ_64(`VX_CSR_MPM_SCRB_WCTL, read_mpm_class, pipeline_perf.issue.sfu_uses[SFU_WCTL]);
            `CSR_READ_64(`VX_CSR_MPM_IFETCHES, read_mpm_class, pipeline_perf.ifetches);
            `CSR_READ_64(`VX_CSR_MPM_LOADS, read_mpm_class, pipeline_perf.loads);
            `CSR_READ_64(`VX_CSR_MPM_STORES, read_mpm_class, pipeline_perf.stores);
            `CSR_READ_64(`VX_CSR_MPM_IFETCH_LT, read_mpm_class, pipeline_perf.ifetch_latency);
            `CSR_READ_64(`VX_CSR_MPM_LOAD_LT, read_mpm_class, pipeline_perf.load_latency);
            default:;
            endcase
        end
        `VX_DCR_MPM_CLASS_MEM: begin
            case (addr)
            `CSR_READ_64(`VX_CSR_MPM_ICACHE_READS, read_mpm_class, sysmem_perf.icache.reads);
            `CSR_READ_64(`VX_CSR_MPM_ICACHE_MISS_R, read_mpm_class, sysmem_perf.icache.read_misses);
            `CSR_READ_64(`VX_CSR_MPM_ICACHE_MSHR_ST, read_mpm_class, sysmem_perf.icache.mshr_stalls);
            `CSR_READ_64(`VX_CSR_MPM_DCACHE_READS, read_mpm_class, sysmem_perf.dcache.reads);
            `CSR_READ_64(`VX_CSR_MPM_DCACHE_WRITES, read_mpm_class, sysmem_perf.dcache.writes);
            `CSR_READ_64(`VX_CSR_MPM_DCACHE_MISS_R, read_mpm_class, sysmem_perf.dcache.read_misses);
            `CSR_READ_64(`VX_CSR_MPM_DCACHE_MISS_W, read_mpm_class, sysmem_perf.dcache.write_misses);
            `CSR_READ_64(`VX_CSR_MPM_DCACHE_BANK_ST, read_mpm_class, sysmem_perf.dcache.bank_stalls);
            `CSR_READ_64(`VX_CSR_MPM_DCACHE_MSHR_ST, read_mpm_class, sysmem_perf.dcache.mshr_stalls);
            `CSR_READ_64(`VX_CSR_MPM_LMEM_READS, read_mpm_class, sysmem_perf.lmem.reads);
            `CSR_READ_64(`VX_CSR_MPM_LMEM_WRITES, read_mpm_class, sysmem_perf.lmem.writes);
            `CSR_READ_64(`VX_CSR_MPM_LMEM_BANK_ST, read_mpm_class, sysmem_perf.lmem.bank_stalls);
            `CSR_READ_64(`VX_CSR_MPM_L2CACHE_READS, read_mpm_class, sysmem_perf.l2cache.reads);
            `CSR_READ_64(`VX_CSR_MPM_L2CACHE_WRITES, read_mpm_class, sysmem_perf.l2cache.writes);
            `CSR_READ_64(`VX_CSR_MPM_L2CACHE_MISS_R, read_mpm_class, sysmem_perf.l2cache.read_misses);
            `CSR_READ_64(`VX_CSR_MPM_L2CACHE_MISS_W, read_mpm_class, sysmem_perf.l2cache.write_misses);
            `CSR_READ_64(`VX_CSR_MPM_L2CACHE_BANK_ST, read_mpm_class, sysmem_perf.l2cache.bank_stalls);
            `CSR_READ_64(`VX_CSR_MPM_L2CACHE_MSHR_ST, read_mpm_class, sysmem_perf.l2cache.mshr_stalls);
            `CSR_READ_64(`VX_CSR_MPM_L3CACHE_READS, read_mpm_class, sysmem_perf.l3cache.reads);
            `CSR_READ_64(`VX_CSR_MPM_L3CACHE_WRITES, read_mpm_class, sysmem_perf.l3cache.writes);
            `CSR_READ_64(`VX_CSR_MPM_L3CACHE_MISS_R, read_mpm_class, sysmem_perf.l3cache.read_misses);
            `CSR_READ_64(`VX_CSR_MPM_L3CACHE_MISS_W, read_mpm_class, sysmem_perf.l3cache.write_misses);
            `CSR_READ_64(`VX_CSR_MPM_L3CACHE_BANK_ST, read_mpm_class, sysmem_perf.l3cache.bank_stalls);
            `CSR_READ_64(`VX_CSR_MPM_L3CACHE_MSHR_ST, read_mpm_class, sysmem_perf.l3cache.mshr_stalls);
            `CSR_READ_64(`VX_CSR_MPM_MEM_READS, read_mpm_class, sysmem_perf.mem.reads);
            `CSR_READ_64(`VX_CSR_MPM_MEM_WRITES, read_mpm_class, sysmem_perf.mem.writes);
            `CSR_READ_64(`VX_CSR_MPM_MEM_LT, read_mpm_class, sysmem_perf.mem.latency);
            `CSR_READ_64(`VX_CSR_MPM_COALESCER_MISS, read_mpm_class, sysmem_perf.coalescer.misses);
            default:;
            endcase
        end
        `VX_DCR_MPM_CLASS_ACCEL_MXU: begin
            case (addr)
            `CSR_READ_64(`VX_CSR_MPM_BUSY_CYC, read_mpm_class, accel_perf.busy_cycles);
            `CSR_READ_64(`VX_CSR_MPM_GEMM_TOTAL_CYC, read_mpm_class, accel_perf.gemm_node.total_cycles);
            `CSR_READ_64(`VX_CSR_MPM_GEMM_COMPUTE_CYC, read_mpm_class, accel_perf.gemm_unit.compute_cycles);
            `CSR_READ_64(`VX_CSR_MPM_GEMM_STALL_CYC, read_mpm_class, accel_perf.gemm_unit.stall_cycles);
            `CSR_READ_64(`VX_CSR_MPM_GEMM_JOB_CNT, read_mpm_class, accel_perf.gemm_unit.job_count);
            `CSR_READ_64(`VX_CSR_MPM_MXU_MAC_COUNT, read_mpm_class, accel_perf.gemm_unit.mac_count);
            `CSR_READ_64(`VX_CSR_MPM_MXU_INPUT_FIRE, read_mpm_class, accel_perf.gemm_unit.input_fire);
            `CSR_READ_64(`VX_CSR_MPM_MXU_INPUT_STALL, read_mpm_class, accel_perf.gemm_unit.input_stall);
            `CSR_READ_64(`VX_CSR_MPM_MXU_WEIGHT_FIRE, read_mpm_class, accel_perf.gemm_unit.weight_fire);
            `CSR_READ_64(`VX_CSR_MPM_MXU_WEIGHT_STALL, read_mpm_class, accel_perf.gemm_unit.weight_stall);
            `CSR_READ_64(`VX_CSR_MPM_MXU_PSUM_FIRE, read_mpm_class, accel_perf.gemm_unit.psum_fire);
            `CSR_READ_64(`VX_CSR_MPM_MXU_PSUM_STALL, read_mpm_class, accel_perf.gemm_unit.psum_stall);
            `CSR_READ_64(`VX_CSR_MPM_MXU_OUTPUT_FIRE, read_mpm_class, accel_perf.gemm_unit.output_fire);
            `CSR_READ_64(`VX_CSR_MPM_MXU_OUTPUT_STALL, read_mpm_class, accel_perf.gemm_unit.output_stall);
            `CSR_READ_64(`VX_CSR_MPM_OVERLAP_DMA_MXU, read_mpm_class, accel_perf.overlap_dma_mxu);
            `CSR_READ_64(`VX_CSR_MPM_MXU_ACCUM_RD_ACCEPT, read_mpm_class, accel_perf.gemm_unit.accum_rd_accept);
            `CSR_READ_64(`VX_CSR_MPM_MXU_ACCUM_WR_FIRE, read_mpm_class, accel_perf.gemm_unit.accum_wr_fire);
            `CSR_READ_64(`VX_CSR_MPM_MXU_SCALER_VALID, read_mpm_class, accel_perf.gemm_unit.scaler_valid);
            `CSR_READ_64(`VX_CSR_MPM_MXU_ACC_OUTPUT_VALID, read_mpm_class, accel_perf.gemm_unit.acc_output_valid);
            `CSR_READ_64(`VX_CSR_MPM_MXU_PSUM_UNDERFLOW, read_mpm_class, accel_perf.gemm_unit.psum_underflow);
            `CSR_READ_64(`VX_CSR_MPM_MXU_RD_WR_CONFLICT, read_mpm_class, accel_perf.gemm_unit.rd_wr_conflict);
            `CSR_READ_64(`VX_CSR_MPM_DMA_UNION_ACTIVE_CYC, read_mpm_class, accel_perf.dma_union_active_cycles);
            default:;
            endcase
        end
        `VX_DCR_MPM_CLASS_ACCEL_DMA: begin
            case (addr)
            `CSR_READ_64(`VX_CSR_MPM_BUSY_CYC, read_mpm_class, accel_perf.busy_cycles);
            `CSR_READ_64(`VX_CSR_MPM_GEMM_TOTAL_CYC, read_mpm_class, accel_perf.gemm_node.total_cycles);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_RD_BYTES, read_mpm_class, accel_perf.cpu_dma.rd_bytes);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_WR_BYTES, read_mpm_class, accel_perf.cpu_dma.wr_bytes);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_XFER_CNT, read_mpm_class, accel_perf.cpu_dma.xfer_count);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_ACTIVE_CYC, read_mpm_class, accel_perf.cpu_dma.active_cycles);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_SRC_RD_REQ_FIRE, read_mpm_class, accel_perf.cpu_dma.src_rd_req_fire);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_SRC_RD_REQ_STALL, read_mpm_class, accel_perf.cpu_dma.src_rd_req_stall);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_SRC_RD_DATA_FIRE, read_mpm_class, accel_perf.cpu_dma.src_rd_data_fire);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_SRC_RD_DATA_STALL, read_mpm_class, accel_perf.cpu_dma.src_rd_data_stall);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_DST_WR_FIRE, read_mpm_class, accel_perf.cpu_dma.dst_wr_fire);
            `CSR_READ_64(`VX_CSR_MPM_CPU_DMA_DST_WR_STALL, read_mpm_class, accel_perf.cpu_dma.dst_wr_stall);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_RD_BYTES, read_mpm_class, accel_perf.hbm_dma.aggregate.rd_bytes);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_WR_BYTES, read_mpm_class, accel_perf.hbm_dma.aggregate.wr_bytes);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_XFER_CNT, read_mpm_class, accel_perf.hbm_dma.aggregate.xfer_count);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_ACTIVE_CYC, read_mpm_class, accel_perf.hbm_dma.aggregate.active_cycles);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_SRC_RD_REQ_FIRE, read_mpm_class, accel_perf.hbm_dma.aggregate.src_rd_req_fire);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_SRC_RD_REQ_STALL, read_mpm_class, accel_perf.hbm_dma.aggregate.src_rd_req_stall);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_SRC_RD_DATA_FIRE, read_mpm_class, accel_perf.hbm_dma.aggregate.src_rd_data_fire);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_SRC_RD_DATA_STALL, read_mpm_class, accel_perf.hbm_dma.aggregate.src_rd_data_stall);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_DST_WR_FIRE, read_mpm_class, accel_perf.hbm_dma.aggregate.dst_wr_fire);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_DST_WR_STALL, read_mpm_class, accel_perf.hbm_dma.aggregate.dst_wr_stall);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_ACTIVE_MAX, read_mpm_class, accel_perf.hbm_dma.active_cycles_max);
            `CSR_READ_64(`VX_CSR_MPM_HBM_DMA_ACTIVE_MIN, read_mpm_class, accel_perf.hbm_dma.active_cycles_min);
            default:;
            endcase
        end
        `VX_DCR_MPM_CLASS_ACCEL_LDMA_IN,
        `VX_DCR_MPM_CLASS_ACCEL_LDMA_WT,
        `VX_DCR_MPM_CLASS_ACCEL_LDMA_SZ,
        `VX_DCR_MPM_CLASS_ACCEL_LDMA_OUT: begin
            dma_perf_t ldma_perf;
            case (mpm_class)
            `VX_DCR_MPM_CLASS_ACCEL_LDMA_IN:  ldma_perf = accel_perf.lmem_dma_input;
            `VX_DCR_MPM_CLASS_ACCEL_LDMA_WT:  ldma_perf = accel_perf.lmem_dma_weight;
            `VX_DCR_MPM_CLASS_ACCEL_LDMA_SZ:  ldma_perf = accel_perf.lmem_dma_sz;
            default:                          ldma_perf = accel_perf.lmem_dma_output;
            endcase
            case (addr)
            `CSR_READ_64(`VX_CSR_MPM_BUSY_CYC, read_mpm_class, accel_perf.busy_cycles);
            `CSR_READ_64(`VX_CSR_MPM_GEMM_TOTAL_CYC, read_mpm_class, accel_perf.gemm_node.total_cycles);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_RD_BYTES, read_mpm_class, ldma_perf.rd_bytes);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_WR_BYTES, read_mpm_class, ldma_perf.wr_bytes);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_XFER_CNT, read_mpm_class, ldma_perf.xfer_count);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_ACTIVE_CYC, read_mpm_class, ldma_perf.active_cycles);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_SRC_RD_REQ_FIRE, read_mpm_class, ldma_perf.src_rd_req_fire);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_SRC_RD_REQ_STALL, read_mpm_class, ldma_perf.src_rd_req_stall);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_SRC_RD_DATA_FIRE, read_mpm_class, ldma_perf.src_rd_data_fire);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_SRC_RD_DATA_STALL, read_mpm_class, ldma_perf.src_rd_data_stall);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_DST_WR_FIRE, read_mpm_class, ldma_perf.dst_wr_fire);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_DST_WR_STALL, read_mpm_class, ldma_perf.dst_wr_stall);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_WAIT_DCACHE, read_mpm_class, ldma_perf.wait_dcache);
            `CSR_READ_64(`VX_CSR_MPM_LDMA_WAIT_LMEM, read_mpm_class, ldma_perf.wait_lmem);
            default:;
            endcase
        end
        default:;
        endcase
    endfunction

    for (genvar perf_class = 1; perf_class <= 8; ++perf_class) begin : g_read_mpm_class
        assign read_data_mpm[perf_class] = read_mpm_class(8'(perf_class), read_addr);
    end
`endif

    always @(*) begin
        read_data_ro_w    = '0;
        read_data_rw_w    = '0;
        read_addr_valid_w = 1;
        case (read_addr)
            `VX_CSR_MVENDORID  : read_data_ro_w = `XLEN'(`VENDOR_ID);
            `VX_CSR_MARCHID    : read_data_ro_w = `XLEN'(`ARCHITECTURE_ID);
            `VX_CSR_MIMPID     : read_data_ro_w = `XLEN'(`IMPLEMENTATION_ID);
            `VX_CSR_MISA       : read_data_ro_w = `XLEN'({2'(`CLOG2(`XLEN/16)), 30'(`MISA_STD)});
        `ifdef EXT_F_ENABLE
            `VX_CSR_FFLAGS     : read_data_rw_w = `XLEN'(fcsr[read_wid][`FP_FLAGS_BITS-1:0]);
            `VX_CSR_FRM        : read_data_rw_w = `XLEN'(fcsr[read_wid][INST_FRM_BITS+`FP_FLAGS_BITS-1:`FP_FLAGS_BITS]);
            `VX_CSR_FCSR       : read_data_rw_w = `XLEN'(fcsr[read_wid]);
        `endif
            `VX_CSR_MSCRATCH   : read_data_rw_w = mscratch;

            `VX_CSR_WARP_ID    : read_data_ro_w = `XLEN'(read_wid);
            `VX_CSR_CORE_ID    : read_data_ro_w = `XLEN'(CORE_ID);
            `VX_CSR_ACTIVE_THREADS: read_data_ro_w = `XLEN'(thread_masks[read_wid]);
            `VX_CSR_ACTIVE_WARPS: read_data_ro_w = `XLEN'(active_warps);
            `VX_CSR_NUM_THREADS: read_data_ro_w = `XLEN'(`NUM_THREADS);
            `VX_CSR_NUM_WARPS  : read_data_ro_w = `XLEN'(`NUM_WARPS);
            `VX_CSR_NUM_CORES  : read_data_ro_w = `XLEN'(`NUM_CORES * `NUM_CLUSTERS);
            `VX_CSR_LOCAL_MEM_BASE: read_data_ro_w = `XLEN'(`LMEM_BASE_ADDR);

            `CSR_READ_64(`VX_CSR_MCYCLE, read_data_ro_w, cycles);

            `VX_CSR_MPM_RESERVED : read_data_ro_w = '0;
            `VX_CSR_MPM_RESERVED_H : read_data_ro_w = '0;

            `CSR_READ_64(`VX_CSR_MINSTRET, read_data_ro_w, commit_csr_if.instret);

            `VX_CSR_SATP,
            `VX_CSR_MSTATUS,
            `VX_CSR_MNSTATUS,
            `VX_CSR_MEDELEG,
            `VX_CSR_MIDELEG,
            `VX_CSR_MIE,
            `VX_CSR_MTVEC,
            `VX_CSR_MEPC,
            `VX_CSR_PMPCFG0,
            `VX_CSR_PMPADDR0 : read_data_ro_w = `XLEN'(0);

            default: begin
                read_addr_valid_w = 0;
                if ((read_addr >= `VX_CSR_MPM_USER   && read_addr < (`VX_CSR_MPM_USER + 32))
                 || (read_addr >= `VX_CSR_MPM_USER_H && read_addr < (`VX_CSR_MPM_USER_H + 32))) begin
                    read_addr_valid_w = 1;
                end
            end
        endcase
    end

    assign read_data_ro = read_data_ro_w;
    assign read_data_rw = read_data_rw_w;

    `UNUSED_VAR (base_dcrs)

    `VX_RUNTIME_ASSERT(~read_enable || read_addr_valid_w, ("%t: *** invalid CSR read address: 0x%0h (#%0d)", $time, read_addr, read_uuid))

`ifdef PERF_ENABLE
    `UNUSED_VAR (sysmem_perf.icache);
    `UNUSED_VAR (sysmem_perf.lmem);
`endif

endmodule
