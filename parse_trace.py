#!/usr/bin/env python3
import re
import json
import sys
from typing import Optional, Dict, Any, List

# -------- 설정 부분 --------

# 타겟 코어 (cid)
TARGET_CID = 0

# 파이프라인 스테이지 트랙 (tid는 마음대로 고정만 잘 해두면 됨)
STAGE_TRACKS = {
    "pipeline-schedule": {"tid": 10, "label": "Schedule"},
    "pipeline-decode":   {"tid": 11, "label": "Decode"},
    "pipeline-dispatch": {"tid": 12, "label": "Issue/Dispatch"},
    "pipeline-commit":   {"tid": 13, "label": "Commit"},
    # 필요하면 추가
    "pipeline-ibuffer":  {"tid": 14, "label": "IBuffer"},
    "pipeline-operands": {"tid": 15, "label": "Operands"},
}

# 실행 유닛 트랙
UNIT_TRACKS = {
    "alu-unit": {"tid": 20, "label": "ALU"},
    "sfu-unit": {"tid": 21, "label": "SFU"},
    "fpu-unit": {"tid": 22, "label": "FPU"},
    "tcu":  {"tid": 23, "label": "TCU"},
    # Vortex에서 쓰는 이름 더 있으면 여기에 추가
}

# 각 이벤트의 기본 duration (cycle 단위)
DEFAULT_DUR = 1

# -------- 파서 구현 --------

TRACE_RE = re.compile(r'^TRACE\s+(\d+):\s+([^:]+):\s+(.*)$')
ATTR_RE = re.compile(r'(\w+)=([^,\s]+)')

def parse_attrs(attr_str: str) -> Dict[str, str]:
    """cid=0, wid=0, tmask=1000, PC=0x80000038, wb=0, rs0=x5, ex=SFU (#26)"""
    attrs = {}
    # 괄호 뒤 (#26) 같은 부분 제거
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

def convert_log_to_perfetto(infile, outfile):
    trace_events: List[Dict[str, Any]] = []

    # 메타데이터 이벤트 먼저 삽입
    trace_events.extend(build_metadata_events())

    for line in infile:
        ev = parse_trace_line(line)
        if ev is not None:
            trace_events.append(ev)

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
