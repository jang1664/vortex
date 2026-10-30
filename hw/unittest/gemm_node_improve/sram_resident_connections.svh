// Resident-mode integration tests use public MMIO and real SRAM DMA traffic.
// Only the SIMD-side LMEM endpoint is modeled; destination stores deliberately
// commit several cycles after acceptance to expose premature completion.
`include "sram_acc_backpressure.svh"
VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(LMEM_TAG_WIDTH))
    fusion_lmem_if();
wire fusion_busy;
logic fusion_lmem_commit = 0;
logic fusion_lmem_published = 1;
byte unsigned fusion_lmem[0:`LMEM_SIZE-1];
logic fusion_mem_pending;
logic fusion_mem_write;
logic [LSU_WORD_SIZE*8-1:0] fusion_mem_data;
logic [LSU_WORD_SIZE-1:0] fusion_mem_byteen;
logic [LMEM_TAG_WIDTH-1:0] fusion_mem_tag;
int fusion_mem_offset, fusion_mem_delay;
int fusion_mem_commits;
int fusion_clock;
int fusion_read_count[NUM_DMA_CHANNELS];
int fusion_write_count[NUM_DMA_CHANNELS];
int fusion_input_read_count[NUM_DMA_CHANNELS];
int fusion_output_read_count[NUM_DMA_CHANNELS];
logic [63:0] fusion_watch_input, fusion_watch_output;
int fusion_watch_input_bytes, fusion_watch_output_bytes;

assign fusion_lmem_if.req_ready = !reset && !fusion_mem_pending
    && !fusion_lmem_if.rsp_valid && (fusion_clock % 5 != 0);

always @(posedge clk) begin
    if (reset) begin
        fusion_mem_pending <= 0;
        fusion_lmem_if.rsp_valid <= 0;
        fusion_lmem_commit <= 0;
        fusion_clock <= 0;
        fusion_mem_commits <= 0;
    end else begin
        fusion_clock <= fusion_clock + 1;
        fusion_lmem_commit <= 0;
        if (fusion_lmem_if.req_valid)
            assert (!$isunknown(fusion_lmem_if.req_data))
                else $fatal(1,"Fusion LMEM request contains X: address=%h write=%b data=%h",
                    fusion_lmem_if.req_data.addr,fusion_lmem_if.req_data.rw,
                    fusion_lmem_if.req_data.data);
        if (u_dut.o_gemm_bus_if.rsp_valid && u_dut.fusion_output_fp32)
            assert (!$isunknown(u_dut.o_gemm_bus_if.rsp_data.data))
                else $fatal(1,"FP32 ACC response contains X: address=%h tag=%h data=%h",
                    u_dut.o_gemm_bus_if.req_data.addr,u_dut.o_gemm_bus_if.rsp_data.tag,
                    u_dut.o_gemm_bus_if.rsp_data.data);
        if (fusion_lmem_if.rsp_valid && fusion_lmem_if.rsp_ready)
            fusion_lmem_if.rsp_valid <= 0;
        if (fusion_lmem_if.req_valid && fusion_lmem_if.req_ready) begin
            longint unsigned address;
            address = (64'(fusion_lmem_if.req_data.addr) << $clog2(LSU_WORD_SIZE))
                    - 64'(`LMEM_BASE_ADDR);
            assert (address + LSU_WORD_SIZE <= `LMEM_SIZE)
                else $fatal(1, "Fusion LMEM address outside modeled range");
            fusion_mem_offset <= int'(address);
            fusion_mem_write <= fusion_lmem_if.req_data.rw;
            fusion_mem_data <= fusion_lmem_if.req_data.data;
            fusion_mem_byteen <= fusion_lmem_if.req_data.byteen;
            fusion_mem_tag <= fusion_lmem_if.req_data.tag;
            fusion_mem_delay <= fusion_lmem_if.req_data.rw ? 7 : 3;
            fusion_mem_pending <= 1;
        end
        if (fusion_mem_pending) begin
            if (fusion_mem_delay != 0) begin
                fusion_mem_delay <= fusion_mem_delay - 1;
            end else if (fusion_mem_write) begin
                for (int b = 0; b < LSU_WORD_SIZE; ++b)
                    if (fusion_mem_byteen[b])
                        fusion_lmem[fusion_mem_offset+b] <= fusion_mem_data[b*8 +: 8];
                fusion_mem_pending <= 0;
                fusion_lmem_commit <= 1;
                fusion_mem_commits <= fusion_mem_commits + 1;
            end else if (!fusion_lmem_if.rsp_valid || fusion_lmem_if.rsp_ready) begin
                for (int b = 0; b < LSU_WORD_SIZE; ++b)
                    fusion_lmem_if.rsp_data.data[b*8 +: 8]
                        <= fusion_lmem[fusion_mem_offset+b];
                fusion_lmem_if.rsp_data.tag <= fusion_mem_tag;
                fusion_lmem_if.rsp_valid <= 1;
                fusion_mem_pending <= 0;
            end
        end
    end
end

for (genvar fc = 0; fc < NUM_DMA_CHANNELS; ++fc) begin : g_fusion_axi_count
    always @(posedge clk) begin
        if (reset) begin
            fusion_read_count[fc] <= 0;
            fusion_write_count[fc] <= 0;
            fusion_input_read_count[fc] <= 0;
            fusion_output_read_count[fc] <= 0;
        end else begin
            if (dma_axi[fc].aw_valid && dma_axi[fc].aw_ready)
                fusion_write_count[fc] <= fusion_write_count[fc] + 1;
            if (dma_axi[fc].ar_valid && dma_axi[fc].ar_ready) begin
                longint unsigned flat;
                flat = g_axi_slave[fc].to_flat_addr(64'(dma_axi[fc].ar_addr), fc);
                fusion_read_count[fc] <= fusion_read_count[fc] + 1;
                if (flat >= fusion_watch_input
                    && flat < fusion_watch_input + fusion_watch_input_bytes)
                    fusion_input_read_count[fc] <= fusion_input_read_count[fc] + 1;
                if (flat >= fusion_watch_output
                    && flat < fusion_watch_output + fusion_watch_output_bytes)
                    fusion_output_read_count[fc] <= fusion_output_read_count[fc] + 1;
            end
        end
    end
end

function automatic int fusion_count(input int kind);
    int count;
    count = 0;
    for (int c = 0; c < NUM_DMA_CHANNELS; ++c) begin
        case (kind)
            0: count += fusion_read_count[c];
            1: count += fusion_write_count[c];
            2: count += fusion_input_read_count[c];
            3: count += fusion_output_read_count[c];
        endcase
    end
    return count;
endfunction
