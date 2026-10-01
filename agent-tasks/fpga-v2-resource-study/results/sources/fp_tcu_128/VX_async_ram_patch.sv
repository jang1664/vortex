module VX_async_ram_patch #(
    parameter DATAW       = 1,
    parameter SIZE        = 1,
    parameter WRENW       = 1,
    parameter DUAL_PORT   = 0,
    parameter FORCE_BRAM  = 0,
    parameter RADDR_REG   = 0,  
    parameter RADDR_RESET = 0,  
    parameter WRITE_FIRST = 0,
    parameter INIT_ENABLE = 0,
    parameter INIT_FILE   = "",
    parameter [DATAW-1:0] INIT_VALUE = 0,
    parameter ADDRW       = (((SIZE) > 1) ? $clog2(SIZE) : 1)
) (
    input wire               clk,
    input wire               reset,
    input wire               read,
    input wire               write,
    input wire [WRENW-1:0]   wren,
    input wire [ADDRW-1:0]   waddr,
    input wire [DATAW-1:0]   wdata,
    input wire [ADDRW-1:0]   raddr,
    output wire [DATAW-1:0]  rdata
);
    localparam WSELW = DATAW / WRENW;
    (* keep = "true" *) wire [ADDRW-1:0] raddr_w, raddr_s;
    (* keep = "true" *) wire read_s;
    assign raddr_w = raddr;
   wire raddr_reset_w;
    if (RADDR_RESET) begin : g_raddr_reset
        (* keep = "true" *) wire raddr_reset;
        assign raddr_reset = 0;
        assign raddr_reset_w = raddr_reset;
    end else begin : g_no_raddr_reset
        assign raddr_reset_w = 0;
    end
    VX_placeholder #(
        .I (ADDRW + 1),
        .O (ADDRW + 1)
    ) placeholder1 (
        .in  ({raddr_w, raddr_reset_w}),
        .out ({raddr_s, read_s})
    );
    wire [DATAW-1:0] rdata_s;
    if (1) begin : g_sync_ram
        if (WRENW != 1) begin : g_wren
            if (FORCE_BRAM) begin : g_bram
                if (WRITE_FIRST) begin : g_write_first
    (* ram_style = "block" *) (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [ADDRW-1:0] raddr_r; 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
        if (read_s) begin 
            raddr_r <= raddr_s; 
        end 
    end 
    assign rdata_s = ram[raddr_r];
                end else begin : g_read_first
    (* ram_style = "block" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [DATAW-1:0] rdata_r; 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
        if (read_s) begin 
            rdata_r <= ram[raddr_s]; 
        end 
    end 
    assign rdata_s = rdata_r;
                end
            end else begin : g_lutram
                if (WRITE_FIRST) begin : g_write_first
     (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [ADDRW-1:0] raddr_r; 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
        if (read_s) begin 
            raddr_r <= raddr_s; 
        end 
    end 
    assign rdata_s = ram[raddr_r];
                end else begin : g_read_first
     reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [DATAW-1:0] rdata_r; 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
        if (read_s) begin 
            rdata_r <= ram[raddr_s]; 
        end 
    end 
    assign rdata_s = rdata_r;
                end
            end
        end else begin : g_no_wren
            if (FORCE_BRAM) begin : g_bram
                if (WRITE_FIRST) begin : g_write_first
    (* ram_style = "block" *) (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [ADDRW-1:0] raddr_r; 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
        if (read_s) begin 
            raddr_r <= raddr_s; 
        end 
    end 
    assign rdata_s = ram[raddr_r];
                end else begin : g_read_first
    (* ram_style = "block" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [DATAW-1:0] rdata_r; 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
        if (read_s) begin 
            rdata_r <= ram[raddr_s]; 
        end 
    end 
    assign rdata_s = rdata_r;
                end
            end else begin : g_lutram
                if (WRITE_FIRST) begin : g_write_first
     (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [ADDRW-1:0] raddr_r; 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
        if (read_s) begin 
            raddr_r <= raddr_s; 
        end 
    end 
    assign rdata_s = ram[raddr_r];
                end else begin : g_read_first
     reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    reg [DATAW-1:0] rdata_r; 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
        if (read_s) begin 
            rdata_r <= ram[raddr_s]; 
        end 
    end 
    assign rdata_s = rdata_r;
                end
            end
        end
    end
    if (RADDR_REG) begin : g_raddr_reg
        assign rdata = rdata_s;
    end else begin : g_async_ram
        (* keep = "true" *) wire is_raddr_reg;
        VX_placeholder #(
            .O (1)
        ) placeholder2 (
            .in  (1'b0),
            .out (is_raddr_reg)
        );
        wire [DATAW-1:0] rdata_a;
        if (DUAL_PORT) begin : g_dp
            if (WRENW != 1) begin : g_wren
                if (WRITE_FIRST) begin : g_write_first
    (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
    end 
    assign rdata_a = ram[raddr];
                end else begin : g_read_first
    (* rw_addr_collision = "no" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
    end 
    assign rdata_a = ram[raddr];
                end
            end else begin : g_no_wren
                if (WRITE_FIRST) begin : g_write_first
    (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
    end 
    assign rdata_a = ram[raddr];
                end else begin : g_read_first
    (* rw_addr_collision = "no" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
    end 
    assign rdata_a = ram[raddr];
                end
            end
        end else begin : g_sp
            if (WRENW != 1) begin : g_wren
                if (WRITE_FIRST) begin : g_write_first
    (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
    end 
    assign rdata_a = ram[waddr];
                end else begin : g_read_first
    (* rw_addr_collision = "no" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            for (integer i = 0; i < WRENW; ++i) begin 
                if (wren[i]) begin 
                    ram[waddr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                end 
            end 
        end 
    end 
    assign rdata_a = ram[waddr];
                end
            end else begin : g_no_wren
                if (WRITE_FIRST) begin : g_write_first
    (* rw_addr_collision = "yes" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
    end 
    assign rdata_a = ram[waddr];
                end else begin : g_read_first
    (* rw_addr_collision = "no" *) reg [DATAW-1:0] ram [0:SIZE-1]; 
    if (INIT_ENABLE != 0) begin : g_init 
        if (INIT_FILE != "") begin : g_file 
            initial $readmemh(INIT_FILE, ram); 
        end else begin : g_value 
            initial begin 
                for (integer i = 0; i < SIZE; ++i) begin : g_i 
                    ram[i] = INIT_VALUE; 
                end 
            end 
        end 
    end 
    always @(posedge clk) begin 
        if (write) begin 
            ram[waddr] <= wdata; 
        end 
    end 
    assign rdata_a = ram[waddr];
                end
            end
        end
        assign rdata = is_raddr_reg ? rdata_s : rdata_a;
    end
endmodule
