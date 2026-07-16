#!/bin/bash
export DISPLAY=:1

bin_path=$1 
vivado -mode gui -nolog -nojournal -notrace \
  -source hw/syn/xilinx/xrt/export_photo.tcl \
  -tclargs ${bin_path}/_x/link/vivado/vpl/prj/prj.xpr