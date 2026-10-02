"""Capture Vivado on a private Xvfb display and clean up owned processes."""

from __future__ import annotations

from contextlib import ExitStack, closing
import hashlib
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import time

from x11_input import X11Input

HERE = Path(__file__).resolve().parent
# Exclude the Device notification bar so it cannot keep black margins on trim.
# Default Vivado 2025.1 layout on the fixed 1920x1200 virtual screen.
CANVAS = "1536x904+366+215"


def require_program(name: str) -> str:
    # PATH can contain the obsolete Xvfb bundled with Synopsys tools.
    program = shutil.which(name, path="/usr/bin:/bin") or shutil.which(name)
    if program is None:
        raise FileNotFoundError(f"Required capture program is unavailable: {name}")
    return program


def stop_process(process: subprocess.Popen, *, group: bool = False):
    try:
        if group:
            os.killpg(process.pid, signal.SIGTERM)
        elif process.poll() is None:
            process.terminate()
        process.wait(timeout=5)
    except ProcessLookupError:
        process.wait()
    except subprocess.TimeoutExpired:
        try:
            if group:
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass
        process.wait()


def wait_for_ui(predicate, description: str):
    deadline = time.monotonic() + 30
    while not predicate():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Vivado GUI did not respond: {description}")
        time.sleep(0.2)


def set_drawer(ui: X11Input, opened: bool):
    def is_open():
        return min(ui.pixels(1850, 225)[0]) > 220
    if is_open() != opened:
        ui.click(1890, 168)
        wait_for_ui(lambda: is_open() == opened, "Device Resource Types drawer")


def reset_layout(ui: X11Input):
    ui.key("F5")  # Reset layout before using fixed Device-view coordinates.
    time.sleep(1)
    wait_for_ui(lambda: min(ui.pixels(400, 400)[0]) > 220, "default layout")


def frame_device(ui: X11Input):
    reset_layout(ui)
    red, _, blue = ui.pixels(300, 95)[0]
    has_navigator = blue - red < 20
    # Preserve Vivado's resource visibility and colors; only frame the view.
    set_drawer(ui, False)
    ui.click(1873 if has_navigator else 1853, 137)  # Maximize Device view.
    wait_for_ui(lambda: max(ui.pixels(400, 400)[0]) < 100, "maximized Device view")
    # Checkpoint mode has no Flow Navigator beside the maximized Device view.
    ui.click(523 if has_navigator else 190, 168)  # Zoom Fit.


def save_device(env: dict[str, str], output: Path, deadline: float, settle: float):
    image_program = require_program("import")
    convert_program = require_program("convert")
    with closing(X11Input(env["DISPLAY"])) as ui:
        frame_device(ui)
        time.sleep(settle)
        previous, stable = None, 0
        while time.monotonic() < deadline:
            screenshot = subprocess.check_output(
                [image_program, "-window", "root", "-silent", "png:-"],
                env=env, timeout=15,
            )
            data = subprocess.check_output(
                [convert_program, "png:-", "-crop", CANVAS, "+repage", "-depth", "8", "rgb:-"],
                input=screenshot, env=env, timeout=15,
            )
            # Reject an empty/unfinished Device canvas; require colored cells.
            colored = data.count(bytes((55, 126, 184))) + data.count(bytes((77, 175, 74)))
            digest = hashlib.sha256(data).digest()
            stable = stable + 1 if digest == previous and colored > 100 else 0
            if stable >= 2:
                break
            previous = digest
            time.sleep(2)
        else:
            raise TimeoutError("Device rendering did not settle before the capture timeout")
        (output / "full.png").write_bytes(screenshot)
        subprocess.run(
            [convert_program, str(output / "full.png"), "-crop", CANVAS, "+repage",
             "-trim", "+repage", str(output / "floorplan.png")],
            env=env, check=True, timeout=30,
        )
        print(f"Saved: {output / 'floorplan.png'}", flush=True)


def capture_floorplan(command: list[str], output: Path, timeout: float, settle: float) -> int:
    xvfb_program = require_program("Xvfb")
    wm_program = require_program("fluxbox")
    require_program("import")
    require_program("convert")
    if shutil.which(command[0]) is None:
        raise FileNotFoundError(f"Vivado executable is unavailable: {command[0]}")
    output.mkdir(parents=True, exist_ok=False)
    print(f"Capture directory: {output}", flush=True)
    deadline = time.monotonic() + timeout
    with ExitStack() as stack:
        xvfb_log = stack.enter_context((output / "xvfb.log").open("w"))
        read_fd, write_fd = os.pipe()
        stack.callback(os.close, read_fd)
        try:
            xvfb = subprocess.Popen(
                [xvfb_program, "-displayfd", str(write_fd), "-screen", "0", "1920x1200x24",
                 "-nolisten", "tcp", "-ac"],
                pass_fds=(write_fd,), stdout=xvfb_log, stderr=subprocess.STDOUT,
            )
        finally:
            os.close(write_fd)
        stack.callback(stop_process, xvfb)
        if not select.select([read_fd], [], [], min(15, timeout))[0]:
            raise TimeoutError(f"Xvfb startup timed out; see {output / 'xvfb.log'}")
        display_number = os.read(read_fd, 64).decode().strip()
        if not display_number.isdecimal():
            raise RuntimeError(f"Xvfb failed to start; see {output / 'xvfb.log'}")
        env = os.environ.copy()
        env["DISPLAY"] = f":{display_number}"
        wm_log = stack.enter_context((output / "fluxbox.log").open("w"))
        wm = subprocess.Popen([wm_program], env=env, stdout=wm_log, stderr=subprocess.STDOUT)
        stack.callback(stop_process, wm)
        console = stack.enter_context((output / "console.log").open("w"))
        launch = [part for part in command if part not in {"-nolog", "-nojournal"}]
        launch[launch.index("-source") + 1] = str(HERE / "capture_photo.tcl")
        tclargs = launch.index("-tclargs")
        launch[tclargs:tclargs] = ["-log", "vivado.log", "-journal", "vivado.jou"]
        launch.append(str(output))
        vivado = subprocess.Popen(
            launch, cwd=output, env=env, stdout=console, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        stack.callback(stop_process, vivado, group=True)
        print(f"Vivado loading implementation on {env['DISPLAY']}...", flush=True)
        ready, failed = output / "ready.txt", output / "failed.txt"
        next_update = time.monotonic() + 30
        while not ready.is_file():
            if failed.is_file():
                raise RuntimeError(f"Floorplan Tcl failed:\n{failed.read_text()}")
            if vivado.poll() is not None:
                raise RuntimeError(f"Vivado exited with status {vivado.returncode}; see {console.name}")
            if time.monotonic() >= deadline:
                raise TimeoutError(f"Implementation loading timed out; see {console.name}")
            if time.monotonic() >= next_update:
                print(f"Waiting for implementation/coloring; log: {console.name}", flush=True)
                next_update += 30
            time.sleep(0.5)
        save_device(env, output, deadline, settle)
    return 0
