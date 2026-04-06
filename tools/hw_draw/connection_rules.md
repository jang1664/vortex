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

## Custom Dim Map

When `mapping` is `custom`, the `dim_map` field provides explicit dimension mapping:

```json
{
  "mapping": "custom",
  "dim_map": {
    "from_shape": [4, 2],
    "to_shape": [2, 4],
    "map": "transpose"
  }
}
```

### Standard `map` values

| Map | Description |
|-----|-------------|
| `reshape` | Flatten and reshape: `[4, 2]` → `[2, 4]`, same total, different grouping |
| `transpose` | Swap dimension order: `[i][j]` → `[j][i]` |
| `stride(N)` | Interleave with stride N |
| `slice(start:end)` | Partial connection, only a range of indices |
| Free-form text | Any description for complex patterns (e.g., `"even indices only"`) |

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
