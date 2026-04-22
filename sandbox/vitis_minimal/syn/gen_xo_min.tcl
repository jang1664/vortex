# Minimal gen_xo wrapper — invokes package_kernel_min.tcl and emits the .xo.
# No xilinx_ip_gen step (sandbox kernel has no Xilinx IP dependencies).

if { $::argc < 4 || $::argc > 5 } {
    puts "ERROR: Program \"$::argv0\" requires 4 or 5 arguments!\n"
    puts "Usage: $::argv0 <xoname> <krnl_name> <vcs_file> <build_dir> \[<device_part>\]\n"
    exit
}

set xoname    [lindex $::argv 0]
set krnl_name [lindex $::argv 1]
set vcs_file  [lindex $::argv 2]
set build_dir [lindex $::argv 3]
set device_part ""
if { $::argc == 5 } {
    set device_part [lindex $::argv 4]
}

set script_dir [file dirname [file normalize [info script]]]

if {[file exists "${xoname}"]} {
    file delete -force "${xoname}"
}

if {[string length $device_part] != 0} {
    set argv [list ${krnl_name} ${vcs_file} ${build_dir} ${device_part}]
    set argc 4
} else {
    set argv [list ${krnl_name} ${vcs_file} ${build_dir}]
    set argc 3
}
source ${script_dir}/package_kernel_min.tcl

package_xo -xo_path ${xoname} -kernel_name ${krnl_name} \
    -ip_directory "${build_dir}/xo/packaged_kernel"
