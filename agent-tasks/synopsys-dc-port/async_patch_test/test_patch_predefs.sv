// Pre-definitions for test_patch elaboration.
// Same approach as the SRAM dumper: VCS's command-line +define+ does not
// reliably propagate to package-included files, so we set them via include.
`define SYNTHESIS
`define NDEBUG
`define XLEN_64
// Synopsys vendor flag toggled by run_test.sh (passed via +define+SYNOPSYS or not)
