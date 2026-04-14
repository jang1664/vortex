// Restores Vortex assertion macros after third-party libraries such as
// common_cells/assertions.svh redefine generic names like `VX_ASSERT`.

`ifdef VX_ASSERT
`undef VX_ASSERT
`endif

`ifdef VX_RUNTIME_ASSERT
`undef VX_RUNTIME_ASSERT
`endif

`ifdef VX_STATIC_ASSERT
`undef VX_STATIC_ASSERT
`endif

`ifdef ERROR
`undef ERROR
`endif

`ifdef SIMULATION

`define VX_STATIC_ASSERT(cond, msg) \
    /* verilator lint_off GENUNNAMED */ \
    initial if (!(cond)) begin \
        $error msg; \
    end \
    /* verilator lint_on GENUNNAMED */

`define ERROR(msg) \
    $error msg

`define VX_ASSERT(cond, msg) \
    assert(cond) else $error msg

`define VX_RUNTIME_ASSERT(cond, msg) \
    always @(posedge clk) begin   \
        if (!reset) begin         \
            `VX_ASSERT(cond, msg);   \
        end                       \
    end

`else

`define VX_STATIC_ASSERT(cond, msg)
`define ERROR(msg)
`define VX_ASSERT(cond, msg)
`define VX_RUNTIME_ASSERT(cond, msg)

`endif
