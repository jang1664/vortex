# Pre opt_design hook
# Runs before OPT_DESIGN — set optimization constraints

# Add extra setup margin to kernel clocks so Vivado optimizes harder.
# Without this, Vivado stops optimizing at WNS ~0 and the design runs
# with essentially zero margin on silicon.
# Adjust the value (in ns) as needed: 0.5ns = 500ps extra guard band.
set setup_margin_ns 0.3
set hold_margin_ns 0.03
foreach clk [get_clocks -quiet *kernel*] {
    set_clock_uncertainty -setup $setup_margin_ns $clk
    set_clock_uncertainty -hold $hold_margin_ns $clk
    puts "INFO: Added ${setup_margin_ns}ns setup margin and ${hold_margin_ns}ns hold margin to clock [get_property NAME $clk]"
}

report_utilization -file hier_utilization.rpt -hierarchical -hierarchical_percentages
