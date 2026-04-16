

module VX_mem_remap #(
    parameter ADDR_W = 64,
    parameter BANK_SHIFT = 29
) (
    input  wire [ADDR_W-1:0] m_address,
    output wire [ADDR_W-1:0] hbm_address
);

    // 64B block decomposition
    wire [ADDR_W-1:0] block_idx;
    wire [ADDR_W-1:0] byte_offset;

    assign block_idx   = m_address >> 6;        // which 64B block
    assign byte_offset = m_address & 64'h3f;    // offset inside 64B block

    // bank = block_idx % 32
    // row  = block_idx / 32
    wire [4:0]        bank_idx;
    wire [ADDR_W-1:0] bank_offset;

    assign bank_idx    = block_idx[4:0];
    assign bank_offset = (block_idx >> 5) << 6; // (block_idx / 32) * 64

    assign hbm_address =
        ({ {(ADDR_W-5){1'b0}}, bank_idx } << BANK_SHIFT) |
        bank_offset |
        byte_offset;

endmodule