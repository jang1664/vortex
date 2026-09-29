# FPGA memory selection

The memory selectors from feat/gemv commit `72045e5a2` are adapted to this
branch's existing RTL. Each numeric macro independently selects the requested
RAM style through the existing `VX_sp_ram.USE_URAM` parameter.

| Macro | Default | Applies to |
|---|---:|---|
| `LMEM_USE_URAM` | 0 | Local-memory SRAM banks |
| `GEMM_ACC_USE_URAM` | 0 | Internal GEMM accumulator SRAM banks, improve or naive ACC enabled |
| `TMEM_USE_URAM` | 0 | Tensor-memory banks; also overridable through each bank's `USE_URAM` parameter |

Use `0` for BRAM and `1` for URAM. These are numeric values, unlike the
presence-based `GEMM_SLR_PIPELINE` switch. Sizes, byte enables, registered
read latency and read-first semantics are unchanged. The accumulator selector
has no effect when the selected backend does not instantiate internal ACC RAM.

All three memories default to BRAM. To request URAM, source the desired
configuration before adding overrides:

```bash
# Request URAM for all three memories.
export CONFIGS="$CONFIGS -DLMEM_USE_URAM=1 -DGEMM_ACC_USE_URAM=1 -DTMEM_USE_URAM=1"
```

Each selector can also be overridden independently. The all-BRAM defaults
follow the user's request; feat/gemv defaults LMEM and ACC to URAM instead.

SLR transport and placement options are independent of these selectors.
`VX_sp_ram` retains its existing platform, size and compatibility rules;
these values express the inference intent, not proof of physical resource
mapping. Behavioral simulation alone cannot verify final RAM primitives.
The compiled-SRAM ASIC path is unchanged.
