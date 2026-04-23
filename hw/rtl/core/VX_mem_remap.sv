`include "VX_define.vh"

module VX_mem_remap #(
    parameter ADDR_W     = 64,
    parameter BLOCK_SIZE = `MEM_BLOCK_SIZE,
    parameter NUM_BANKS  = `PLATFORM_MEMORY_NUM_BANKS,
    parameter NUM_PORTS  = `NUM_DMA_CHANNELS,
    parameter BANK_SHIFT = `PLATFORM_MEMORY_ADDR_WIDTH - `CLOG2(`PLATFORM_MEMORY_NUM_BANKS)
) (
    input  wire [ADDR_W-1:0] m_address,
    output wire [ADDR_W-1:0] hbm_address
);

    localparam int BLOCK_SHIFT    = `CLOG2(BLOCK_SIZE);
    localparam int BANK_BITS      = `CLOG2(NUM_BANKS);
    localparam int BANKS_PER_PORT = NUM_BANKS / NUM_PORTS;
    localparam int PORT_BITS      = `CLOG2(NUM_PORTS);
    localparam int LOCAL_BITS     = `CLOG2(BANKS_PER_PORT);

    // Block-level decomposition. Let b = block_idx, then
    //   q        = b / NUM_PORTS                       (high part)
    //   r        = b % NUM_PORTS                       (port index)
    //   bank_idx = BANKS_PER_PORT*r + (q % BANKS_PER_PORT) = {r, q[LOCAL_BITS-1:0]}
    //   row      = q / BANKS_PER_PORT
    // NUM_PORTS consecutive blocks round-robin across NUM_PORTS HBM ports,
    // and each port owns BANKS_PER_PORT contiguous banks. For NUM_BANKS=32,
    // NUM_PORTS=8, BLOCK_SIZE=64 the visit order is
    //   0,4,8,12,16,20,24,28, 1,5,9,13,17,21,25,29, 2,6,..., 3,7,...
    wire [ADDR_W-1:0]    block_idx   = m_address >> BLOCK_SHIFT;
    wire [ADDR_W-1:0]    byte_offset = m_address & ((ADDR_W'(1) << BLOCK_SHIFT) - 1);

    wire [ADDR_W-1:0]    q = block_idx >> PORT_BITS;
    wire [PORT_BITS-1:0] r = block_idx[PORT_BITS-1:0];

    wire [BANK_BITS-1:0] bank_idx =
        ({ {(BANK_BITS-PORT_BITS){1'b0}}, r } << LOCAL_BITS)
        | { {(BANK_BITS-LOCAL_BITS){1'b0}}, q[LOCAL_BITS-1:0] };

    wire [ADDR_W-1:0]    bank_offset = (q >> LOCAL_BITS) << BLOCK_SHIFT;

    assign hbm_address =
        ({ {(ADDR_W-BANK_BITS){1'b0}}, bank_idx } << BANK_SHIFT) |
        bank_offset |
        byte_offset;

endmodule
