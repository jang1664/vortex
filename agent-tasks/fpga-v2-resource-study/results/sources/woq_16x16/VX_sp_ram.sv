module VX_sp_ram #(
    parameter DATAW       = 1,
    parameter SIZE        = 1,
    parameter WRENW       = 1,
    parameter OUT_REG     = 0,
    parameter LUTRAM      = 0,
    parameter USE_URAM    = 0,  
    parameter  RDW_MODE = "W",  
    parameter  SRAM_TYPE = "HS",  
    parameter RADDR_REG   = 0,  
    parameter RADDR_RESET = 0,  
    parameter RDW_ASSERT  = 0,
    parameter RESET_RAM   = 0,
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
    input wire [ADDRW-1:0]   addr,
    input wire [DATAW-1:0]   wdata,
    output wire [DATAW-1:0]  rdata
);
    localparam WSELW = DATAW / WRENW;
    localparam FORCE_BRAM = !LUTRAM && (((SIZE) >= 64 || (DATAW) >= 16 || ((SIZE) * (DATAW)) >= 512) && ((SIZE) * (DATAW)) >= 64);
    localparam URAM_COMPATIBLE = (RDW_MODE != "W");
    localparam USE_URAM_FINAL = FORCE_BRAM && (USE_URAM == 1) && URAM_COMPATIBLE;
    if (OUT_REG) begin : g_sync
        if (USE_URAM_FINAL) begin : g_uram
            if (RDW_MODE == "R") begin : g_read_first
                if (WRENW != 1) begin : g_wren
                    (* ram_style = "ultra" *) reg [DATAW-1:0] ram [0:SIZE-1];
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end else begin : g_no_wren
                    (* ram_style = "ultra" *) reg [DATAW-1:0] ram [0:SIZE-1];
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
                            ram[addr] <= wdata; 
                        end
                        if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end
            end else begin : g_no_change
                if (WRENW != 1) begin : g_wren
                    (* ram_style = "ultra" *) reg [DATAW-1:0] ram [0:SIZE-1];
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        else if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end else begin : g_no_wren
                    (* ram_style = "ultra" *) reg [DATAW-1:0] ram [0:SIZE-1];
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
                            ram[addr] <= wdata; 
                        end
                        else if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end
            end
        end else if (FORCE_BRAM) begin : g_bram
            if (RDW_MODE == "W") begin : g_write_first
                if (WRENW != 1) begin : g_wren
                    (* rw_addr_collision = "yes" *) (* ram_style = "block" *) reg [DATAW-1:0] ram [0:SIZE-1];
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
                    reg [ADDRW-1:0] addr_r;
                    always @(posedge clk) begin
                            if (write) begin 
                                for (integer i = 0; i < WRENW; ++i) begin 
                                    if (wren[i]) begin 
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        if (read) begin
                            addr_r <= addr;
                        end
                    end
                    assign rdata = ram[addr_r];
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                        if (read) begin
                            if (write) begin
                                rdata_r <= wdata;
                            end else begin
                                rdata_r <= ram[addr];
                            end
                        end
                    end
                    assign rdata = rdata_r;
                end
            end else if (RDW_MODE == "R") begin : g_read_first
                if (WRENW != 1) begin : g_wren
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                        if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end
            end else if (RDW_MODE == "N") begin : g_no_change
                if (WRENW != 1) begin : g_wren
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        else if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                        else if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end
            end
        end else begin : g_auto
            if (RDW_MODE == "W") begin : g_write_first
                if (WRENW != 1) begin : g_wren
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
                    reg [ADDRW-1:0] addr_r;
                    always @(posedge clk) begin
                            if (write) begin 
                                for (integer i = 0; i < WRENW; ++i) begin 
                                    if (wren[i]) begin 
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        if (read) begin
                            addr_r <= addr;
                        end
                    end
                    assign rdata = ram[addr_r];
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                        if (read) begin
                            if (write) begin
                                rdata_r <= wdata;
                            end else begin
                                rdata_r <= ram[addr];
                            end
                        end
                    end
                    assign rdata = rdata_r;
                end
            end else if (RDW_MODE == "R") begin : g_read_first
                if (WRENW != 1) begin : g_wren
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                        if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end
            end else if (RDW_MODE == "N") begin : g_no_change
                if (WRENW != 1) begin : g_wren
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                        else if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                        else if (read) begin
                            rdata_r <= ram[addr];
                        end
                    end
                    assign rdata = rdata_r;
                end
            end
        end
    end else begin : g_async
        if (FORCE_BRAM) begin : g_bram
            VX_async_ram_patch #(
                .DATAW      (DATAW),
                .SIZE       (SIZE),
                .WRENW      (WRENW),
                .DUAL_PORT  (0),
                .FORCE_BRAM (FORCE_BRAM),
                .RADDR_REG  (RADDR_REG),
                .RADDR_RESET(RADDR_RESET),
                .WRITE_FIRST(RDW_MODE == "W"),
                .INIT_ENABLE(INIT_ENABLE),
                .INIT_FILE  (INIT_FILE),
                .INIT_VALUE (INIT_VALUE)
            ) async_ram_patch (
                .clk   (clk),
                .reset (reset),
                .read  (read),
                .write (write),
                .wren  (wren),
                .waddr (addr),
                .wdata (wdata),
                .raddr (addr),
                .rdata (rdata)
            );
        end else begin : g_auto
            if (RDW_MODE == "W") begin : g_write_first
                if (WRENW != 1) begin : g_wren
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                    end
                    assign rdata = ram[addr];
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                    end
                    assign rdata = ram[addr];
                end
            end else begin : g_read_first
                if (WRENW != 1) begin : g_wren
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
                                        ram[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW]; 
                                    end 
                                end 
                            end
                    end
                    assign rdata = ram[addr];
                end else begin : g_no_wren
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
                            ram[addr] <= wdata; 
                        end
                    end
                    assign rdata = ram[addr];
                end
            end
        end
    end
endmodule
