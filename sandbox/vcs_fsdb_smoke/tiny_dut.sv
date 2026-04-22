// Minimal stand-in for the real vortex_afu. The module name must match the
// bind target in vcs_fsdb_init.sv; ports can be anything because the bind
// instance (`bind vortex_afu vcs_fsdb_dump_init u_vcs_fsdb_dump_init ()`)
// takes no ports.
//
// A trivial clocked counter gives $fsdbDumpvars some signal activity to
// record, so the resulting FSDB is non-trivial and confirms dumping works.

module vortex_afu (
    input logic clk,
    input logic rst_n
);
    logic [7:0] counter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) counter <= 8'h00;
        else        counter <= counter + 8'h01;
    end

    // Array of packed data so $fsdbDumpMDA() has something interesting.
    logic [15:0] mem [0:3];
    always_ff @(posedge clk) begin
        mem[counter[1:0]] <= {counter, ~counter};
    end
endmodule
