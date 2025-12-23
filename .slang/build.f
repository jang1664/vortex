// Slang configuration for Vortex GPU
// Top module: Vortex

// Include directories
+incdir+hw/rtl
+incdir+hw/rtl/libs
+incdir+hw/rtl/core
+incdir+hw/rtl/cache
+incdir+hw/rtl/mem
+incdir+hw/rtl/fpu
+incdir+hw/rtl/tcu
+incdir+hw/rtl/interfaces
+incdir+hw/rtl/afu/opae
+incdir+hw/rtl/afu/opae/ccip
+incdir+hw/rtl/afu/xrt
+incdir+hw/dpi

// Define macros (common defaults)
+define+SIMULATION
+define+XLEN=32

// Package files (must be compiled first)
hw/rtl/VX_gpu_pkg.sv
hw/rtl/VX_trace_pkg.sv
hw/rtl/fpu/VX_fpu_pkg.sv
hw/rtl/tcu/VX_tcu_pkg.sv

// Library modules
hw/rtl/libs/VX_allocator.sv
hw/rtl/libs/VX_async_ram_patch.sv
hw/rtl/libs/VX_avs_adapter.sv
hw/rtl/libs/VX_axi_adapter.sv
hw/rtl/libs/VX_axi_write_ack.sv
hw/rtl/libs/VX_bits_concat.sv
hw/rtl/libs/VX_bits_insert.sv
hw/rtl/libs/VX_bits_remove.sv
hw/rtl/libs/VX_bypass_buffer.sv
hw/rtl/libs/VX_cyclic_arbiter.sv
hw/rtl/libs/VX_demux.sv
hw/rtl/libs/VX_divider.sv
hw/rtl/libs/VX_dp_ram.sv
hw/rtl/libs/VX_edge_trigger.sv
hw/rtl/libs/VX_elastic_adapter.sv
hw/rtl/libs/VX_elastic_buffer.sv
hw/rtl/libs/VX_fifo_queue.sv
hw/rtl/libs/VX_find_first.sv
hw/rtl/libs/VX_generic_arbiter.sv
hw/rtl/libs/VX_index_buffer.sv
hw/rtl/libs/VX_index_queue.sv
hw/rtl/libs/VX_lzc.sv
hw/rtl/libs/VX_matrix_arbiter.sv
hw/rtl/libs/VX_mem_bank_adapter.sv
hw/rtl/libs/VX_mem_coalescer.sv
hw/rtl/libs/VX_mem_data_adapter.sv
hw/rtl/libs/VX_mem_scheduler.sv
hw/rtl/libs/VX_multiplier.sv
hw/rtl/libs/VX_mux.sv
hw/rtl/libs/VX_nz_iterator.sv
hw/rtl/libs/VX_onehot_encoder.sv
hw/rtl/libs/VX_onehot_mux.sv
hw/rtl/libs/VX_onehot_shift.sv
hw/rtl/libs/VX_pending_size.sv
hw/rtl/libs/VX_pe_serializer.sv
hw/rtl/libs/VX_pipe_buffer.sv
hw/rtl/libs/VX_pipe_register.sv
hw/rtl/libs/VX_placeholder.sv
hw/rtl/libs/VX_popcount.sv
hw/rtl/libs/VX_priority_arbiter.sv
hw/rtl/libs/VX_priority_encoder.sv
hw/rtl/libs/VX_reduce_tree.sv
hw/rtl/libs/VX_reset_relay.sv
hw/rtl/libs/VX_rr_arbiter.sv
hw/rtl/libs/VX_scan.sv
hw/rtl/libs/VX_scope_switch.sv
hw/rtl/libs/VX_scope_tap.sv
hw/rtl/libs/VX_serial_div.sv
hw/rtl/libs/VX_serial_mul.sv
hw/rtl/libs/VX_shift_register.sv
hw/rtl/libs/VX_skid_buffer.sv
hw/rtl/libs/VX_sp_ram.sv
hw/rtl/libs/VX_stream_arb.sv
hw/rtl/libs/VX_stream_buffer.sv
hw/rtl/libs/VX_stream_omega.sv
hw/rtl/libs/VX_stream_pack.sv
hw/rtl/libs/VX_stream_switch.sv
hw/rtl/libs/VX_stream_unpack.sv
hw/rtl/libs/VX_stream_xbar.sv
hw/rtl/libs/VX_stream_xpoint.sv
hw/rtl/libs/VX_ticket_lock.sv
hw/rtl/libs/VX_toggle_buffer.sv
hw/rtl/libs/VX_transpose.sv

// Interface modules
hw/rtl/interfaces/VX_branch_ctl_if.sv
hw/rtl/interfaces/VX_commit_csr_if.sv
hw/rtl/interfaces/VX_commit_if.sv
hw/rtl/interfaces/VX_commit_sched_if.sv
hw/rtl/interfaces/VX_dcr_bus_if.sv
hw/rtl/interfaces/VX_decode_if.sv
hw/rtl/interfaces/VX_decode_sched_if.sv
hw/rtl/interfaces/VX_dispatch_if.sv
hw/rtl/interfaces/VX_execute_if.sv
hw/rtl/interfaces/VX_fetch_if.sv
hw/rtl/interfaces/VX_ibuffer_if.sv
hw/rtl/interfaces/VX_issue_sched_if.sv
hw/rtl/interfaces/VX_operands_if.sv
hw/rtl/interfaces/VX_result_if.sv
hw/rtl/interfaces/VX_sched_csr_if.sv
hw/rtl/interfaces/VX_schedule_if.sv
hw/rtl/interfaces/VX_scoreboard_if.sv
hw/rtl/interfaces/VX_warp_ctl_if.sv
hw/rtl/interfaces/VX_writeback_if.sv

// Memory subsystem
hw/rtl/mem/VX_gbar_bus_if.sv
hw/rtl/mem/VX_gbar_arb.sv
hw/rtl/mem/VX_gbar_unit.sv
hw/rtl/mem/VX_lmem_switch.sv
hw/rtl/mem/VX_local_mem.sv
hw/rtl/mem/VX_local_mem_top.sv
hw/rtl/mem/VX_lsu_adapter.sv
hw/rtl/mem/VX_lsu_mem_arb.sv
hw/rtl/mem/VX_lsu_mem_if.sv
hw/rtl/mem/VX_mem_arb.sv
hw/rtl/mem/VX_mem_bus_if.sv
hw/rtl/mem/VX_mem_switch.sv

// Cache subsystem
hw/rtl/cache/VX_cache_bank.sv
hw/rtl/cache/VX_cache_bypass.sv
hw/rtl/cache/VX_cache_cluster.sv
hw/rtl/cache/VX_cache_data.sv
hw/rtl/cache/VX_cache_flush.sv
hw/rtl/cache/VX_cache_init.sv
hw/rtl/cache/VX_cache_mshr.sv
hw/rtl/cache/VX_cache_repl.sv
hw/rtl/cache/VX_cache.sv
hw/rtl/cache/VX_cache_tags.sv
hw/rtl/cache/VX_cache_top.sv
hw/rtl/cache/VX_cache_wrap.sv

// FPU
hw/rtl/fpu/VX_fpu_csr_if.sv
hw/rtl/fpu/VX_fp_classifier.sv
hw/rtl/fpu/VX_fp_rounding.sv
hw/rtl/fpu/VX_fcvt_unit.sv
hw/rtl/fpu/VX_fncp_unit.sv
hw/rtl/fpu/VX_fpu_cvt.sv
hw/rtl/fpu/VX_fpu_div.sv
hw/rtl/fpu/VX_fpu_dpi.sv
hw/rtl/fpu/VX_fpu_dsp.sv
hw/rtl/fpu/VX_fpu_fma.sv
hw/rtl/fpu/VX_fpu_fpnew.sv
hw/rtl/fpu/VX_fpu_ncp.sv
hw/rtl/fpu/VX_fpu_sqrt.sv
hw/rtl/fpu/VX_fpu_unit.sv

// TCU (Tensor Compute Unit)
hw/rtl/tcu/bhf/bsg_counting_leading_zeros.sv
hw/rtl/tcu/bhf/VX_tcu_bhf_bf16mul.sv
hw/rtl/tcu/bhf/VX_tcu_bhf_fadd.sv
hw/rtl/tcu/bhf/VX_tcu_bhf_fmul.sv
hw/rtl/tcu/VX_tcu_fedp_bhf.sv
hw/rtl/tcu/VX_tcu_fedp_dpi.sv
hw/rtl/tcu/VX_tcu_fedp_dsp.sv
hw/rtl/tcu/VX_tcu_fedp_int.sv
hw/rtl/tcu/VX_tcu_fp.sv
hw/rtl/tcu/VX_tcu_int.sv
hw/rtl/tcu/VX_tcu_top.sv
hw/rtl/tcu/VX_tcu_unit.sv
hw/rtl/tcu/VX_tcu_uops.sv

// Core modules
hw/rtl/core/VX_alu_int.sv
hw/rtl/core/VX_alu_muldiv.sv
hw/rtl/core/VX_alu_unit.sv
hw/rtl/core/VX_commit.sv
hw/rtl/core/VX_csr_data.sv
hw/rtl/core/VX_csr_unit.sv
hw/rtl/core/VX_dcr_data.sv
hw/rtl/core/VX_decode.sv
hw/rtl/core/VX_dispatch.sv
hw/rtl/core/VX_dispatch_unit.sv
hw/rtl/core/VX_execute.sv
hw/rtl/core/VX_fetch.sv
hw/rtl/core/VX_gather_unit.sv
hw/rtl/core/VX_ibuffer.sv
hw/rtl/core/VX_ipdom_stack.sv
hw/rtl/core/VX_issue_slice.sv
hw/rtl/core/VX_issue.sv
hw/rtl/core/VX_issue_top.sv
hw/rtl/core/VX_lsu_slice.sv
hw/rtl/core/VX_lsu_unit.sv
hw/rtl/core/VX_mem_unit.sv
hw/rtl/core/VX_mem_unit_top.sv
hw/rtl/core/VX_opc_unit.sv
hw/rtl/core/VX_operands.sv
hw/rtl/core/VX_pe_switch.sv
hw/rtl/core/VX_schedule.sv
hw/rtl/core/VX_scoreboard.sv
hw/rtl/core/VX_sfu_unit.sv
hw/rtl/core/VX_split_join.sv
hw/rtl/core/VX_uop_sequencer.sv
hw/rtl/core/VX_uuid_gen.sv
hw/rtl/core/VX_wctl_unit.sv
hw/rtl/core/VX_core.sv
hw/rtl/core/VX_core_top.sv

// Top-level modules
hw/rtl/VX_socket.sv
hw/rtl/VX_cluster.sv
hw/rtl/Vortex.sv
hw/rtl/Vortex_axi.sv

// Top module specification
--top Vortex
