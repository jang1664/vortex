# HW Block Design — Connection & Dimension Rules

## Port Dimension Model

Each port's wire count is determined by three levels of hierarchy, ordered from outermost to innermost (matching Verilog convention):

```
[batch_instance_dims...][port_array_dims...][bitwidth]
```

| Level | Source | Example | Description |
|-------|--------|---------|-------------|
| Batch instance dims | Instance `array` field | `u_core[4][2]` → `[4, 2]` | Number of replicated instances |
| Port array dims | Port `array` field | `data[3]` → `[3]` | Array of ports within one instance |
| Bitwidth | Port property `width` | `width: 32` → `[32]` | Bit width of a single wire |

**Total wires** = product of all dimensions.

### Example

```
Instance: u_core, array: [4]
Port: data, array: [3], width: 8

Dimension: [4][3][8]
            ^   ^   ^
          batch port bit

Total: 4 × 3 × 8 = 96 wires
Verilog: wire [7:0] u_core_data [0:3][0:2]
```

## Connection Shape

In the simplified JSON, each connection endpoint has a **shape** field that shows `[batch_dims...][port_array_dims...]` — **bitwidth is excluded** because it is always passed through as-is.

```json
{
  "from": ["u_core.data"],
  "to": ["u_mem.addr"],
  "from_shape": [4, 3],
  "to_shape": [12],
  "mapping": "1:1"
}
```

This means: 4×3 = 12 elements on the from side, 12 elements on the to side, connected 1:1 (after flattening).

## Mapping Presets

| Mapping | Description | Shape constraint |
|---------|-------------|-----------------|
| `1:1` | Flatten both sides, connect index-to-index | `product(from_shape) == product(to_shape)` |
| `broadcast` | Single source replicated to all targets | `product(from_shape) == 1` or `from_shape` divides `to_shape` |
| `reduction` | Multiple sources merged into one target | `product(to_shape) == 1` or `to_shape` divides `from_shape` |
| `crossbar` | Any-to-any connectivity, arbitration required | No shape constraint |
| `interleave` | Round-robin or stride-based mapping | `product(from_shape) == product(to_shape)` |
| `custom` | Explicit `dim_map` provided | See below |

### How to interpret each preset

**`1:1`** — Default. Both sides are flattened to 1D in row-major order, then connected element-by-element.
```
from_shape: [4, 3] → flat indices 0..11
to_shape: [12]     → flat indices 0..11
Connection: from[i] ↔ to[i]
```

**`broadcast`** — The smaller side is replicated to match the larger side.
```
from_shape: [1]    → 1 element
to_shape: [4]      → 4 elements
Connection: from[0] → to[0], to[1], to[2], to[3]
```

**`reduction`** — Multiple sources feed into fewer targets (e.g., mux, arbiter).
```
from_shape: [4]    → 4 elements
to_shape: [1]      → 1 element
Connection: from[0..3] → to[0] (with arbitration/selection)
```

**`crossbar`** — Full connectivity matrix. Any from-element can talk to any to-element. Requires arbitration logic (described in connection `description` or `properties`).

**`interleave`** — Elements are mapped with a stride pattern.
```
from_shape: [4]     → indices 0,1,2,3
to_shape: [2, 2]    → indices [0][0], [0][1], [1][0], [1][1]
stride=2: from[0]→to[0][0], from[1]→to[1][0], from[2]→to[0][1], from[3]→to[1][1]
```

## Custom Map Expression

When `mapping` is `custom`, the `map_expr` field uses Verilog-style index expressions to describe exactly how indices are mapped between ports.

### Syntax

```
<lhs>[<index_expr>] -> <rhs>[<index_expr>] for(<var>,<start>,<end>) [for(<var>,<start>,<end>)...]
```

- `<lhs>`, `<rhs>`: port names (or `in`/`out` as shorthand)
- `<index_expr>`: integer arithmetic using loop variables, constants, parameters (`+`, `-`, `*`, `/`, `%`)
- `for(i,0,N)`: loop variable `i` from 0 to N-1 (N exclusive)
- Multiple `for` clauses = nested loops (left = outer)
- Parameter variables (e.g., `NUM_CORES`) can be used in expressions and loop bounds

### 1D Examples

```
// Simple 1:1
in[i] -> out[i] for(i,0,8)

// Stride-2 interleave
in[i] -> out[2*i] for(i,0,4)

// Broadcast: 1 source to N targets
in[0] -> out[i] for(i,0,N)

// Reduction: N sources to 1 target
in[i] -> out[0] for(i,0,N)

// Partial select (slice)
in[i] -> out[i-2] for(i,2,6)

// Two ranges to interleaved output
in[i] -> out[2*i] for(i,0,4)
in[i] -> out[2*i+1] for(i,4,8)
```

### 2D Examples

```
// 2D 1:1
in[i][j] -> out[i][j] for(i,0,4) for(j,0,8)

// Transpose
in[i][j] -> out[j][i] for(i,0,4) for(j,0,2)

// Flatten 2D to 1D: batch[4] x port[8] -> flat[32]
in[i][j] -> out[i*8+j] for(i,0,4) for(j,0,8)

// Unflatten 1D to 2D
in[i*8+j] -> out[i][j] for(i,0,4) for(j,0,8)

// Row broadcast
in[0][j] -> out[i][j] for(i,0,4) for(j,0,8)

// Parameterized
in[i][j] -> out[i*M+j] for(i,0,N) for(j,0,M)
```

### JSON Format

```json
{
  "mapping": "custom",
  "map_expr": "in[i][j] -> out[j][i] for(i,0,4) for(j,0,2)"
}
```

Multi-line expressions are allowed for complex patterns:
```json
{
  "mapping": "custom",
  "map_expr": "in[i] -> out[2*i] for(i,0,4)\nin[i] -> out[2*i+1] for(i,4,8)"
}
```

## M:N Connections

When a connection has multiple `from` and/or `to` endpoints, the shape is computed per-endpoint:

```json
{
  "from": ["u_core_a.out", "u_core_b.out"],
  "to": ["u_mux.in"],
  "from_shape": [[4], [4]],
  "to_shape": [8],
  "mapping": "1:1",
  "description": "Two 4-wide ports merged into one 8-wide port"
}
```

When `from_shape` or `to_shape` is a list of lists, each sub-list corresponds to one endpoint. The mapping applies to the **concatenated** flat indices of all endpoints on each side.

## Floating Endpoints

Connections can have open endpoints (floating points) that represent hierarchical boundaries:

```json
{
  "from": ["u_core.data_out"],
  "to": ["to upper level"],
  "from_shape": [4],
  "to_shape": [1],
  "mapping": "1:1"
}
```

A string endpoint (not `inst.port` format) indicates a floating point with that label. These represent wires that leave the current sheet's scope — typically connected at a higher level of hierarchy.

## Direction

| Value | Arrow | Meaning |
|-------|-------|---------|
| `forward` | → | Data flows from → to (default) |
| `reverse` | ← | Data flows to → from |
| `both` | ↔ | Bidirectional |
| `none` | — | No direction (structural connection) |
