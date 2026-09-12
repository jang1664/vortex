`include "VX_define.vh"
module tb_types;
    import VX_gpu_pkg::*;
    localparam int ORIGINAL_BITS = UUID_WIDTH + NW_WIDTH + PC_BITS
                                + 3*NUM_REGS_BITS + 773;
    gemm_unified_cmd_t command_word;
    initial begin
        assert ($bits(gemm_wait_meta_t) == 38
             && $bits(gemm_prepare_meta_t) == 48
             && $bits(gemm_notify_meta_t) == 39
             && GEMM_SYNC_REG_ID_WIDTH == 5)
            else $fatal(1, "common metadata width changed");
`ifdef GEMM_NAIVE
        assert ($bits(command_word) == ORIGINAL_BITS + 130
             && GEMM_NUM_SYNC_REGS == 23
             && GEMM_RID_SRC_FREE0 == 21 && GEMM_RID_SRC_FREE1 == 22
             && $bits(command_word.naive_final_base) == 64)
            else $fatal(1, "naive metadata allocation mismatch");
`else
        assert ($bits(command_word) == ORIGINAL_BITS && GEMM_NUM_SYNC_REGS == 21)
            else $fatal(1, "improve metadata changed");
`endif
        $display("TEST PASSED metadata widths command=%0d counters=%0d", $bits(command_word), GEMM_NUM_SYNC_REGS);
        $finish;
    end
endmodule
