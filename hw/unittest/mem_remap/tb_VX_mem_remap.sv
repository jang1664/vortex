`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_mem_remap;
    localparam int ADDR_W = `PLATFORM_MEMORY_ADDR_WIDTH;
    localparam int BLOCK_SIZE = `MEM_BLOCK_SIZE;
    localparam int NUM_BANKS = `PLATFORM_MEMORY_NUM_BANKS;
    localparam int NUM_PORTS = `NUM_HBM_PORTS;
    localparam int BANK_SHIFT = ADDR_W - $clog2(NUM_BANKS);
    localparam int BANKS_PER_PORT = NUM_BANKS / NUM_PORTS;

    logic [ADDR_W-1:0] m_address;
    wire [ADDR_W-1:0] hbm_address;

    VX_mem_remap #(
        .ADDR_W     (ADDR_W),
        .BLOCK_SIZE (BLOCK_SIZE),
        .NUM_BANKS  (NUM_BANKS),
        .NUM_PORTS  (NUM_PORTS),
        .BANK_SHIFT (BANK_SHIFT)
    ) dut (
        .m_address   (m_address),
        .hbm_address (hbm_address)
    );

    task automatic check_block(input longint unsigned block);
        longint unsigned q;
        longint unsigned port;
        longint unsigned bank;
        longint unsigned row;
        longint unsigned expected;
        longint unsigned got_bank;
        begin
            m_address = ADDR_W'(block * BLOCK_SIZE);
            #1;
            q = block / longint'(NUM_PORTS);
            port = block % longint'(NUM_PORTS);
            bank = port * longint'(BANKS_PER_PORT)
                 + (q % longint'(BANKS_PER_PORT));
            row = q / longint'(BANKS_PER_PORT);
            expected = (bank << BANK_SHIFT) | (row * BLOCK_SIZE);
            if (hbm_address !== ADDR_W'(expected)) begin
                $fatal(1,
                    "block=%0d got=0x%0h expected=0x%0h port=%0d bank=%0d row=%0d",
                    block, hbm_address, expected, port, bank, row);
            end
            got_bank = longint'(hbm_address) >> BANK_SHIFT;
            if ((got_bank / longint'(BANKS_PER_PORT)) != port)
                $fatal(1, "block=%0d remapped bank %0d escaped port %0d",
                       block, got_bank, port);
        end
    endtask

    initial begin
        if ((NUM_PORTS < 1) || ((NUM_PORTS & (NUM_PORTS - 1)) != 0))
            $fatal(1, "test requires power-of-two NUM_PORTS");
        check_block(0);
        check_block(1);
        check_block(longint'(NUM_PORTS) - 1);
        check_block(longint'(NUM_PORTS));
        check_block(longint'(NUM_BANKS) - 1);
        check_block(longint'(NUM_BANKS));
        check_block(63);
        check_block(64);

        if (NUM_PORTS == 8) begin
            m_address = ADDR_W'(64);
            #1;
            if ((hbm_address >> BANK_SHIFT) != 4)
                $fatal(1, "U55C golden mismatch: 64B must map to PC4");
        end

        $display("TEST PASSED: VX_mem_remap P=%0d H=%0d", NUM_BANKS, NUM_PORTS);
        $finish;
    end
endmodule
