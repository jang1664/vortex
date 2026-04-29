#!/usr/bin/env python3
import re
import json
import sys
from typing import Optional, Dict, Any, List, Tuple

# -------- 설정 부분 --------

# 타겟 코어 (cid)
TARGET_CID = 0

# 파이프라인 스테이지 트랙 (tid는 마음대로 고정만 잘 해두면 됨)
STAGE_TRACKS = {
    "pipeline-schedule": {"tid": 10, "label": "Schedule",       "order": 0},
    "pipeline-decode":   {"tid": 11, "label": "Decode",         "order": 1},
    "pipeline-ibuffer":  {"tid": 14, "label": "IBuffer",        "order": 2},
    "pipeline-dispatch": {"tid": 12, "label": "Issue/Dispatch", "order": 3},
    "pipeline-operands": {"tid": 15, "label": "Operands",       "order": 4},
    "pipeline-commit":   {"tid": 13, "label": "Commit",         "order": 6},
}

# 실행 유닛 트랙. 모든 unit은 pipeline 흐름상 Operands 와 Commit 사이로 본다 (order=5).
UNIT_TRACKS = {
    "alu-unit":  {"tid": 20, "label": "ALU",  "order": 5},
    "sfu-unit":  {"tid": 21, "label": "SFU",  "order": 5},
    "fpu-unit":  {"tid": 22, "label": "FPU",  "order": 5},
    "lsu-unit":  {"tid": 24, "label": "LSU",  "order": 5},
    "vpu-unit":  {"tid": 25, "label": "VPU",  "order": 5},
    "tcu":       {"tid": 23, "label": "TCU",  "order": 5},  # TensorUnit::Create("tcu", ...)
    "tcu-unit":  {"tid": 23, "label": "TCU",  "order": 5},  # FuncUnit "tcu-unit" 변형
}

# Flow event 토글
EMIT_PIPELINE_FLOW = True   # 같은 uuid의 stage/unit 슬라이스를 순서대로 연결
EMIT_RAW_FLOW = True        # 같은 wid의 producer commit (rd) → consumer 첫 stage (rsK)

# 각 이벤트의 기본 duration (cycle 단위)
DEFAULT_DUR = 1

# -------- 파서 구현 --------

TRACE_RE = re.compile(r'^TRACE\s+(\d+):\s+([^:]+):\s+(.*)$')
# DEBUG Instr: <DISASM>, cid=…, wid=…, tmask=…, PC=0x… (#uuid)
DEBUG_INSTR_RE = re.compile(r'^DEBUG\s+Instr:\s+(.*)$')
# DEBUG Fetch: code=0x…, cid=…, …, PC=0x… (#uuid)
DEBUG_FETCH_RE = re.compile(r'^DEBUG\s+Fetch:\s+code=(0x[0-9a-fA-F]+),\s*(.*)$')
ATTR_RE = re.compile(r'(\w+)=([^,\s]+)')
UUID_RE = re.compile(r'\(#(\d+)\)\s*$')

def parse_attrs(attr_str: str) -> Dict[str, str]:
    """cid=0, wid=0, tmask=1000, PC=0x80000038, wb=0, rs0=x5, ex=SFU (#26)"""
    attrs = {}
    m = UUID_RE.search(attr_str)
    if m:
        attrs["uuid"] = m.group(1)
        attr_str = attr_str[:m.start()]
    else:
        # fallback: 옛날 방식대로 (# 이후 자르기
        attr_str = attr_str.split("(#")[0]
    for k, v in ATTR_RE.findall(attr_str):
        attrs[k] = v
    return attrs

def build_event(ts: int,
                comp: str,
                attrs: Dict[str, str]) -> Optional[Dict[str, Any]]:
    """TRACE 한 줄을 Perfetto 이벤트로 변환."""
    # cid 필터링
    cid_str = attrs.get("cid")
    if cid_str is not None:
        try:
            if int(cid_str) != TARGET_CID:
                return None
        except ValueError:
            pass  # 이상하면 그냥 통과

    # 파이프라인 스테이지 트랙
    if comp in STAGE_TRACKS:
        info = STAGE_TRACKS[comp]
        tid = info["tid"]
        label = info["label"]

        event_name = label  # 바 안에 찍힐 이름
        args = {"stage": label}
        args.update(attrs)

        return {
            "name": event_name,
            "ph": "X",
            "ts": ts,
            "dur": DEFAULT_DUR,
            "pid": 0,
            "tid": tid,
            "args": args,
            "_order": info["order"],
            "_kind": "stage",
            "_comp": comp,
        }

    # 실행 유닛 트랙
    if comp in UNIT_TRACKS:
        info = UNIT_TRACKS[comp]
        tid = info["tid"]
        label = info["label"]

        # op 이름이 있으면 바 이름으로 사용
        op = attrs.get("op", label)
        event_name = op

        args = {"unit": label}
        args.update(attrs)

        return {
            "name": event_name,
            "ph": "X",
            "ts": ts,
            "dur": DEFAULT_DUR,
            "pid": 0,
            "tid": tid,
            "args": args,
            "_order": info["order"],
            "_kind": "unit",
            "_comp": comp,
        }

    # 관심 없는 컴포넌트는 스킵
    return None

def parse_trace_line(line: str) -> Optional[Dict[str, Any]]:
    m = TRACE_RE.match(line)
    if not m:
        return None

    ts_str, comp, rest = m.groups()
    try:
        ts = int(ts_str)
    except ValueError:
        return None

    comp = comp.strip()
    attrs = parse_attrs(rest)

    return build_event(ts, comp, attrs)


def parse_debug_instr_line(line: str) -> Optional[Tuple[str, str]]:
    """DEBUG Instr 줄에서 (uuid, disasm) 추출. disasm = ", cid=" 앞부분 전체."""
    m = DEBUG_INSTR_RE.match(line)
    if not m:
        return None
    rest = m.group(1).rstrip()
    um = UUID_RE.search(rest)
    if not um:
        return None
    uuid = um.group(1)
    body = rest[:um.start()].rstrip()
    # ", cid=" 앞에서 잘라 disasm 만 남김
    idx = body.find(", cid=")
    disasm = body[:idx].rstrip() if idx != -1 else body
    return uuid, disasm


def parse_debug_fetch_line(line: str) -> Optional[Tuple[str, str]]:
    """DEBUG Fetch 줄에서 (uuid, code) 추출."""
    m = DEBUG_FETCH_RE.match(line)
    if not m:
        return None
    code, rest = m.group(1), m.group(2)
    um = UUID_RE.search(rest)
    if not um:
        return None
    return um.group(1), code

def build_metadata_events() -> List[Dict[str, Any]]:
    """프로세스/스레드 이름 붙이는 메타 이벤트."""
    events = []

    # process name
    events.append({
        "name": "process_name",
        "ph": "M",
        "pid": 0,
        "tid": 0,
        "args": {"name": f"VortexCore{TARGET_CID}"}
    })

    # stage tracks
    for comp, info in STAGE_TRACKS.items():
        events.append({
            "name": "thread_name",
            "ph": "M",
            "pid": 0,
            "tid": info["tid"],
            "args": {"name": f"Stage: {info['label']}"}
        })

    # unit tracks
    for comp, info in UNIT_TRACKS.items():
        events.append({
            "name": "thread_name",
            "ph": "M",
            "pid": 0,
            "tid": info["tid"],
            "args": {"name": f"Unit: {info['label']}"}
        })

    return events

def build_pipeline_flows(x_events: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """같은 uuid 의 stage/unit 슬라이스를 (order, ts) 순으로 묶어 s/t/f 체인 emit."""
    by_uuid: Dict[str, List[Dict[str, Any]]] = {}
    for e in x_events:
        u = e["args"].get("uuid")
        if u is None:
            continue
        by_uuid.setdefault(u, []).append(e)

    flows: List[Dict[str, Any]] = []
    for u, evs in by_uuid.items():
        if len(evs) < 2:
            continue
        # pipeline order 우선, 동일 order 면 ts 순
        evs.sort(key=lambda e: (e["_order"], e["ts"]))
        flow_id = f"u{u}"
        n = len(evs)
        for i, e in enumerate(evs):
            if i == 0:
                ph = "s"
            elif i == n - 1:
                ph = "f"
            else:
                ph = "t"
            fe = {
                "name": "instr",
                "cat": "pipeline",
                "id": flow_id,
                "ph": ph,
                "ts": e["ts"],
                "pid": e["pid"],
                "tid": e["tid"],
            }
            if ph == "f":
                fe["bp"] = "e"  # enclosing slice 에 bind (default 가 next slice 라서 명시)
            flows.append(fe)
    return flows


def build_raw_flows(x_events: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """RAW dependency: 같은 wid 의 (commit, rd=xN) → 다음 (consumer 첫 stage, rsK=xN)."""
    # uuid 별 (가장 일찍 등장하는 슬라이스, commit 슬라이스) 찾기
    first_by_uuid: Dict[str, Dict[str, Any]] = {}
    commit_by_uuid: Dict[str, Dict[str, Any]] = {}
    for e in x_events:
        u = e["args"].get("uuid")
        if u is None:
            continue
        if u not in first_by_uuid:
            first_by_uuid[u] = e
        else:
            cur = first_by_uuid[u]
            if (e["_order"], e["ts"]) < (cur["_order"], cur["ts"]):
                first_by_uuid[u] = e
        if e["_comp"] == "pipeline-commit":
            commit_by_uuid[u] = e

    # 시간 순으로 처리하면서 register 마지막 writer 추적
    last_writer: Dict[Tuple[str, str], str] = {}  # (wid, reg) -> producer uuid
    flows: List[Dict[str, Any]] = []

    # uuid 별로 처리: 각 uuid 가 처음 등장하는 시점에 rsK 검사, commit 시점에 rd 등록
    # → 시간 순서를 유지하기 위해 모든 슬라이스를 ts 기준 정렬
    for e in sorted(x_events, key=lambda x: (x["ts"], x["_order"])):
        args = e["args"]
        u = args.get("uuid")
        if u is None:
            continue
        wid = args.get("wid")
        if wid is None:
            continue

        # 이 uuid 의 첫 슬라이스에서만 rs 읽기 처리 (중복 arrow 방지)
        if e is first_by_uuid.get(u):
            for k, v in args.items():
                if not (k.startswith("rs") and k[2:].isdigit()):
                    continue
                key = (wid, v)
                producer_u = last_writer.get(key)
                if producer_u is None or producer_u == u:
                    continue
                producer = commit_by_uuid.get(producer_u)
                if producer is None:
                    continue
                fid = f"raw-{producer_u}-{u}-{k}"
                flows.append({
                    "name": f"RAW {v}",
                    "cat": "raw",
                    "id": fid,
                    "ph": "s",
                    "ts": producer["ts"],
                    "pid": producer["pid"],
                    "tid": producer["tid"],
                })
                flows.append({
                    "name": f"RAW {v}",
                    "cat": "raw",
                    "id": fid,
                    "ph": "f",
                    "ts": e["ts"],
                    "pid": e["pid"],
                    "tid": e["tid"],
                    "bp": "e",
                })

        # commit 시점에 rd 등록
        if e["_comp"] == "pipeline-commit":
            rd = args.get("rd")
            wb = args.get("wb")
            if rd is not None and wb not in (None, "0"):
                last_writer[(wid, rd)] = u

    return flows


def strip_internal(events: List[Dict[str, Any]]) -> None:
    for e in events:
        for k in ("_order", "_kind", "_comp"):
            e.pop(k, None)


def convert_log_to_perfetto(infile, outfile):
    trace_events: List[Dict[str, Any]] = []
    x_events: List[Dict[str, Any]] = []

    # 메타데이터 이벤트 먼저 삽입
    trace_events.extend(build_metadata_events())

    for line in infile:
        ev = parse_trace_line(line)
        if ev is not None:
            trace_events.append(ev)
            x_events.append(ev)

    if EMIT_PIPELINE_FLOW:
        trace_events.extend(build_pipeline_flows(x_events))
    if EMIT_RAW_FLOW:
        trace_events.extend(build_raw_flows(x_events))

    strip_internal(trace_events)

    json.dump({"traceEvents": trace_events}, outfile, indent=2)
    outfile.write("\n")

def main():
    if len(sys.argv) not in (1, 3):
        print(f"Usage: {sys.argv[0]} [input.log output.json]", file=sys.stderr)
        print("  If no args are given, read from stdin and write to stdout.", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) == 1:
        convert_log_to_perfetto(sys.stdin, sys.stdout)
    else:
        in_path, out_path = sys.argv[1], sys.argv[2]
        with open(in_path, "r", encoding="utf-8") as f_in, \
             open(out_path, "w", encoding="utf-8") as f_out:
            convert_log_to_perfetto(f_in, f_out)

if __name__ == "__main__":
    main()