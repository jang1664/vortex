# Read-only primitive attribution from an optimized OOC checkpoint.
if {$argc != 2} {error "Expected checkpoint output_csv"}
lassign $argv checkpoint output
set_param general.maxThreads 4
open_checkpoint $checkpoint
set fh [open $output w]
puts $fh "cell,REF_NAME,USE_MULT,USE_SIMD,AREG,BREG,MREG,PREG"
foreach cell [lsort [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]] {
    set row [list $cell DSP48E2]
    set props [list_property $cell]
    foreach key {USE_MULT USE_SIMD AREG BREG MREG PREG} {
        set val "unknown"
        foreach candidate [list $key CONFIG.$key] {
            if {[lsearch -exact $props $candidate] >= 0} {set val [get_property $candidate $cell]; break}
        }
        lappend row $val
    }
    puts $fh [join $row ,]
}
close $fh
close_design
