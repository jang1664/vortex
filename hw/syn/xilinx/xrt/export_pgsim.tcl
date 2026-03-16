write_sdf -cell level0_i/ulp/vortex_afu_1 -force vortex_afu_post_impl.sdf
write_verilog -cell level0_i/ulp/vortex_afu_1 -mode timesim -force vortex_afu_post_impl.v
source $env(VORTEX_HOME)/hw/syn/xilinx/xrt/report_vortex_afu_boundary_delays.tcl
report_vortex_afu_boundary_delays -out_dir ./my_reports