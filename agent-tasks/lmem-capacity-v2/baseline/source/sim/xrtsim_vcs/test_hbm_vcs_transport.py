"""Exercise production simv startup, BO transport, errors and shutdown via TCP."""
import argparse
import json
import os
import secrets
from pathlib import Path
import socket
import struct
import subprocess
import time

HEADER = struct.Struct("<BB2xIQII")


def packet(kind, seq=1, addr=0, size=0, value=0):
    return HEADER.pack(kind, 0, seq, addr, size, value)


def receive(sock, size):
    result = bytearray()
    while len(result) < size:
        part = sock.recv(size - len(result))
        if not part:
            raise RuntimeError("Unexpected peer EOF")
        result.extend(part)
    return bytes(result)


def port_pair():
    # Keep the selection check local; a concurrent binder is reported as a
    # startup failure, never mistaken for an expected negative test result.
    for _ in range(100):
        with socket.socket() as first, socket.socket() as second:
            # Stay below Linux's ephemeral client-port range. Otherwise a
            # connection retry can itself claim the not-yet-listening mem port.
            port = 10000 + secrets.randbelow(20000)
            try:
                first.bind(("0.0.0.0", port))
                second.bind(("0.0.0.0", port + 1))
                return port
            except OSError:
                pass
    raise RuntimeError("Cannot find two available ports")


def connect(port, process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("simv exited before connection")
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=0.2)
            sock.settimeout(10)
            return sock
        except ConnectionRefusedError:
            time.sleep(0.01)
    raise RuntimeError("simv connection timeout")


def run_case(binary, manifest, output, case):
    directory = output / case
    directory.mkdir(parents=True, exist_ok=True)
    port = port_pair()
    control = memory = None
    flags = []
    if case.startswith("reset_"):
        flags.append(f"+TEST_CONTROL_RESET={1 if 'queued' in case else 2}")
    with (directory / "simv.log").open("w") as log:
        process = subprocess.Popen([str(binary), f"+SOCKET_PORT={port}", *flags],
                                   cwd=directory, stdout=log, stderr=subprocess.STDOUT,
                                   env={**os.environ, "VCS_TRANSPORT_TIMEOUT_MS": "1000"})
        try:
            control = connect(port, process)
            memory = connect(port + 1, process)
            digest = manifest["sha256"] if case != "bad_hash" else "0" * 64
            memory.sendall(packet(0x30, size=64, value=2 if case == "bad_version" else 1)
                           + digest.encode())
            ack = HEADER.unpack(receive(memory, HEADER.size))
            assert ack[0] == 0x33 and ack[2] == 1 and ack[4] == 0, ack
            if case in ("bad_hash", "bad_version"):
                assert ack[5] == 1, ack
                expected = "Failed to accept connections"
            else:
                assert ack[5] == 0, ack
                if case == "shutdown":
                    # A BO round trip through the actual DPI-owned RAM must
                    # complete before the following control shutdown.
                    payload = bytes(range(64))
                    memory.sendall(packet(0x31, seq=2, addr=8192, size=64) + payload)
                    assert receive(memory, HEADER.size) == packet(0x33, seq=2)
                    memory.sendall(packet(0x32, seq=3, addr=8192, size=64))
                    assert receive(memory, HEADER.size) == packet(0x33, seq=3, size=64)
                    assert receive(memory, 64) == payload
                    control.sendall(packet(0x01, seq=0, value=0))
                    assert receive(control, HEADER.size) == packet(0x02, seq=0)
                    control.sendall(packet(0x03, seq=0))
                    assert HEADER.unpack(receive(control, HEADER.size))[0] == 0x04
                    control.sendall(packet(0x05))
                    control.shutdown(socket.SHUT_WR)
                    memory.shutdown(socket.SHUT_WR)
                    expected = "Received SHUTDOWN command"
                elif case == "control_eof":
                    control.shutdown(socket.SHUT_WR)
                    expected = "Host transport disconnected"
                elif case == "memory_eof":
                    memory.shutdown(socket.SHUT_WR)
                    expected = "Host transport disconnected"
                elif case == "partial_control":
                    control.sendall(packet(0x01)[:3])
                    control.shutdown(socket.SHUT_WR)
                    expected = "Incomplete host control packet"
                elif case == "invalid_control":
                    control.sendall(packet(0xff))
                    expected = "Incomplete host control packet"
                elif case == "stalled_control":
                    control.sendall(packet(0x01)[:3])
                    expected = "Incomplete host control packet"
                elif case == "stalled_memory":
                    memory.sendall(packet(0x31, size=64) + b"abc")
                    expected = "Host transport disconnected"
                elif case == "oversized_memory":
                    memory.sendall(packet(0x31, size=(1 << 20) + 1))
                    expected = "Host transport disconnected"
                elif case.startswith("reset_"):
                    control.sendall(packet(0x01 if case.endswith("write") else 0x03))
                    # Failure closes the transport, never a fabricated success
                    # ACK/read response for the reset-canceled command.
                    assert control.recv(HEADER.size) == b""
                    expected = "Reset canceled an outstanding host control command"
                else:
                    raise AssertionError(case)
            code = process.wait(timeout=15)
        finally:
            if control is not None:
                control.close()
            if memory is not None:
                memory.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    text = (directory / "simv.log").read_text()
    assert expected in text, text[-4000:]
    if case == "shutdown":
        assert code == 0 and "Fatal:" not in text and "Error:" not in text, text[-4000:]
        assert "sockets closed" in text
    else:
        # This VCS build returns zero even for SV $fatal. Require the specific
        # failure text and a normal process exit, not just a nonzero status.
        assert code in (0, 1) and "Fatal:" in text, text[-4000:]
    print(f"Production VCS transport passed: {case}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simv", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    for case in ("shutdown", "bad_hash", "bad_version", "control_eof", "memory_eof",
                 "partial_control", "invalid_control", "oversized_memory",
                 "stalled_control", "stalled_memory", "reset_queued_read",
                 "reset_queued_write", "reset_active_read", "reset_active_write"):
        run_case(args.simv.resolve(), manifest, args.output_dir.resolve(), case)


if __name__ == "__main__":
    main()
