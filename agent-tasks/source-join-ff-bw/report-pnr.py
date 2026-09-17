#!/usr/bin/env python3
"""Extract comparable final timing, resources and packaged clock from PnR artifacts."""
import csv, itertools, json, re
from pathlib import Path
TASK=Path(__file__).resolve().parent
KEYS=("wns_ns","tns_ns","setup_failing_endpoints","setup_endpoints","whs_ns","ths_ns","hold_failing_endpoints","hold_endpoints","wpws_ns","tpws_ns","pulse_failing_endpoints","pulse_endpoints")

def timing(path):
    with path.open() as f: lines=list(itertools.islice(f,1000))
    result={"report":str(path)}
    for i,line in enumerate(lines):
        if "WNS(ns)" in line and "TNS Failing Endpoints" in line and "global" not in result:
            values=lines[i+2].split()
            assert len(values)==12, values
            result["global"]=dict(zip(KEYS,map(float,values)))
        values=line.split()
        if values and values[0]=="clk_kernel_00_unbuffered_net":
            if len(values)==5 and values[1].startswith("{"):
                result["kernel_period_ns"]=float(values[3])
            if len(values)==13:
                result["kernel"]=dict(zip(KEYS,map(float,values[1:])))
    assert all(k in result for k in ("global","kernel","kernel_period_ns")),path
    return result

def utilization(path):
    wanted={"CLB LUTs":"LUT","CLB Registers":"FF","Block RAM Tile":"BRAM_tiles","DSPs":"DSP","URAM":"URAM"}
    result={"report":str(path)}
    with path.open() as f:
        for line in f:
            fields=[s.strip().replace("*","") for s in line.split("|")]
            if len(fields)>3 and fields[1] in wanted and wanted[fields[1]] not in result:
                result[wanted[fields[1]]]=float(fields[2].replace(",",""))
    assert all(k in result for k in ("LUT","FF","BRAM_tiles","DSP")),path
    return result

def clock(path):
    text=path.read_text()
    data=re.search(r"Name:\s+DATA_CLK\s+Index:.*?Frequency:\s+([0-9.]+) MHz",text,re.S)
    system=re.search(r"Name:\s+ulp_ucs_aclk_kernel_00\s+Type:.*?Requested Freq:\s+([0-9.]+) MHz\s+Achieved Freq:\s+([0-9.]+) MHz",text,re.S)
    assert data and system,path
    result=dict(data_mhz=float(data[1]),requested_mhz=float(system[1]),achieved_mhz=float(system[2]),report=str(path))
    assert result["data_mhz"]==result["achieved_mhz"],result
    return result

def families(path):
    result={}
    with path.open() as f:
        for row in csv.DictReader(f,delimiter="\t"):
            end=row["end"].lower()
            key=("source_join" if "/source_join/" in end else "naive_controller" if "/control/controller/" in end else "LSU" if "lsu" in end else "other_GEMM" if "gemm" in end else "other")
            item=result.setdefault(key,{"endpoints":0,"worst_slack_ns":0})
            item["endpoints"]+=1
            item["worst_slack_ns"]=min(item["worst_slack_ns"],float(row["slack"]))
    return result

def first_path(path):
    with path.open() as f:
        text="".join(itertools.islice(f, 70))
    def match(pattern):
        result=re.search(pattern,text)
        assert result, (path,pattern)
        return result[1]
    return dict(
        report=str(path),
        slack_ns=float(match(r"Slack \(.*?\)\s*:\s*([-0-9.]+)ns")),
        source=match(r"Source:\s+(\S+)"),
        destination=match(r"Destination:\s+(\S+)"),
        data_delay_ns=float(match(r"Data Path Delay:\s+([0-9.]+)ns")),
        logic_delay_ns=float(match(r"\(logic ([0-9.]+)ns")),
        route_delay_ns=float(match(r"route ([0-9.]+)ns")),
        logic_levels=int(match(r"Logic Levels:\s+([0-9]+)")),
    )

if __name__=="__main__":
    baseline=TASK/"baseline/pnr"
    output=Path((TASK/"pnr/output-dir.txt").read_text().strip())
    impl=output/"_x/link/vivado/vpl/prj/prj.runs/impl_1"
    after=TASK/"pnr/analysis"
    results={
        "before":{"timing":timing(baseline/"impl_1_hw_bb_locked_timing_summary_postroute_physopted.rpt"),"resources":utilization(baseline/"final_utilization.rpt"),"clock":clock(baseline/"vortex_afu.xclbin.info")},
        "after":{"timing":timing(impl/"hw_bb_locked_timing_summary_postroute_physopted.rpt"),"resources":utilization(after/"final_utilization.rpt"),"clock":clock(output/"bin/vortex_afu.xclbin.info")},
        "new_failing_endpoint_families":families(after/"violations.tsv"),
        "new_paths":{name:first_path(after/(name+".rpt")) for name in ("worst_kernel_paths","k_to_event_ff","event_ff_to_owner")},
        "bitstream_generated":any(impl.glob("*.bit")),
        "xclbin_packaged":(output/"bin/vortex_afu.xclbin").is_file(),
    }
    t=results["after"]["timing"];c=results["after"]["clock"]
    results["timing_closed_100mhz"]=(t["kernel_period_ns"]==10 and c["data_mhz"]==100 and t["global"]["setup_failing_endpoints"]==0 and t["global"]["hold_failing_endpoints"]==0 and t["global"]["pulse_failing_endpoints"]==0)
    (TASK/"pnr/results.json").write_text(json.dumps(results,indent=2)+"\n")
    print(json.dumps(results,indent=2))
