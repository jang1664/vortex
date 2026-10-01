# Validate IP-XACT register properties without synthesis or implementation.
set core [ipx::create_core local vortex capacity_check 1.0]
set mmap [ipx::add_memory_map s_axi_ctrl $core]
set block [ipx::add_address_block registers $mmap]
set reg [ipx::add_register LMEM_SIZE $block]
set_property description "Exact local memory capacity in bytes" $reg
set_property address_offset 0xD0 $reg
set_property size 32 $reg
set_property access read-only $reg
if {[get_property address_offset $reg] != 208 || [get_property size $reg] != 32
 || [get_property access $reg] ne "read-only"} {
    error "Exact LMEM register metadata mismatch"
}
puts "TEST PASSED: exact LMEM read-only IP-XACT register metadata"
exit
