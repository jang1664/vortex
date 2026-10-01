if {$argc != 3} {error "Expected baseline_compute_dir output_dir testbench"}
lassign $argv baseline out tb
set_param general.maxThreads 4
create_project vendor_ip_check "$out/project" -force -part xcu55c-fsvh2892-2L-e
foreach name {xil_f16mul_latency1 xil_f32mul_latency1 xil_f32add_latency1} {
    read_ip "$baseline/ip/$name/$name.xci"
}
add_files -fileset sim_1 -norecurse $tb
set_property top vendor_ip_tb [get_filesets sim_1]
set_property target_simulator XSim [current_project]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
