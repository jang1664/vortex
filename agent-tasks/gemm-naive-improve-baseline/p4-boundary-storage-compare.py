#!/usr/bin/env python3
"""Compare declaration capacities; this is not synthesis or behavior proof."""
import json
from pathlib import Path
TASK = Path(__file__).resolve().parent
PREFIXES = ("u_VX_gemm_acc_lmem.", "psum_rd_lane_split.", "final_lane_split.",
            "psum_wr_lane_split.", "g_lmem_lane_arb[", "g_psum_lane_arb[",
            "u_VX_gemm_compute_core.", "VX_job_frontend_instance.")
result = {}
for mxu in (16, 32):
    inventories = [json.loads((TASK / f"{phase}-boundary-storage-elaborated{mxu}.json").read_text()) for phase in ("p0", "p4")]
    maps = [{r["path"].split(".node.", 1)[1]: (r["module"], r["bits"]) for r in d["records"]} for d in inventories]
    checks = {}
    for prefix in PREFIXES:
        selected = [{k: v for k, v in m.items() if k.startswith(prefix)} for m in maps]
        assert selected[0] and selected[0] == selected[1], prefix
        checks[prefix] = dict(unchanged=True, objects=len(selected[0]), bits=sum(v[1] for v in selected[0].values()))
    weight = [r for r in inventories[1]["records"] if ".weight_executor." in r["path"]]
    payload = [r for r in weight if r["path"].endswith("assembly_data_r") or ".response_payload_ram." in r["path"]]
    weight_bits = sum(r["bits"] for r in payload)
    assert weight_bits == {16: 288*8, 32: 1088*8}[mxu]
    result[mxu] = dict(retained_declarations=checks, weight_payload_bits=weight_bits,
                       weight_other_bits=sum(r["bits"] for r in weight)-weight_bits,
                       weight_payload_objects=payload,
                       scope="Retained sequential names/modules/widths only; does not prove unchanged logic or hardware cost.")
(TASK / "p4-boundary-storage-comparison.json").write_text(json.dumps(result, indent=2)+"\n")
print("MXU16/32 retained declaration comparisons and weight payload capacity PASS")
