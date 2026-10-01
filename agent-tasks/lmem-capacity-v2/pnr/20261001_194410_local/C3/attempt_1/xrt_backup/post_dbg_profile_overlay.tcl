# Align the ULP clock wizard defaults with user-requested kernel frequencies
# so the synthesized MMCM settings match the implementation-time clock
# constraints that Vitis generates.

proc vortex_update_kernel_clkwiz_freqs {} {
  if {![info exists ::kernel_clock_freqs]} {
    puts "INFO: VORTEX kernel_clock_freqs is not available; skipping clock wizard update"
    return
  }

  foreach clock_name [dict keys $::kernel_clock_freqs] {
    set dict_clock [dict get $::kernel_clock_freqs $clock_name]
    set is_user_set [dict get $dict_clock is_user_set]
    if {![string equal -nocase $is_user_set "true"]} {
      continue
    }

    set port_name [dict get $dict_clock port]
    set clock_freq [dict get $dict_clock freq]
    set clkwiz_cell [get_bd_cells -quiet "/ulp_ucs/${port_name}_hierarchy/clkwiz_${port_name}"]
    if {[llength $clkwiz_cell] == 0} {
      puts "WARNING: VORTEX failed to find clock wizard for ${port_name}; skipping"
      continue
    }

    set freq_str [format "%.3f" $clock_freq]
    set_property -dict [list CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $freq_str] $clkwiz_cell
    puts "INFO: VORTEX updated $clkwiz_cell CLKOUT1_REQUESTED_OUT_FREQ to ${freq_str} MHz"
  }

  validate_bd_design
}

vortex_update_kernel_clkwiz_freqs
