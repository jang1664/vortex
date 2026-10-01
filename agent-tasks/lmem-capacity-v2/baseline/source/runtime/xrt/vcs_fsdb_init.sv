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
`ifndef DISABLE_FSDB
module vcs_fsdb_dump_init;
    // Scope the dump to `vortex_afu` (kernel) and everything below it.
    // $fsdbDumpvars(0) without scope dumps from $root — on this design
    // that is ~600K signals including pfm_top_wrapper, sim_qdma, HMSS,
    // smartconnects. The FSDB consumer thread cannot keep up; the
    // default 64 MB ring buffer rolls over every ~few us of sim time,
    // overwriting earlier transitions. Net effect: the final .fsdb
    // contains only the last handful of microseconds, which is usually
    // just platform teardown — all actual kernel activity is lost.
    //
    // Scoping to vortex_afu reduces the signal count by >30x and keeps
    // the whole kernel execution inside the buffer window. Platform
    // scaffolding (sim_qdma / HMSS / AXI VIP) is excluded on purpose —
    // it is mostly SystemC anyway and not useful for kernel debug.
    //
    // Periodic $fsdbDumpflush ensures disk contents stay current even
    // under bursty activity; without it, a killed simv can still lose
    // the last buffered window.
    initial begin
        $fsdbDumpfile("vortex.fsdb");
        $fsdbDumpvars(0, vortex_afu);
        $fsdbDumpMDA();
        forever begin
            #1us;
            $fsdbDumpflush;
        end
    end
endmodule

bind vortex_afu vcs_fsdb_dump_init u_vcs_fsdb_dump_init ();
`endif
`endif
