"""Tests for the structured log format parser."""

import tempfile
from pathlib import Path

from log_analyzer.log_format import LogEntry, ParseError, parse_payload, parse_line, parse_file


def test_parse_atom_int():
    assert parse_payload("42") == 42


def test_parse_atom_negative():
    assert parse_payload("-7") == -7


def test_parse_atom_hex():
    assert parse_payload("0x1a") == 0x1a


def test_parse_atom_string():
    assert parse_payload("OP_ADD") == "OP_ADD"


def test_parse_flat_object():
    result = parse_payload("{opcode=OP_ADD, rd=5, rs1=3}")
    assert result == {"opcode": "OP_ADD", "rd": 5, "rs1": 3}


def test_parse_hex_values():
    result = parse_payload("{addr=0x1a, data=0x0064ff00}")
    assert result == {"addr": 0x1a, "data": 0x0064ff00}


def test_parse_simple_array():
    result = parse_payload("[N, S, E]")
    assert result == ["N", "S", "E"]


def test_parse_int_array():
    result = parse_payload("[1, 2, 3]")
    assert result == [1, 2, 3]


def test_parse_nested_object():
    result = parse_payload("{ctrl_ex={opcode=OP_ADD, rd=5}, state=1}")
    assert result == {"ctrl_ex": {"opcode": "OP_ADD", "rd": 5}, "state": 1}


def test_parse_array_of_objects():
    result = parse_payload("[{port=N, dst=S}, {port=E, dst=L}]")
    assert result == [{"port": "N", "dst": "S"}, {"port": "E", "dst": "L"}]


def test_parse_object_with_array():
    result = parse_payload("{grants=[N, S], blocked=0}")
    assert result == {"grants": ["N", "S"], "blocked": 0}


def test_parse_complex_nested():
    text = "{requests=[{port=N, dst=S, ready=1}, {port=E, dst=L, ready=0}], grants=[N], count=2}"
    result = parse_payload(text)
    assert result["count"] == 2
    assert len(result["requests"]) == 2
    assert result["requests"][0] == {"port": "N", "dst": "S", "ready": 1}
    assert result["grants"] == ["N"]


def test_parse_empty_object():
    assert parse_payload("{}") == {}


def test_parse_empty_array():
    assert parse_payload("[]") == []


def test_parse_empty_string():
    assert parse_payload("") == {}


def test_parse_deeply_nested():
    text = "{a={b={c=[1, 2, {d=3}]}}}"
    result = parse_payload(text)
    assert result["a"]["b"]["c"] == [1, 2, {"d": 3}]


# --- parse_line tests ---

def test_parse_line_basic():
    entry = parse_line("[1234] | EXECUTE | {opcode=OP_ADD, rd=5}")
    assert entry is not None
    assert entry.time == 1234
    assert entry.event == "EXECUTE"
    assert entry.payload == {"opcode": "OP_ADD", "rd": 5}


def test_parse_line_no_payload():
    entry = parse_line("[1234] | STEP_SUCCESS")
    assert entry is not None
    assert entry.time == 1234
    assert entry.event == "STEP_SUCCESS"
    assert entry.payload == {}


def test_parse_line_preserves_raw():
    raw = "[1234] | EXECUTE | {opcode=OP_ADD}"
    entry = parse_line(raw)
    assert entry.raw == raw


def test_parse_line_large_timestamp():
    entry = parse_line("[  999999999] | STALL_START | {reason=RECV_FIFO}")
    assert entry is not None
    assert entry.time == 999999999


def test_parse_line_rejects_non_structured():
    assert parse_line("some random text") is None
    assert parse_line("") is None
    assert parse_line("[1234] EXECUTE opcode=OP_ADD") is None


def test_parse_line_nested_payload():
    line = "[100] | CYCLE | {requests=[{port=N, dst=S}, {port=E, dst=L}], grants=[N]}"
    entry = parse_line(line)
    assert entry is not None
    assert entry.payload["requests"][0]["port"] == "N"
    assert entry.payload["grants"] == ["N"]


# --- parse_file tests ---

def test_parse_file():
    content = (
        "[100] | EXECUTE | {opcode=OP_ADD, rd=5}\n"
        "# this is a comment, ignored\n"
        "[200] | STALL_START | {reason=RECV_FIFO, fifo_id=3}\n"
        "[300] | STALL_END | {reason=RECV_FIFO, duration=15}\n"
        "some legacy log line that doesn't match\n"
        "[400] | STATE_CHANGE | {from=S_IDLE, to=S_COMPUTE}\n"
    )
    with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
        f.write(content)
        f.flush()
        entries = parse_file(f.name)

    assert len(entries) == 4
    assert entries[0].event == "EXECUTE"
    assert entries[1].payload["fifo_id"] == 3
    assert entries[2].payload["duration"] == 15
    assert entries[3].payload["to"] == "S_COMPUTE"


def test_parse_file_with_event_filter():
    content = (
        "[100] | EXECUTE | {opcode=OP_ADD}\n"
        "[200] | STALL_START | {reason=RECV_FIFO}\n"
        "[300] | EXECUTE | {opcode=OP_NOP}\n"
    )
    with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
        f.write(content)
        f.flush()
        entries = parse_file(f.name, events={"EXECUTE"})

    assert len(entries) == 2
    assert all(e.event == "EXECUTE" for e in entries)


# --- Run all tests ---

def run_tests():
    """Run all tests and report results."""
    import inspect

    test_funcs = [
        obj for name, obj in inspect.getmembers(
            inspect.getmodule(inspect.currentframe())
        )
        if name.startswith("test_") and callable(obj)
    ]

    passed = 0
    failed = 0
    for func in test_funcs:
        try:
            func()
            passed += 1
            print(f"  PASS  {func.__name__}")
        except Exception as e:
            failed += 1
            print(f"  FAIL  {func.__name__}: {e}")

    print(f"\n{passed} passed, {failed} failed, {passed + failed} total")
    return failed == 0


if __name__ == "__main__":
    run_tests()
