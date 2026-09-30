#!/usr/bin/env python3
"""Run isolated synthesis outputs and persist hourly PnR reviews."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

TASK = Path(__file__).resolve().parent
MANIFEST = json.loads((TASK / 'manifest.json').read_text())
REPO = Path(MANIFEST['repo'])
BUILDDIR = REPO / 'build'
RUNS = []
NOTIFIED = set()
BASELINES = {}


def now():
    return dt.datetime.now().astimezone().isoformat(timespec='seconds')


def event(kind, **data):
    record = {'time': now(), 'event': kind, **data}
    with (TASK / 'events.jsonl').open('a') as stream:
        stream.write(json.dumps(record) + '\n')
    print(json.dumps(record), flush=True)


def alarm(key, message):
    if key in NOTIFIED:
        return
    NOTIFIED.add(key)
    event('problem_or_completion', message=message)
    try:
        result = subprocess.run(['notify-me', 'alarm'], capture_output=True,
                                text=True, timeout=30)
        # Keep notification credentials and transport responses out of logs.
        event('alarm', key=key, returncode=result.returncode)
    except Exception as exc:
        event('alarm_failed', key=key, exception=type(exc).__name__)


def remember_logs(out):
    # Log files can be appended on resume. Record their old end and anchor so
    # old errors cannot be reported as errors from this attempt.
    paths = [*out.glob('_x/logs/**/*.log'),
             *out.glob('_x/link/vivado/vpl/prj/prj.runs/*/runme.log')]
    for path in paths:
        try:
            stat = path.stat()
            with path.open('rb') as stream:
                stream.seek(max(0, stat.st_size - 128))
                anchor = stream.read()
            BASELINES[str(path)] = (stat.st_dev, stat.st_ino, stat.st_size, anchor)
        except OSError:
            pass


def tail(path):
    try:
        stat = path.stat()
        start = 0
        baseline = BASELINES.get(str(path))
        with path.open('rb') as stream:
            if baseline:
                dev, ino, size, anchor = baseline
                if (stat.st_dev, stat.st_ino) == (dev, ino) and stat.st_size >= size:
                    stream.seek(max(0, size - 128))
                    if stream.read(len(anchor)) == anchor:
                        start = size
            stream.seek(max(start, stat.st_size - 65536))
            return stream.read().decode(errors='replace')
    except OSError:
        return ''


def review():
    states = []
    for run in RUNS:
        proc = run['process']
        rc = proc.poll()
        out = Path(run['output'])
        logs = [Path(run['log']), *out.glob('_x/logs/**/*.log'),
                *out.glob('_x/link/vivado/vpl/prj/prj.runs/*/runme.log')]
        logs = [p for p in logs if p.is_file() and p.stat().st_mtime >= dt.datetime.fromisoformat(run['started']).timestamp()]
        latest = max(logs, key=lambda p: p.stat().st_mtime) if logs else None
        errors = []
        for log in logs:
            errors.extend(f'{log}: {line[:600]}' for line in tail(log).splitlines()
                          if re.match(r'^\s*(ERROR:|FATAL:)', line))
        binary = out / 'bin/vortex_afu.xclbin'
        state = 'running' if rc is None else ('passed' if rc == 0 and binary.is_file() else 'failed')
        result = {k: v for k, v in run.items() if k != 'process'}
        result.update(state=state, returncode=rc,
                      latest_log=str(latest) if latest else None,
                      recent_lines=tail(latest).splitlines()[-8:] if latest else [],
                      errors=errors[-8:])
        if state == 'failed' or errors:
            alarm(run['config'] + ':failure', f"{run['config']}: {state}; rc={rc}; " + '\n'.join(errors[-3:]))
        if rc is None and latest and time.time() - latest.stat().st_mtime > 4 * 3600:
            alarm(run['config'] + ':stale', f"{run['config']}: no log update for four hours; inspect processes")
        if rc is not None:
            for report in out.glob('_x/reports/link/imp/*timing_summary_routed.rpt'):
                content = report.read_text(errors='replace')
                if 'Timing constraints are not met' in content:
                    alarm(run['config'] + ':timing', f"{run['config']}: routed timing constraints not met; {report}")
        states.append(result)
    free = shutil.disk_usage(BUILDDIR).free / (1024 ** 3)
    if free < 15:
        alarm('disk-low', f'PnR filesystem has only {free:.1f} GiB available')
    snapshot = {'time': now(), 'monitor_pid': os.getpid(), 'free_disk_gib': round(free, 1), 'runs': states}
    tmp = TASK / 'status.json.tmp'
    tmp.write_text(json.dumps(snapshot, indent=2) + '\n')
    tmp.replace(TASK / 'status.json')
    active = any(r['state'] == 'running' for r in states)
    (TASK / 'STATUS.yaml').write_text(
        'task: c4-boundary-pnr\nstate: ' + ('RUNNING' if active else 'FINISHED') + '\n'
        + 'updated: ' + json.dumps(now()) + '\n'
        + 'commit: ' + MANIFEST['commit'] + '\n'
        + 'details: status.json\nhistory: events.jsonl\n'
        + 'pitfalls:\n  - Platform name lookup is ambiguous; use the absolute xpfm path.\n'
        + '  - Disk space is monitored; existing outputs are preserved with a unique postfix.\n')
    return snapshot, active


def main():
    env = os.environ.copy()
    for key in ('CONFIGS', 'PERF', 'DEBUG', 'GEMM_MXU_SLR_FLOORPLAN', 'BUILD_DIR',
                'PREFIX', 'MAKEFLAGS', 'MFLAGS', 'CONGESTION_FAIL_FAST'):
        env.pop(key, None)
    env.update(PLATFORM=MANIFEST['platform'], MAX_JOBS=str(MANIFEST['jobs_per_build']),
               JOBS=str(MANIFEST['jobs_per_build']), CLOCK_FREQ_HZ='100')
    if MANIFEST.get('pending_validation', True):
        raise RuntimeError('Validation must pass before resuming PnR')
    env.update(VORTEX_HOME=str(REPO), TOOL_DIR=str(REPO / 'hw/scripts'))
    for item in MANIFEST['runs']:
        config = item['config']
        out = Path(item['output'])
        log = TASK / (config + '.launcher.log')
        # Match the configured Makefile's environment, with the config sourced
        # before execution. v++ resumes in its original output directory.
        command = ['bash', '-c',
            'source "$1"; export VORTEX_GEMM_MXU_SLR_FLOORPLAN="$GEMM_MXU_SLR_FLOORPLAN"; '
            'export VORTEX_CONGESTION_FAIL_FAST=1; exec "${@:2}"',
            'pnr-resume', item['config_file'], *item['vpp_command']]
        remember_logs(out)
        with log.open('x') as stream:
            proc = subprocess.Popen(command, cwd=out, env=env, stdout=stream, stderr=subprocess.STDOUT)
        run = {'config': config, 'command': command, 'pid': proc.pid,
               'started': now(), 'output': str(out), 'log': str(log), 'process': proc}
        RUNS.append(run)
        event('launched', **{k: v for k, v in run.items() if k != 'process'})
    next_hour = time.monotonic()
    while True:
        snapshot, active = review()
        if time.monotonic() >= next_hour or not active:
            event('hourly_review' if active else 'final_review', **snapshot)
            next_hour = time.monotonic() + MANIFEST['interval_seconds']
        if not active:
            alarm('all-finished', 'All PnR jobs finished: ' + ', '.join(r['config'] + '=' + r['state'] for r in snapshot['runs']))
            break
        time.sleep(MANIFEST['poll_seconds'])


if __name__ == '__main__':
    try:
        main()
    except Exception:
        event('monitor_exception', traceback=traceback.format_exc())
        alarm('monitor-exception', 'PnR monitor stopped unexpectedly; inspect events.jsonl and running jobs')
        raise
