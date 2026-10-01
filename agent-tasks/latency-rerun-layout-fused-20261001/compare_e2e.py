"""Compare complete composed latency before and after selective rerun."""
from pathlib import Path
import csv
import sys
csv.field_size_limit(sys.maxsize)
ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/"analysis_workspace/latency_on_hw"
TAG="th16_20260920_c4_slots16_v2r1"

def load(directory,model):
    path=next(directory.glob(f"{model}_e2e_no_area_norm_gemm_layout_vector_stacked*/total.csv"))
    with path.open(newline="") as f:
        return {(r["stage"],r["batch"],r["seq_len"],r["variant"]):{
            "seconds":float(r["final_total_latency_s"]),"missing":int(r["missing_case_count"])}
            for r in csv.DictReader(f)}

def main():
    result=[]
    for model in ("llama2_7b","llama3_8b"):
        old=load(BASE/f"backups/20261001T011103/figure_prepare.{TAG}",model)
        new=load(BASE/f"figure_prepare.{TAG}",model)
        for key,row in sorted(new.items()):
            stage,batch,seq,variant=key
            if variant!="all_fpint_gemm_improve_fused_layout_spinquant":continue
            before=old[key]
            c3=new[(stage,batch,seq,"all_fpint_gemm_naive_spinquant")]
            result.append(dict(model=model,stage=stage,batch=int(batch),sequence=int(seq),
                old_c4_seconds=before["seconds"],new_c4_seconds=row["seconds"],
                c4_change_percent=100*(row["seconds"]/before["seconds"]-1),
                c3_seconds=c3["seconds"],new_c4_over_c3=row["seconds"]/c3["seconds"],
                missing_cases=row["missing"]))
    path=Path(__file__).with_name("e2e_before_after.csv")
    with path.open("w",newline="") as f:
        w=csv.DictWriter(f,fieldnames=list(result[0]));w.writeheader();w.writerows(result)
    assert all(r["missing_cases"]==0 for r in result),"composed cases missing"
    for row in result:
        if row["stage"]=="prefill":
            print(row["model"],row["sequence"],f"C4 change {row['c4_change_percent']:+.2f}%",f"C4/C3 {row['new_c4_over_c3']:.4f}")
if __name__=="__main__":main()
