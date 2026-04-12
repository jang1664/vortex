"""Backend wrappers for Synopsys FSDB command-line utilities.

Each function invokes a Verdi utility via subprocess and returns its stdout.
Synopsys copyright banners and logDir warnings are stripped automatically.
"""

import os
import subprocess
import tempfile

# fsdbreport needs system libstdc++ to avoid GLIBCXX_3.4.30 error
_FSDBREPORT_ENV = {
    "LD_PRELOAD": "/usr/lib/x86_64-linux-gnu/libstdc++.so.6",
}

_SYNOPSYS_BANNER_LINES = {
    "",
    " ",
    "  ",
    "fsdbdebug (R)",
    "fsdbextract (R)",
    "fsdbreport (R)",
    "fsdbqry (R)",
}


def _clean_output(raw: str) -> str:
    """Remove Synopsys banners, copyright blocks, and Inclusivity notices."""
    lines = raw.splitlines()
    out = []
    skip = False
    for line in lines:
        stripped = line.strip()
        # Skip banner/copyright/inclusivity blocks
        if "Copyright (c)" in line or "Inclusivity & Diversity" in line:
            continue
        if stripped.startswith("logDir = "):
            continue
        if any(kw in stripped for kw in (
            "Version ", "fsdbdebug (R)", "fsdbextract (R)",
            "fsdbreport (R)", "fsdbqry (R)",
            "Synopsys, Inc.", "Licensed Products",
            "SolvNetPlus", "solvnetplus.synopsys.com",
            "This software and the associated",
            "This software may only be used",
            "communicate with Synopsys servers",
            "updates, detecting software piracy",
            "will use information gathered",
            "deliver software updates and pursue",
            "software pirates and", "infringers",
            "read the", "Statement on",
            "Inclusivity", "solvnetplus",
            "article 000036315",
        )):
            continue
        if stripped in _SYNOPSYS_BANNER_LINES:
            continue
        out.append(line)
    return "\n".join(out)


def _run(cmd: list[str], env_extra: dict | None = None) -> str:
    """Run a command and return cleaned stdout."""
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        cmd, capture_output=True, text=True, env=env, timeout=300,
    )
    if result.returncode != 0:
        stderr_clean = _clean_output(result.stderr)
        if stderr_clean.strip():
            raise RuntimeError(
                f"Command failed (rc={result.returncode}): {' '.join(cmd)}\n"
                f"{stderr_clean}"
            )
    return _clean_output(result.stdout + result.stderr)


def run_fsdbdebug(args: list[str], fsdb: str) -> str:
    """Run fsdbdebug with given flags.

    Args:
        args: Flags like ['-info'], ['-scope'], ['-tree'], ['-vc', '-vidcode', 'N']
        fsdb: Path to FSDB file.
    """
    return _run(["fsdbdebug"] + args + [fsdb])


def run_fsdbdebug_tree_lines(fsdb: str):
    """Stream fsdbdebug -tree output line by line (generator).

    Used for streaming parsers that process large FSDB files without
    loading the entire output into memory.
    """
    cmd = ["fsdbdebug", "-tree", fsdb]
    env = os.environ.copy()
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=env, bufsize=1,
    )
    try:
        for line in proc.stdout:
            stripped = line.strip()
            # Skip banner/log lines
            if (not stripped
                or stripped.startswith("logDir =")
                or any(kw in stripped for kw in (
                    "Copyright", "Synopsys", "Version ", "fsdbdebug (R)",
                    "Inclusivity", "solvnetplus", "Licensed Products",
                    "This software", "communicate with",
                    "software pirates", "read the", "Statement on",
                ))):
                continue
            yield stripped
    finally:
        proc.wait()
    return _run(["fsdbdebug"] + args + [fsdb])


def run_fsdbextract(
    fsdb: str,
    scope: str | None = None,
    level: int | None = None,
    bt: str | None = None,
    et: str | None = None,
    output: str | None = None,
) -> str:
    """Run fsdbextract to cut a sub-FSDB by scope and/or time range.

    Args:
        fsdb: Input FSDB file path.
        scope: Hierarchy scope to extract (e.g., '/tb/dut/u_core').
        level: Descendant depth to include.
        bt: Begin time with unit (e.g., '10ns').
        et: End time with unit (e.g., '20us').
        output: Output FSDB file path.
    """
    cmd = ["fsdbextract", fsdb]
    if scope:
        cmd += ["-s", scope]
    if level is not None:
        cmd += ["-level", str(level)]
    if bt:
        cmd += ["-bt", bt]
    if et:
        cmd += ["-et", et]
    if output:
        cmd += ["-o", output]
    return _run(cmd)


def run_fsdbreport(
    fsdb: str,
    signals: list[str],
    bt: str | None = None,
    et: str | None = None,
    csv: bool = True,
    output: str | None = None,
) -> str:
    """Run fsdbreport to dump signal value changes.

    Args:
        fsdb: Input FSDB file path.
        signals: List of signal paths (e.g., ['/tb/clk', '/tb/reset']).
        bt: Begin time with unit.
        et: End time with unit.
        csv: Output in CSV format (default True, easier to parse).
        output: Write report to file instead of stdout.
    """
    cmd = ["fsdbreport", fsdb]
    for sig in signals:
        cmd += ["-s", sig]
    if bt:
        cmd += ["-bt", bt]
    if et:
        cmd += ["-et", et]
    if csv:
        cmd.append("-csv")
    if output:
        cmd += ["-o", output]
    return _run(cmd, env_extra=_FSDBREPORT_ENV)


def run_fsdbreport_file(
    fsdb: str,
    signals: list[str],
    bt: str | None = None,
    et: str | None = None,
) -> str:
    """Run fsdbreport and return path to output CSV file.

    Uses a temp file because fsdbreport writes to -o file, not stdout for CSV.
    """
    if len(signals) > 1:
        from fsdb_cli.parsers import parse_csv_report

        time_unit = None
        per_signal_rows = {}

        for sig in signals:
            raw = run_fsdbreport_file(fsdb, [sig], bt=bt, et=et)
            this_time_unit, signal_names, data_rows = parse_csv_report(raw)
            if time_unit is None:
                time_unit = this_time_unit
            elif time_unit != this_time_unit:
                raise RuntimeError(
                    f"Inconsistent time unit while merging fsdbreport output: "
                    f"{time_unit} vs {this_time_unit}"
                )
            if len(signal_names) != 1:
                raise RuntimeError(
                    f"Expected single signal report while merging fsdbreport output, "
                    f"got: {signal_names}"
                )
            row_map = {}
            for row in data_rows:
                if not row:
                    continue
                timestamp = row[0]
                value = row[1] if len(row) > 1 else ""
                row_map[timestamp] = value
            per_signal_rows[sig] = row_map

        all_times = sorted({
            int(ts)
            for row_map in per_signal_rows.values()
            for ts in row_map.keys()
        })
        header = ",".join([f"Time({time_unit})", *signals])
        lines = [header]
        for ts in all_times:
            ts_s = str(ts)
            vals = [per_signal_rows.get(sig, {}).get(ts_s, "") for sig in signals]
            lines.append(",".join([ts_s, *vals]))
        return "\n".join(lines) + "\n"

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".csv", delete=False, prefix="fsdb_report_",
    ) as f:
        outpath = f.name
    try:
        run_fsdbreport(fsdb, signals, bt=bt, et=et, csv=True, output=outpath)
        with open(outpath) as f:
            return f.read()
    finally:
        os.unlink(outpath)
