`include "VX_define.vh"

module VX_mem_remap #(
    parameter ADDR_W     = 64,
    parameter BLOCK_SIZE = `MEM_BLOCK_SIZE,
    parameter NUM_BANKS  = `PLATFORM_MEMORY_NUM_BANKS,
    parameter BANK_SHIFT = `PLATFORM_MEMORY_ADDR_WIDTH - `CLOG2(`PLATFORM_MEMORY_NUM_BANKS)
) (
    input  wire [ADDR_W-1:0] m_address,
    output wire [ADDR_W-1:0] hbm_address
);

    localparam int BLOCK_SHIFT = `CLOG2(BLOCK_SIZE);
    localparam int BANK_BITS   = `CLOG2(NUM_BANKS);

    // Block-level decomposition
    wire [ADDR_W-1:0]    block_idx   = m_address >> BLOCK_SHIFT;
    wire [ADDR_W-1:0]    byte_offset = m_address & ((ADDR_W'(1) << BLOCK_SHIFT) - 1);

    // bank = block_idx % NUM_BANKS
    // row  = block_idx / NUM_BANKS
    wire [BANK_BITS-1:0] bank_idx    = block_idx[BANK_BITS-1:0];
    wire [ADDR_W-1:0]    bank_offset = (block_idx >> BANK_BITS) << BLOCK_SHIFT;

    assign hbm_address =
        ({ {(ADDR_W-BANK_BITS){1'b0}}, bank_idx } << BANK_SHIFT) |
        bank_offset |
        byte_offset;

endmodule
