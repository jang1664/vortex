# Identical OOC clock target for both variants; no placement or route.
create_clock -name core_clock -period 5.000 [get_ports clk]
set_false_path -from [get_ports reset]
