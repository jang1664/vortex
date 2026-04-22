// FSDB dump initializer for Vitis hw_emu with VCS.
//
// Synopsys canonical FSDB flow: instantiate a module with $fsdbDump* system
// tasks in an initial block at the top hierarchy. We use SystemVerilog `bind`
// to inject the dump initializer into every instance of vortex_afu (our
// kernel top) without modifying any generated code.
//
// Why bind to vortex_afu (kernel top) instead of pfm_top_wrapper (platform
// top): Vivado's kernel IP packager (package_kernel.tcl → package_xo) only
// accepts files whose module references are in kernel scope. A bind targeting
// pfm_top_wrapper — which lives in the Vitis platform outside the .xo — is
// silently dropped at packaging time, and vlogan never sees this SV during
// sim. Binding to vortex_afu keeps the target in scope, so the file survives
// packaging and participates in elaboration. FSDB coverage is the kernel and
// everything it instantiates — exactly the Vortex internals we care about —
// while platform scaffolding (sim_qdma, hmss, xtlm) is excluded.
//
// Why not xrt.ini [Emulation] user_pre_sim_script? Vitis 2025.1's
// -user-pre-sim-script flag (launch_emulator) is xsim-centric — its own CLI
// help documents it with xsim-only commands (add_wave, log_wave) and the
// Vitis VCS backend does not propagate USER_PRE_SIM_SCRIPT env to simv.
// Vivado's VCS integration exposes only compile.tcl.pre and simulate.tcl.post
// as official extension points, so RTL-level injection is the only portable
// path.
//
// Enabled by +define+VCS_FSDB_DUMP (emitted by gen_vitis_ini.py when
// SIMULATOR=vcs and DEBUG is set). Requires -debug_access+all at VCS
// elaboration (also emitted) so Verdi PLI is linked and $fsdbDump* system
// tasks exist.

`ifdef VCS_FSDB_DUMP
module vcs_fsdb_dump_init;
    initial begin
        $fsdbDumpfile("vortex.fsdb");
        $fsdbDumpvars(0);
        $fsdbDumpMDA();
    end
endmodule

bind vortex_afu vcs_fsdb_dump_init u_vcs_fsdb_dump_init ();
`endif
