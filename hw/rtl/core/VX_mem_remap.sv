`include "VX_define.vh"

module VX_mem_remap #(
    parameter ADDR_W     = 64,
    parameter BLOCK_SIZE = `MEM_BLOCK_SIZE,
    parameter NUM_BANKS  = `PLATFORM_MEMORY_NUM_BANKS,
    parameter NUM_PORTS  = `PLATFORM_MEMORY_NUM_PORTS,
    parameter BANK_SHIFT = `PLATFORM_MEMORY_ADDR_WIDTH - `CLOG2(`PLATFORM_MEMORY_NUM_BANKS)
) (
    input  wire [ADDR_W-1:0] m_address,
    output wire [ADDR_W-1:0] hbm_address
);

`ifdef PLATFORM_MEMORY_REMAP

    localparam int BLOCK_SHIFT    = `CLOG2(BLOCK_SIZE);
    localparam int BANK_BITS      = `CLOG2(NUM_BANKS);
    localparam int BANK_WIDTH     = `UP(BANK_BITS);
    localparam int BANKS_PER_PORT = NUM_BANKS / NUM_PORTS;
    localparam int PORT_BITS      = `CLOG2(NUM_PORTS);
    localparam int LOCAL_BITS     = `CLOG2(BANKS_PER_PORT);
    localparam [ADDR_W-1:0] PORT_MASK  = ADDR_W'(NUM_PORTS) - ADDR_W'(1);
    localparam [ADDR_W-1:0] LOCAL_MASK = ADDR_W'(BANKS_PER_PORT) - ADDR_W'(1);

    `STATIC_ASSERT (`IS_POW2(BLOCK_SIZE), ("BLOCK_SIZE must be a power of 2"))
    `STATIC_ASSERT (`IS_POW2(NUM_BANKS), ("NUM_BANKS must be a power of 2"))
    `STATIC_ASSERT (`IS_POW2(NUM_PORTS), ("NUM_PORTS must be a power of 2"))
    `STATIC_ASSERT ((NUM_BANKS >= NUM_PORTS), ("NUM_BANKS must be >= NUM_PORTS"))
    `STATIC_ASSERT ((NUM_BANKS % NUM_PORTS == 0), ("NUM_BANKS must be a multiple of NUM_PORTS"))
    `STATIC_ASSERT (`IS_POW2(BANKS_PER_PORT), ("BANKS_PER_PORT must be a power of 2"))

    wire [ADDR_W-1:0] block_idx   = m_address >> BLOCK_SHIFT;
    wire [ADDR_W-1:0] byte_offset = m_address & ((ADDR_W'(1) << BLOCK_SHIFT) - 1);

    wire [ADDR_W-1:0] q = block_idx >> PORT_BITS;
    wire [ADDR_W-1:0] r = (NUM_PORTS > 1) ? (block_idx & PORT_MASK) : '0;
    wire [ADDR_W-1:0] local_bank =
        (BANKS_PER_PORT > 1) ? (q & LOCAL_MASK) : '0;

    wire [BANK_WIDTH-1:0] bank_idx =
        BANK_WIDTH'((r << LOCAL_BITS) | local_bank);

    wire [ADDR_W-1:0] bank_offset = (q >> LOCAL_BITS) << BLOCK_SHIFT;

    assign hbm_address =
        (ADDR_W'(bank_idx) << BANK_SHIFT) |
        bank_offset |
        byte_offset;

`else

    `UNUSED_PARAM (BLOCK_SIZE)
    `UNUSED_PARAM (NUM_BANKS)
    `UNUSED_PARAM (NUM_PORTS)
    `UNUSED_PARAM (BANK_SHIFT)

    assign hbm_address = m_address;

`endif

endmodule
