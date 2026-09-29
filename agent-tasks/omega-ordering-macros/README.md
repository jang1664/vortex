# Selectable Omega ordering

`VX_stream_omega.sv` is unchanged between historical C3 RTL (`93f4ae97d`)
and the comparison baseline (`18ab7f92`). Commit `a534c3fb2` added ordering
around the Omega fabrics in `VX_local_mem.sv`:

- Request admission tracks outstanding stores in a shared CAM, blocking reads
  to the same word until a store commits. Presented same-cycle stores also
  block matching reads.
- Response admission tracks accepted read-bank order per requester. Once a
  response enters the Omega network, `rsp_order_issued` blocks that requester's
  next response until the previous response completes its external handshake.
  This prevents pipelining multiple responses to that requester through Omega.

These guards stay enabled by default. Fabric selection and ordering policy
are now independent:

| Macro | Meaning when defined |
| --- | --- |
| `LMEM_REQ_OMEGA_ENABLE` | Select request Omega instead of stream xbar |
| `LMEM_RSP_OMEGA_ENABLE` | Select response Omega instead of stream xbar |
| `LMEM_REQ_OMEGA_ORDER_DISABLE` | Bypass the request store CAM/RAW guard |
| `LMEM_RSP_OMEGA_ORDER_DISABLE` | Bypass the requester response-order guard |

All four are presence macros: `=0` still counts as defined. The disable
macros have no effect when their corresponding fabric is stream xbar.
`LMEM_*_OMEGA_ORDER_ENABLED` are derived internal macros, not user controls.

To use the historical unguarded Omega transport:

```sh
CONFIGS+=" -DLMEM_REQ_OMEGA_ENABLE -DLMEM_RSP_OMEGA_ENABLE"
CONFIGS+=" -DLMEM_REQ_OMEGA_ORDER_DISABLE -DLMEM_RSP_OMEGA_ORDER_DISABLE"
```

To keep current ordering, omit both disable macros. Each can also be used
individually for diagnosis. ACC storage and SLR controls are independent.
This restores the transport behavior, not every historical GEMM/LMEM change.

Bypass mode does not promise cross-requester RAW ordering or requester-local
response ordering. The testbench therefore checks those guarantees only in
modes that provide them; routing, data, tags, partial writes, backpressure,
and performance-counter checks remain active for every mode.

Verification uses configured `build_omega_ordering_macros`, system GCC/G++,
and `tools/verify_rtl.py`. `verify_matrix.py` covers all nine distinct
fabric/ordering combinations. Sixteen combinations of selector/disable
presence were additionally preprocessed to check instantiated fabrics and
guard state. `run_blackbox.py` archives the baseline plus the two changed RTL
files into an isolated source/build and uses the previous C3 host/kernel
binaries for `xrt-vcs-sim --perf 3`, M=K=N=256, q32, t0, d0, r1, internal ACC,
SLR OFF. Unit tests must pass before that blackbox runs.

Results are in `unit_results.json`, `blackbox/summary.json`, and `results.md`.
No files under `configs/` were changed, and no commits were created as part of adding these controls.
