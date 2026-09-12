# Read-only timing extraction from the completed physical implementation.
set checkpoint [lindex $argv 0]
set output [lindex $argv 1]
file mkdir $output
open_checkpoint $checkpoint
set clock [get_clocks clk_kernel_00_unbuffered_net]
report_clocks -file $output/clocks.rpt
report_timing -group $clock -delay_type max -max_paths 200 -nworst 1 -input_pins -file $output/kernel_top200.rpt
set groups {
    operands *opc_unit/*
    scheduler *u_microtile_readiness_scheduler/*
    ctrl *gemm_node/u_VX_gemm_ctrl/*
    compute *u_compute_core/*
    input_dma *u_ldma_input/*
    output_dma *u_ldma_output/*
    weight_dma *u_ldma_weight/*
    hbm_dma *u_dma_engine/*
    tmem *u_tmem_subsystem/*
    issue *core/issue/*
    memory *core/mem_unit/*
}
foreach {label pattern} $groups {
    set registers [get_cells -hierarchical -filter "IS_SEQUENTIAL == 1 && NAME =~ $pattern"]
    puts "TIMING_GROUP $label registers=[llength $registers]"
    if {[llength $registers] == 0} {continue}
    report_timing -from $registers -group $clock -delay_type max -max_paths 30 -nworst 1 -input_pins -file $output/$label.rpt
}
close_design
