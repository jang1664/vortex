set task_dir [file dirname [file normalize [info script]]]
set build_dir /home/jaeyongjang/project.local/vortex_base/build/hw/syn/xilinx/xrt/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem_v2_xilinx_u55c_gen3x16_xdma_3_202210_1_hw
open_checkpoint $build_dir/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_postroute_physopt.dcp
set paths [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 50000 -nworst 1]
set out [open $task_dir/failing_paths.tsv w]
puts $out "slack\tstartpoint\tendpoint"
foreach path $paths {
    set sp [get_property NAME [get_property STARTPOINT_PIN $path]]
    set ep [get_property NAME [get_property ENDPOINT_PIN $path]]
    puts $out "[get_property SLACK $path]\t$sp\t$ep"
}
close $out
puts "FAILING_PATH_COUNT [llength $paths]"
# Complete the TSV before any slow detailed reports. Bound report scopes to
# real module roots; direct register names must never become separate scopes.
set seen [dict create]
foreach path $paths {
    set ep [get_property NAME [get_property ENDPOINT_PIN $path]]
    if {[regexp {/gemm_node/(u_tmem_subsystem/)?([^/]+)/} $ep unused sub module]
        && $module in {u_dma_engine u_ldma_input u_ldma_weight u_ldma_scale u_ldma_zero_point u_ldma_output u_VX_gemm_ctrl u_tmem_dma_ctrl u_VX_gemm_unit_v2}
        && ![dict exists $seen $module]} {
        dict set seen $module 1
        report_timing -of_objects $path -file $task_dir/worst_${module}.rpt
    }
}
report_timing -delay_type max -max_paths 500 -nworst 1 -path_type summary -file $task_dir/top500.rpt
report_high_fanout_nets -max_nets 100 -timing -file $task_dir/high_fanout.rpt
foreach module {VX_gemm_node VX_gemm_ctrl VX_gemm_tmem_dma_ctrl VX_tmem_subsystem VX_dma_engine} {
    set roots [get_cells -hier -quiet -filter "REF_NAME =~ *$module"]
    puts "UTIL_ROOTS $module [llength $roots]"
    report_utilization -cells $roots -slr -hierarchical -hierarchical_depth 1 -file $task_dir/util_${module}.rpt
}
close_design
exit
