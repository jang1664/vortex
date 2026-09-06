"""Summarize one worst setup path per failing endpoint from Vivado TSV."""
import csv
from collections import Counter
from pathlib import Path

TASK = Path(__file__).resolve().parent


def classify(name):
    if "/gemm_node/" not in name:
        return "non_gemm"
    name = name.split("/gemm_node/", 1)[1]
    if name.startswith("u_tmem_subsystem/"):
        module = name.split("/", 2)[1]
        if module.startswith("g_bank"):
            return "tmem_banks"
        if module.startswith("g_dma_tmem_route"):
            return "pair_adapter"
        if module.startswith("u_switch"):
            return "tmem_switch"
        return module
    if name.startswith("u_VX_gemm_unit_v2/"):
        return "compute"
    module = name.split("/", 1)[0]
    if module in {"u_VX_gemm_ctrl", "u_tmem_dma_ctrl"}:
        return module
    return "gemm_other"


def main():
    with (TASK / "failing_paths.tsv").open() as source:
        paths = [row for row in csv.DictReader(source, delimiter="\t")
                 if row.get("startpoint") and row.get("endpoint")]
    paths.sort(key=lambda row: float(row["slack"]))
    label = "ALL" if len(paths) == 8580 else "PARTIAL_CAPTURE"
    for label, subset in [(label, paths), ("TOP500", paths[:500])]:
        for grouping in ["endpoint", "pair"]:
            counts = Counter()
            worst = {}
            for row in subset:
                key = classify(row["endpoint"])
                if grouping == "pair":
                    key = classify(row["startpoint"]) + " -> " + key
                counts[key] += 1
                worst[key] = min(worst.get(key, 0), float(row["slack"]))
            print(f"\n{label} {grouping}: {len(subset)} paths")
            for key in sorted(counts, key=lambda k: worst[k]):
                print(f"{key:65s} {counts[key]:6d} {worst[key]:8.3f}")
    print("\nWorst distinct start/end register families:")
    families = set()
    for row in paths:
        sp = row["startpoint"].split("/gemm_node/")[-1]
        ep = row["endpoint"].split("/gemm_node/")[-1]
        key = (classify(row["startpoint"]), classify(row["endpoint"]))
        if key in families:
            continue
        families.add(key)
        print(f"{row['slack']}\n  {sp}\n  {ep}")


if __name__ == "__main__":
    main()
