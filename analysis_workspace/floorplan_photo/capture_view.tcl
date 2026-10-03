# Only source this in the disposable automatic-capture session. Vivado has no
# per-Pblock visibility switch here, so omit these constraints from its in-memory
# snapshot. Do not save the design or run implementation after this step.
# Existing cell locations, highlights, and all other Pblocks are retained.
set capture_pblocks [get_pblocks -quiet {
    pblock_gemm_slr0 pblock_gemm_slr1 pblock_gemm_slr2
}]
if {[llength $capture_pblocks]} {
    puts "Capture view: omitting Pblocks: [join $capture_pblocks {, }]"
    delete_pblocks $capture_pblocks
}
