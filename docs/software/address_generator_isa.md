# Descriptor Address-Generator ISA

This document is the architectural source of truth for the optional Vortex
descriptor address generator. RTL, simx, kernel intrinsics, and verification
must implement the behavior below. `EXT_ADDR_GEN_ENABLE` removes the extension
when it is not selected.

## Streams and encoding

The extension uses guarded raw R-type `CUSTOM0` instructions. The `funct7`
field selects one of three independent per-thread streams.

| `funct7` | Stream |
| ---: | --- |
| `0x04` | `LD0` |
| `0x05` | `LD1` |
| `0x06` | `ST` |

The `funct3` field selects the operation.

| `funct3` | Operation | Operands and result |
| ---: | --- | --- |
| 0 | `CFG_BASE` | `rs1` is the 64-bit byte base. |
| 1 | `CFG_DIM0` | `rs1` is the signed byte stride; `rs2[31:0]` is the bound. |
| 2 | `CFG_DIM1` | `rs1` is the signed byte stride; `rs2[31:0]` is the bound. |
| 3 | `CFG_DIM2` | `rs1` is the signed byte stride; `rs2[31:0]` is the bound. |
| 4 | `START` | Publish the shadow descriptor and flush old queue state. |
| 5 | `RESET` | Stop and flush the selected stream. |
| 6 | `POP` | Return one blocking 64-bit byte address in `rd`. |
| 7 | Reserved | No architectural behavior. |

Configuration, `START`, and `RESET` retire without integer writeback. `POP`
uses normal integer writeback and is accepted only when every active lane in
the issued SIMD mask has a queued address. An empty exhausted stream therefore
blocks indefinitely; simulation may diagnose the software protocol error but
must not change this architectural behavior.

## Descriptor and arithmetic

Every architectural thread has an independent shadow and active descriptor in
each stream. A descriptor contains:

```text
base:       unsigned 64-bit byte address
stride[3]: signed 64-bit byte strides
bound[3]:  unsigned 32-bit iteration counts
```

The generated sequence is the lexicographic traversal

```text
address = base
        + index[0] * stride[0]
        + index[1] * stride[1]
        + index[2] * stride[2]
```

where dimension zero is innermost and `0 <= index[d] < bound[d]`.
All additions wrap modulo 2^64. Hardware must use running offsets and carry,
not multiplication, on the per-address path. It must not infer lane IDs,
element sizes, layout widths, or software loop steps.

## Reference iterator

The following iterator defines both the sequence and exhaustion behavior.
Unsigned 64-bit addition implements the required modulo arithmetic, including
negative strides represented in two's complement.

```text
start(desc):
    active = desc
    index  = {0, 0, 0}
    offset = {0, 0, 0}
    valid  = (bound[0] != 0 && bound[1] != 0 && bound[2] != 0)

next():
    require valid
    result = base + offset[0] + offset[1] + offset[2]

    if index[0] + 1 < bound[0]:
        index[0] += 1
        offset[0] += stride[0]
    else:
        index[0] = 0
        offset[0] = 0
        if index[1] + 1 < bound[1]:
            index[1] += 1
            offset[1] += stride[1]
        else:
            index[1] = 0
            offset[1] = 0
            if index[2] + 1 < bound[2]:
                index[2] += 1
                offset[2] += stride[2]
            else:
                index[2] = 0
                offset[2] = 0
                valid = false

    return result
```

The sequence length is `bound[0] * bound[1] * bound[2]` when all bounds are
nonzero and is zero otherwise. Software must avoid overflowing its own count
calculation; the hardware relies only on nested carry and does not form this
product.

## Lifecycle and queue semantics

`CFG_BASE` and `CFG_DIM*` are the only operations that update shadow state.
`START` atomically copies
the complete shadow descriptor to active state, clears counters and offsets,
flushes the queue, and starts generation. A zero bound makes the descriptor
immediately exhausted. Configuration during generation cannot perturb the
active sequence. `RESET` is always accepted and returns the selected lanes to
idle while flushing their queues; it preserves the shadow descriptor so a
later `START` can restart the last configured sequence.

For a queue update in one cycle:

- enqueue only increments occupancy;
- pop only decrements occupancy;
- enqueue plus pop preserves occupancy and performs both operations;
- a full queue may enqueue when the same entry set also pops that cycle;
- an empty queue prevents acceptance of a selected-lane `POP`.

The three stream engines have independent descriptors, queues, and producer
progress. A blocked `POP` remains confined to the optional `EX_AGEN` issue
path and cannot occupy the ALU, LSU, or SFU path.

## Software contract

Stream and dimension selectors passed to generic intrinsics must be compile-
time constants so each call emits one statically known instruction encoding.
`vx_addrgen_pop_ld0`, `vx_addrgen_pop_ld1`, and `vx_addrgen_pop_st` provide
fixed POP encodings. Returned byte addresses are consumed by ordinary LSU
load/store instructions; the generator never performs memory access.
