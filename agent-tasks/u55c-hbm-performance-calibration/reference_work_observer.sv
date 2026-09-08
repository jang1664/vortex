`timescale 1ns/1ps
// Non-driving controller event trace. Queue occupancy is not CPU stall time.
module reference_work_observer #(parameter N=6)(
    input wire clk, reset, start, done, active, output_done,
    input wire [N-1:0] issue, retire, inflight_empty, queue_empty
);
    integer events=0;
    always @(posedge clk) begin
        if (reset === 1'b0 && events < 16384
            && (start || done || output_done || (|issue) || (|retire))) begin
            $display("REFERENCE_WORK t=%0t start=%b done=%b active=%b output=%b issue=%b retire=%b busy=%b queued=%b",
                $time, start, done, active, output_done, issue, retire,
                ~inflight_empty, ~queue_empty);
            events=events+1;
        end
    end
endmodule
bind VX_gemm_ctrl reference_work_observer #(.N(N_CHILDREN)) reference_work_i(
    .clk(clk), .reset(reset), .start(cfg_fire), .done(done_fire),
    .active(invocation_active_q), .output_done(output_store_done_i),
    .issue(child_issue_fire_v), .retire(child_completion_pop_v),
    .inflight_empty(child_inflight_empty_v), .queue_empty(child_q_empty_v));
