# `core/VX_agen_unit.sv` — General Affine Address Generator

`VX_agen_unit` is an optional execution unit enabled by
`EXT_ADDR_GEN_ENABLE`. With the feature disabled, the module body, decoder
cases, execute instance, and extra issue/commit slot compile out.

## ISA and dispatch

The unit accepts R-type CUSTOM0 instructions. Funct7 `0x04`, `0x05`, and
`0x06` select `LD0`, `LD1`, and `ST`, respectively. Funct3 selects:

| Funct3 | Operation | Behavior |
| ---: | --- | --- |
| 0 | `CFG_BASE` | Write the shadow 64-bit byte base from `rs1`. |
| 1-3 | `CFG_DIM0..2` | Write a shadow signed byte stride from `rs1` and unsigned 32-bit bound from `rs2[31:0]`. |
| 4 | `START` | Publish the shadow descriptor, clear loop state, and flush the queue. |
| 5 | `RESET` | Stop active generation, clear loop state, and flush the queue while preserving the shadow descriptor. |
| 6 | `POP` | Block until all selected lanes have data, then return one address per lane. |
| 7 | reserved | No AGEN decode. |

The decoder carries funct3 in `op_type` and the stream ID in
`op_args.agen.stream`. Configuration, start, and reset produce normal commit
events with `wb=0`. POP preserves the decoded integer destination and commits
with `wb=1`.

## Descriptor and lifecycle

Every architectural thread owns independent shadow and active descriptors for
all three streams. A descriptor contains a 64-bit byte base and three pairs of
signed 64-bit byte stride and unsigned 32-bit bound. Configuration changes only
shadow state, including while an older active descriptor is running.

`START` atomically copies shadow to active state. It clears the three counters
and signed offsets, flushes queued addresses, and enters `RUNNING` unless any
bound is zero. `RESET` returns the active stream to `IDLE` without modifying
shadow configuration. After the final address is enqueued the stream enters
`DRAINING`; popping the last queued address returns it to `IDLE`.

The current address is computed modulo 2^64 as:

```text
base + offset[0] + offset[1] + offset[2]
```

Dimension zero is innermost. Enqueue advances its counter and offset; reaching
the bound resets both and carries into the next dimension. No multiplier or
layout-specific constant is used in address generation.

## Queues, producers, and backpressure

Each stream has depth-four per-thread queues and an independent flattened
warp/slice round-robin producer cursor. The three producers can each advance
one SIMD slice in the same cycle. Eligible lanes in a selected slice enqueue
and advance independently. Queue payloads remain shallow RTL arrays so FPGA
synthesis can choose registers or distributed memory from the target and
access pattern. Pointers, occupancy, and descriptor state remain registers.

A POP fires atomically only when every lane in its SIMD mask has nonzero
occupancy. Inactive lanes neither block nor consume. Enqueue-only and pop-only
change occupancy by one, simultaneous enqueue/pop preserves it, and a full
queue can replace its popped head in the same cycle. Commit backpressure is
held in the unit's per-issue response register.
