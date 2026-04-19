# HMSS Usage Constraints

This note summarizes the constraints for using the Xilinx/AMD HBM Memory
Subsystem (HMSS) from the Vortex XRT flow. It is intended to prevent invalid HBM
connectivity settings when packaging `vortex_afu` and linking with `v++`.

## Terminology

| Term | Meaning |
|------|---------|
| HBM PC | HBM pseudo-channel. U55C exposes 32 PCs, each 512 MB. |
| HMSS | HBM Memory Subsystem inserted/customized by the Vitis link flow. |
| `sp` | Vitis system-port connectivity directive: `sp=<cu>.<arg-or-interface>:<memory>`. |
| AXI master port | A top-level RTL kernel memory interface, for example `m_axi_mem_0`. |
| Kernel argument/register | The `MEM_i` pointer register in `component.xml`, associated with one AXI master port. |

## HMSS Connectivity Rules

### 1. Treat HBM PCs as contiguous address ranges

HMSS routes AXI transactions by address. For U55C, the HBM address space is
contiguous:

```text
HBM[0]  -> [0x000000000, 0x020000000)  512 MB
HBM[1]  -> [0x020000000, 0x040000000)  512 MB
...
HBM[31] -> [0x3e0000000, 0x400000000)  512 MB
```

Any Vortex address remapping or bank-interleaving logic must eventually produce
addresses that are valid in this contiguous HMSS address map.

### 2. One `sp` line maps one kernel argument/interface to one memory resource

For RTL kernels, Vitis resolves the `<arg-or-interface>` name from the packaged
kernel XML. In this flow, `package_kernel.tcl` creates one pointer register per
top-level AXI master port:

```text
MEM_0 -> m_axi_mem_0
MEM_1 -> m_axi_mem_1
...
MEM_7 -> m_axi_mem_7
```

Therefore, `sp=vortex_afu_1.m_axi_mem_0:HBM[0]` maps the `m_axi_mem_0`
interface, through its associated `MEM_0` metadata, to `HBM[0]`.

### 3. Multiple HBM PCs on one AXI interface must be a contiguous range

Use a single range expression when one AXI interface needs access to multiple
HBM PCs:

```ini
[connectivity]
sp=vortex_afu_1.m_axi_mem_0:HBM[0:3]
```

Do not express non-contiguous groups by repeating `sp` entries for the same AXI
interface:

```ini
# Invalid for this flow: Vitis does not create a 4-PC union for m_axi_mem_0.
sp=vortex_afu_1.m_axi_mem_0:HBM[0]
sp=vortex_afu_1.m_axi_mem_0:HBM[8]
sp=vortex_afu_1.m_axi_mem_0:HBM[16]
sp=vortex_afu_1.m_axi_mem_0:HBM[24]
```

In observed U55C builds, all repeated `sp` lines were accepted in
`vitis.gen.ini`, but the generated `cfgen_cfgraph.xml` kept only one `sptag` per
`MEM_i`. The final `address_map.xml` connected `m_axi_mem_0..7` only to
`HBM_MEM00..07`, even though the runtime and RTL expected 32 banks.

### 4. The RTL port map, `sp` map, and runtime bank model must agree

The Vortex XRT stack has three separate concepts that must not be conflated:

| Concept | Current U55C value | Used by |
|---------|--------------------|---------|
| Physical HBM PCs | 32 | `PLATFORM_MEMORY_NUM_BANKS`, runtime bank count, address remap |
| Top-level AXI ports | 8 by default | `NUM_DMA_CHANNELS`, `m_axi_mem_0..7`, `MEM_0..7` |
| HMSS port connectivity | Defined by `sp` | Vitis link, `cfgen_cfgraph.xml`, `address_map.xml` |

If runtime allocation can select bank IDs `0..31`, but the linked kernel master
ports can reach only `HBM[0:7]`, accesses to addresses in `HBM[8:31]` are not
valid from the kernel side and can hang simulation or hardware.

### 5. Full-range mapping is the simplest functional configuration

If each Vortex AXI port can legally emit addresses anywhere in the full HBM
aperture, map each port to the full HBM range:

```ini
[connectivity]
sp=vortex_afu_1.m_axi_mem_0:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_1:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_2:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_3:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_4:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_5:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_6:HBM[0:31]
sp=vortex_afu_1.m_axi_mem_7:HBM[0:31]
```

This is not necessarily optimal for timing or bandwidth, but it matches a design
where any AXI port can generate an address in any HBM PC.

### 6. Partitioned mapping requires matching RTL address routing

If each AXI port owns a subset of HBM PCs, use contiguous ranges and make the RTL
route addresses consistently:

```ini
[connectivity]
sp=vortex_afu_1.m_axi_mem_0:HBM[0:3]
sp=vortex_afu_1.m_axi_mem_1:HBM[4:7]
sp=vortex_afu_1.m_axi_mem_2:HBM[8:11]
sp=vortex_afu_1.m_axi_mem_3:HBM[12:15]
sp=vortex_afu_1.m_axi_mem_4:HBM[16:19]
sp=vortex_afu_1.m_axi_mem_5:HBM[20:23]
sp=vortex_afu_1.m_axi_mem_6:HBM[24:27]
sp=vortex_afu_1.m_axi_mem_7:HBM[28:31]
```

This only works if the RTL demux sends addresses for `HBM[0:3]` to
`m_axi_mem_0`, addresses for `HBM[4:7]` to `m_axi_mem_1`, and so on. A modulo
mapping such as `m_axi_mem_0 -> HBM[0,8,16,24]` is not a valid contiguous range
mapping and should not be encoded as repeated `sp` lines.

## Vortex-Specific Checks

After every HBM connectivity change, inspect the generated Vitis link artifacts:

```bash
rg -n "sptag=|MEM_|m_axi_mem_" <build>/_x/link/sys_link/cfgraph/cfgen_cfgraph.xml
rg -n "componentRef=\"vortex_afu_1\".*m_axi_mem_|HBM_MEM" <build>/_x/link/int/address_map.xml
```

Expected results:

| File | What to verify |
|------|----------------|
| `vitis.gen.ini` | The intended `sp=` lines were emitted. |
| `cfgen_cfgraph.xml` | Each `MEM_i` has the expected HBM `sptag` or range. |
| `address_map.xml` | Each `m_axi_mem_i` has address ranges covering the HBM PCs it can access. |
| `component.xml` | `MEM_i` registers are associated with the intended `m_axi_mem_i` interfaces. |

Do not rely on `vitis.gen.ini` alone. The important result is the linked
address map produced by Vitis.

## Current Failure Pattern

The invalid pattern that caused the U55C HBM issue was:

```ini
sp=vortex_afu_1.m_axi_mem_0:HBM[0]
sp=vortex_afu_1.m_axi_mem_0:HBM[8]
sp=vortex_afu_1.m_axi_mem_0:HBM[16]
sp=vortex_afu_1.m_axi_mem_0:HBM[24]
...
sp=vortex_afu_1.m_axi_mem_7:HBM[7]
sp=vortex_afu_1.m_axi_mem_7:HBM[15]
sp=vortex_afu_1.m_axi_mem_7:HBM[23]
sp=vortex_afu_1.m_axi_mem_7:HBM[31]
```

The intent was to distribute 32 HBM PCs over 8 AXI ports by modulo port number.
However, the generated Vitis artifacts showed only:

```text
MEM_0 -> HBM[0]
MEM_1 -> HBM[1]
...
MEM_7 -> HBM[7]
```

This left `HBM[8:31]` reachable by host/XDMA allocation but not by the Vortex
kernel master ports. That mismatch is sufficient to explain HBM access hangs.

## References

- AMD UG1393, "HBM Configuration and Use":
  <https://docs.amd.com/r/2021.2-English/ug1393-vitis-application-acceleration/HBM-Configuration-and-Use>
- AMD UG1700, "Mapping Kernel Ports to Memory":
  <https://docs.amd.com/r/en-US/ug1700-vitis-accelerated-data-center/Mapping-Kernel-Ports-to-Memory>
- AMD Vitis Tutorials, "HBM Overview":
  <https://docs.amd.com/r/en-US/Vitis-Tutorials-Vitis-Hardware-Acceleration/HBM-Overview>
- AMD PG276, "AXI High Bandwidth Memory Controller Features":
  <https://docs.amd.com/r/en-US/pg276-axi-hbm/Features>
