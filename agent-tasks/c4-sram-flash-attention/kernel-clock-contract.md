# Kernel-00 clock contract: default 300 MHz, requested 100 MHz

Local generated files and installed XRT source support a concrete reconciliation mechanism: **implementation is timed at the requested clock, while XRT dynamically reprograms the platform Clock Wizard when loading the xclbin**. The 300 MHz MMCM default does not itself prove that the running accelerator uses 300 MHz. Conversely, this mechanism is not evidence that the unfinished R5 image has actually loaded or achieved 100 MHz.

## Proven local mechanism

1. `hw/syn/xilinx/xrt/Makefile:327` passes the configured frequency to `gen_vitis_ini.py:37–41`, which emits Alveo `kernel_frequency=0:100` (the variable name CLOCK_FREQ_HZ is historical; this option is MHz). R5's actual `xrt_backup/vitis.gen.ini:1` contains that setting. Its generated `output/_user_impl_clk.xdc:3` says “Kernel clock overridden by user” and creates `clk_kernel_00_unbuffered_net` at the kernel-00 MMCM output using multiply 12/divide 12. The completed methodology report confirms the resulting 10 ns constraint, while the unchanged default CMB parameters imply 3.333 ns.
2. R5 generated `prj.gen/my_rm/bd/ulp/synth/ulp.v:4430–4431` connects `vortex_afu_1.ap_clk` to `ulp_ucs_aclk_kernel_00`. The UCS partition metadata exposes `ep_aclk_kernel_00` as a Clock Wizard at offset `0x01003000` and its frequency counter at `0x01009000`. These are platform-relative resources, not addresses to poke manually.
3. `runtime/xrt/vortex.cpp:328–359` loads the selected xclbin through XRT and obtains/uses its UUID. In installed `/usr/src/xrt-2.19.194/driver/xocl/subdev/icap.c:2125–2142,2378–2423`, the privileged download path caches CLOCK_FREQ_TOPOLOGY and calls frequency scaling before bitstream download. `icap.c:1397–1417` then **forces rescaling after partial reconfiguration**, explicitly because PR can overwrite MMCM settings while Clock Wizard CONFIG registers misleadingly retain the previous values. Failure propagates through this path, but missing clock subdevice has an allowed `-ENODEV` case; a successful load alone is not a measured-clock certificate.
4. `clock_wiz.c:934–1011` sorts topology entries by **type**, not serialized order: CT_DATA becomes target slot 0, CT_KERNEL slot 1. `clock_wiz.c:130–145,1132–1134` and `xocl_fdt.h:70,135` map slot 0 to `RESNAME_CLKWIZKERNEL1` / `ep_aclk_kernel_00`. Thus the accelerator's physical kernel-00 clock is **DATA_CLK**, despite the separate topology entry named KERNEL_CLK. That second entry corresponds to kernel-01; do not mistakenly use its 500 MHz for accelerator cycle conversion.
5. For UltraScale, `clock_wiz.c:622–704` writes the requested table's Clock Wizard CONFIG0/CONFIG2, triggers reconfiguration via CONFIG23 (`0x7`, then `0x2`), and waits for MMCM/PLL lock; failure restores original configuration and returns timeout. The exact 100 MHz table entry is at line 209. The installed source therefore supplies the dynamic programming mechanism that static post-init methodology cannot model.

Evidence paths/hashes and relevant line excerpts are in [logs/kernel_clock_contract/proof.json](logs/kernel_clock_contract/proof.json). These are installed source semantics; the actual loaded management driver/version and selected device still require binding during hardware validation. No driver, FPGA, synthesis, clock-setting or device tool was invoked here.

## Actual old-image evidence and bounded inference

The preserved rev8 xclbin UUID is `be2920d8-076a-34d3-0762-9c529c8d0dba`. Reading its CLOCK_FREQ_TOPOLOGY **from the file bytes** gives HBM SYSTEM=450 MHz, KERNEL=500 MHz and DATA=100 MHz. Its existing `.xclbin.info:54–66` records kernel-00 **SCALABLE**, default 300 / requested 100 / achieved 100 MHz; kernel-01 is 500 MHz. This is packaged metadata, not a current board measurement. See [old_xclbin_topology.json](logs/kernel_clock_contract/old_xclbin_topology.json).

The initial installed Python xclbin binding proved stale (`m_mode` uint32 rather than current header uint16), so that extraction was rejected and retained as `rejected_stale_binding.json`. The accepted read used the installed C header layout, verified header size/section bounds/file length, matched the known UUID and extracted the actual clock section. No runtime library or hardware access occurred.

**Inference:** the static TIMING-1 discrepancy is consistent with a scalable platform retaining its 300 MHz default primitive configuration while Vitis times a 100 MHz requested operating point that XRT will program. This is well supported by the generated constraint, resource mapping and driver code; it is not a waiver of TIMING-1 or proof that R5's eventual packaged topology/loaded device is correct. Old numerical PASS is not used as clock evidence.

## Exact remaining R5 checks

- Bind final R5 routed timing/clock reports, `_user_impl_clk.xdc`, build stamp, xclbin hash/UUID, embedded CLOCK_FREQ_TOPOLOGY and packaged system-clock metadata. Confirm kernel-00 requested/achieved 100 MHz and CT_DATA=100; preserve the actual final achieved value if implementation changes it. Check ap_clk's final clock association, not just the generated pre-opt RTL connection. Keep the platform TIMING-1 disposition explicit alongside the other methodology findings.
- At the separately authorized hardware matrix, record selected image/UUID/BDF/platform and running management-driver/XRT version. After loading that exact image, record its **measured kernel-00 frequency counter**, plus configured frequency, clock lock/scaling errors and any throttling state. Do not replace measurement with requested frequency or stale cached Clock Wizard registers. Bind these observations to the same allocation/device and repeat the relevant bookend after the matrix.
- The installed driver's `icap.c:3397–3439` read-only `clock_freqs` interface uses the frequency counter when a bitstream UUID is present; without one it returns configured frequency. Its mismatch warning compares requested and measured clocks. Therefore preserve UUID presence and counter provenance when using this interface or an XRT report backed by it. `set_and_verify_freqs` can also check the counter (`clock_wiz.c:857–899`), but the topology-load call passes verify=0 (`icap.c:1393–1394`); do not assume a load call already performed that measured-frequency check.
- Use the validated achieved/loaded kernel-00 period for cycle conversion, retain host wall-time separately, and reject an unexplained loaded frequency/UUID mismatch. This is a targeted clock-contract check; no platform-wide constraint remediation or clock modification is proposed.

## Unexecuted post-load counter query

Prefer the management PF's direct `clock_counter_freqs` attribute over the user PF ICAP cache. `clock_counter.c:82–136,238–255` starts a fresh hardware counter measurement, waits for completion, then returns each clock rounded from kHz to **integer MHz**, in DATA/kernel-00, KERNEL/kernel-01, SYSTEM order. Its slot-0 mapping is at `clock_counter.c:204–210`. Missing counter/measurement failure returns zero and must fail the gate. Reading this sysfs attribute starts only a measurement; it does not program a clock frequency. User-PF `icap/clock_freqs` may instead use cached management-peer counter data (`icap.c:562–605`), so do not describe that path as necessarily fresh.

Run the following only **after the actual new UUID is loaded**, inside the same reserved hardware allocation. Supply the selected user PF BDF, the explicitly identified matching management PF BDF, and the new xclbin UUID; do not substitute an arbitrary board or assume function numbers. The query fails on missing/ambiguous interfaces or UUID mismatch and records full paths. It is deliberately unexecuted in this investigation.

```bash
timeout 30s /usr/bin/python3 - USER_BDF MANAGEMENT_BDF NEW_XCLBIN_UUID <<'PY'
import json, pathlib, sys, time, uuid
user, mgmt = [pathlib.Path('/sys/bus/pci/devices') / b for b in sys.argv[1:3]]
expected = str(uuid.UUID(sys.argv[3]))
assert user.name.rsplit('.', 1)[0] == mgmt.name.rsplit('.', 1)[0]
assert user != mgmt and (user/'driver').resolve().name == 'xocl'
assert (mgmt/'driver').resolve().name == 'xclmgmt'
counter = list(mgmt.glob('*/clock_counter_freqs'))
assert len(counter) == 1, f'missing/ambiguous direct management counter: {counter}'
def loaded():
    return [str(uuid.UUID(x)) for x in (user/'xclbinuuid').read_text().split()]
assert loaded() == [expected], 'unexpected loaded UUID/slot count'
samples = []
for _ in range(3):
    samples.append([int(x) for x in counter[0].read_text().split()])
    time.sleep(1)
assert loaded() == [expected], 'loaded image changed during measurement'
versions = {}
for label, device in [('user', user), ('management', mgmt)]:
    p = device/'driver/module/version'
    versions[label] = p.read_text().strip() if p.exists() else 'unavailable: establish separately'
print(json.dumps({'user_bdf':user.name, 'management_bdf':mgmt.name,
    'uuid':expected, 'counter_path':str(counter[0]), 'units':'rounded MHz',
    'samples':samples, 'driver_versions':versions}, indent=2), flush=True)
assert all(len(s) >= 2 and s[0] > 0 and abs(s[0]-100) <= 1 for s in samples), 'kernel-00 counter mismatch'
PY
```

For the requested 100 MHz image, **99–101 MHz on all three rounded readings** is a proposed measurement gate, allowing integer-MHz rounding plus a small margin; it is not a claim of calibrated instrument accuracy. The driver's own optional verification threshold is broader (5%, `clock_wiz.c:888–895`) and is not silently adopted here. A zero, outlier, unexpected image clock or throttled/gated result needs diagnosis and retained raw readings, not a wider automatic tolerance. If the management attribute is unavailable/permission-denied, report measured frequency unproven and obtain the equivalent supported counter report within the allocation; `.info` requested/achieved values remain metadata. Running driver/version linkage and throttling interpretation are still separate receipt fields.
