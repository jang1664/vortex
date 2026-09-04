# VX_gemm_node out-of-context synthesis

This scaffold synthesizes the complete `VX_gemm_node` clock domain without
modifying production RTL.  It is fixed to the U55C
`xcu55c-fsvh2892-2L-e` part and a 7.000 ns `core_clock` constraint.

The runner defaults to a manifest-only dry run.  It sources the WLOAD4 config
`configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`, adds the
same XLEN/U55C synthesis-context defines used by the XRT flow, resolves the
ordered RTL/IP source list, and records hashes, revision, dirty state, part,
clock, Vivado path, and synthesis options.  Source, XCI, and every header
reachable through a recorded include directory are covered by hash manifests.

```bash
ci/run_gemm_node_ooc.sh \
  --output-dir /tmp/gemm-node-ooc-dry-run \
  --ip-dir build/sim/xrtsim_vcs/xilinx_ip
```

To launch synthesis explicitly:

```bash
ci/run_gemm_node_ooc.sh \
  --output-dir build/gemm-node-ooc-7ns \
  --ip-dir build/sim/xrtsim_vcs/xilinx_ip \
  --vivado-bin /tool/Program/Xilinx/2025.1/Vivado/bin/vivado \
  --jobs 8 \
  --run
```

For an otherwise identical response-storage A/B matrix, pass
`--stream-response-data-ram 0|1` and `--wide-response-data-ram 0|1`. The
selected values replace the production config defines and are recorded in
both `command.txt` and `defines.txt`.

The synthesis run writes hierarchical utilization, max-delay setup timing
summary and paths, methodology, a machine-readable setup gate, Vivado
metadata, and logs.  A checkpoint is omitted unless `--write-checkpoint` is
also supplied.  The setup gate requires WNS >= 0.000 ns, TNS == 0.000 ns, and
zero failing endpoints.
