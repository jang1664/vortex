# Candidate clock reconciliation

Observed 2026-09-08 22:39 KST. The candidate Vortex operating configuration is
kernel100/HBMAXI450 MHz, consistent between archived connectivity, linked
xclbin metadata and post-workload board reports. The 300 MHz HWH annotation
is the platform specification/default, not the requested or achieved kernel
frequency. No simulation frequency was changed to conceal a mismatch.

Evidence chain:

1. Archived `ulp.hwh:15616` connects `vortex_afu_1.ap_clk` to
   `ulp_ucs.aclk_kernel_00` / `ulp_ucs_aclk_kernel_00`. Its `CLKFREQUENCY`
   attribute is 300000000.
2. SYSTEM_METADATA extracted directly from the selected xclbin assigns
   the Vortex kernel `clock_id: 0`. The clock list maps ID 0 to
   `ulp_ucs_aclk_kernel_00`, `spec_frequency: 300`,
   `requested_frequency: 100`, `achieved_frequency: 100`. ID 1 is the
   separate kernel_01 clock with requested/achieved 500 MHz.
   The nested compute-unit port description also retains requested300 and
   achieved0. This is not an achieved operating clock: its parent clock ID
   resolves to the final system clock record above. Preserve both records.
3. The same xclbin's CLOCK_FREQ_TOPOLOGY reports DATA_CLK100,
   KERNEL_CLK500 and hbm_aclk450. Topology list indices and SYSTEM_METADATA
   clock IDs are different namespaces; do not equate their numeric indices.
4. Post-run XRT reports for the same candidate UUID consistently report
   DATA_CLK100, KERNEL_CLK500 and hbm_aclk450. Thus the linked operating
   clock profile, observed runtime profile and actual Vortex net connection
   agree. The runtime label KERNEL_CLK does not mean Vortex ap_clk here.

Extraction used `xclbinutil --dump-section CLOCK_FREQ_TOPOLOGY:JSON:...` and
`--dump-section SYSTEM_METADATA:RAW:...` on the existing candidate xclbin.
SYSTEM_METADATA contains JSON but the tool rejects the JSON output-type
selector for that section; the first attempt partially succeeded (topology),
then the supported RAW extraction succeeded. No xclbin was modified.

Files and hashes:

- `build_hbm_reference/reference_clock_topology.json`
  SHA-256 `6f8bc582c0e0c2ae302bd05086132c883b305ff0461e75a8ba78083f9a8891a3`
- `build_hbm_reference/reference_system_metadata.json`
  SHA-256 `480067752942d0e62686f88437170b19419df8cc86f739bdb03b9286561b02eb`
- extraction logs `reference_clock_extract.log`, `reference_system_extract.log`

Runtime samples are post-run observations; no continuous frequency or
throttling trace was captured. This closes the static-versus-runtime selected
clock-profile mismatch question, not the claim that transient throttling was
impossible. Hardware cycle comparisons do not use VCS wall time.
