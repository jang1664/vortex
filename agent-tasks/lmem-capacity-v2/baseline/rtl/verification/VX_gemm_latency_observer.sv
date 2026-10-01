`ifndef VX_GEMM_LATENCY_OBSERVER_SV
`define VX_GEMM_LATENCY_OBSERVER_SV
`ifndef SYNTHESIS
// synthesis translate_off
// Observation only: all inputs are sampled before the accepting rising edge.
// output_store_done_i is a controller-facing retirement pulse. In the naive
// cache path it is NOT a guarantee of final HBM write visibility.
module VX_gemm_latency_observer #(
    parameter string INSTANCE_ID = "",
    parameter string BACKEND = "",
    parameter int MAX_PENDING = 16
) (
    input wire clk,
    input wire reset,
    input wire cfg_start_fire,
    input wire [31:0] cfg_entry_id,
    input wire store_done,
    input wire done_valid,
    input wire done_ready,
    input wire [31:0] done_entry_id
);
    typedef struct {
        bit occupied;
        bit seen_store;
        bit seen_valid;
        logic [31:0] entry_id;
        longint unsigned sequence_id;
        longint unsigned e_cfg;
        longint unsigned e_store;
        longint unsigned e_valid;
        longint unsigned store_count;
    } observation_t;

    observation_t jobs[MAX_PENDING];
    longint unsigned edge_index = 0;
    longint unsigned next_sequence = 0;
    longint unsigned epoch = 0;
    bit in_reset = 0;
    int active_slot = -1;
    longint unsigned completed_count = 0;
    longint unsigned last_gemm, last_store, last_finalize;
    longint unsigned last_delivery, last_handshake;
    longint unsigned last_store_count;

    // Blocking assignments intentionally implement one observation transaction:
    // cfg, store and notification may all be sampled on the same edge.
    always @(posedge clk) begin : observe
        int slot;
        if (reset) begin
            if (!in_reset)
                epoch = epoch + 1;
            in_reset = 1;
            active_slot = -1;
            completed_count = 0;
            next_sequence = 0;
            for (int i = 0; i < MAX_PENDING; ++i)
                jobs[i] = '{default: '0};
        end else begin
            in_reset = 0;
            if (edge_index == '1)
                $fatal(1, "GEMM_LATENCY edge counter overflow: %s", INSTANCE_ID);
            if (cfg_start_fire) begin
                if (active_slot >= 0 && !jobs[active_slot].seen_valid
                    && !(done_valid && done_entry_id == jobs[active_slot].entry_id))
                    $fatal(1, "GEMM_LATENCY overlapping compute invocations: %s", INSTANCE_ID);
                slot = -1;
                for (int i = 0; i < MAX_PENDING; ++i)
                    if (slot < 0 && !jobs[i].occupied)
                        slot = i;
                if (slot < 0)
                    $fatal(1, "GEMM_LATENCY pending observation capacity exhausted");
                jobs[slot] = '{default: '0};
                jobs[slot].occupied = 1;
                jobs[slot].entry_id = cfg_entry_id;
                jobs[slot].sequence_id = next_sequence;
                jobs[slot].e_cfg = edge_index;
                next_sequence = next_sequence + 1;
                active_slot = slot;
                $display("GEMM_LATENCY_CFG instance=%s backend=%s epoch=%0d job=%0d entry_id=%0d e_cfg=%0d",
                    INSTANCE_ID, BACKEND, epoch, jobs[slot].sequence_id,
                    cfg_entry_id, edge_index);
            end
            if (store_done) begin
                if (active_slot < 0 || !jobs[active_slot].occupied
                    || jobs[active_slot].seen_valid)
                    $fatal(1, "GEMM_LATENCY store outside active invocation: %s", INSTANCE_ID);
                jobs[active_slot].seen_store = 1;
                jobs[active_slot].e_store = edge_index;
                jobs[active_slot].store_count = jobs[active_slot].store_count + 1;
            end
            if (done_valid) begin
                slot = -1;
                // Oldest matching invocation wins if an entry ID is reused.
                for (int i = 0; i < MAX_PENDING; ++i) begin
                    if (jobs[i].occupied && jobs[i].entry_id == done_entry_id) begin
                        if (slot < 0)
                            slot = i;
                        else if (jobs[i].sequence_id < jobs[slot].sequence_id)
                            slot = i;
                    end
                end
                if (slot < 0)
                    $fatal(1, "GEMM_LATENCY unmatched done entry=%0d", done_entry_id);
                if (!jobs[slot].seen_valid) begin
                    if (!jobs[slot].seen_store)
                        $fatal(1, "GEMM_LATENCY nonempty invocation has no store retirement");
                    jobs[slot].seen_valid = 1;
                    jobs[slot].e_valid = edge_index;
                    $display("GEMM_LATENCY_VALID instance=%s backend=%s epoch=%0d job=%0d entry_id=%0d e_cfg=%0d e_store=%0d e_valid=%0d L_gemm=%0d L_store=%0d L_finalize=%0d store_endpoint=output_store_done_i visibility=controller_retirement_only",
                        INSTANCE_ID, BACKEND, epoch, jobs[slot].sequence_id,
                        done_entry_id, jobs[slot].e_cfg, jobs[slot].e_store,
                        edge_index, edge_index - jobs[slot].e_cfg,
                        jobs[slot].e_store - jobs[slot].e_cfg,
                        edge_index - jobs[slot].e_store);
                end
                if (done_ready) begin
                    last_gemm = jobs[slot].e_valid - jobs[slot].e_cfg;
                    last_store = jobs[slot].e_store - jobs[slot].e_cfg;
                    last_finalize = jobs[slot].e_valid - jobs[slot].e_store;
                    last_delivery = edge_index - jobs[slot].e_valid;
                    last_handshake = edge_index - jobs[slot].e_cfg;
                    last_store_count = jobs[slot].store_count;
                    completed_count = completed_count + 1;
                    $display("GEMM_LATENCY_DONE instance=%s backend=%s epoch=%0d job=%0d entry_id=%0d e_cfg=%0d e_store=%0d e_valid=%0d e_hs=%0d L_gemm=%0d L_store=%0d L_finalize=%0d L_delivery=%0d L_to_handshake=%0d stores=%0d store_endpoint=output_store_done_i visibility=controller_retirement_only",
                        INSTANCE_ID, BACKEND, epoch, jobs[slot].sequence_id,
                        done_entry_id, jobs[slot].e_cfg, jobs[slot].e_store,
                        jobs[slot].e_valid, edge_index, last_gemm, last_store,
                        last_finalize, last_delivery, last_handshake, last_store_count);
                    jobs[slot].occupied = 0;
                    if (active_slot == slot)
                        active_slot = -1;
                end
            end
        end
        edge_index = edge_index + 1;
    end
endmodule
// synthesis translate_on
`endif
`endif
