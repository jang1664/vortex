"""One real-size Llama3 decoder prefill; setup/readback excluded from timing."""
import argparse
import ctypes
import gc
import json
import os
from pathlib import Path
import sys
import time

import numpy as np
import torch
import tvm
from tvm import relax
from tvm.support.vortex import load_vortex_accelerator_profile
from tvm.relax.backend.vortex.parameter_archive import (
    C4ParameterArchive, llama3_c4_weight_specs, prepare_c4_parameter_archive,
)
from vortex_llama3.run_synthetic_inference import _build, _deterministic_parameters
from vortex_llama3.run_backend_validation import (
    _runtime_tensor, compare_layer_state, hybrid_metrics, LOCAL_THRESHOLDS,
)

sys.path.insert(0, str(Path(os.environ['TVM_VORTEX_HOME']) / 'pytorch/spinquant'))
from spinquant_inference.llama3_c4_export import (
    Llama3ExportConfig, Llama3StackPrefill, stack_parameter_shapes,
)

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--stage', choices=['compile', 'reference', 'run'], required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--repetitions', type=int, default=3)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
cfg = Llama3ExportConfig(1, 1024, 1024)
order = list(stack_parameter_shapes(cfg, 1))
manifest = Path(os.environ['XRT_XCLBIN_PATH']).parent.parent / 'manifest.json'
profile = load_vortex_accelerator_profile(manifest)
seed = 20260831

def canonical():
    return _deterministic_parameters(cfg, lambda c, _: stack_parameter_shapes(c, 1), seed)

def inputs():
    hidden = np.random.default_rng(20261009).uniform(-1, 1, (1, 1024, 4096)).astype('float16')
    positions = np.arange(1024, dtype='int64').reshape(1, -1)
    return hidden, positions

if a.stage == 'compile':
    parameters = canonical()
    archive_path = prepare_c4_parameter_archive(
        a.output / 'parameters', {n: v.numpy() for n, v in parameters.items()},
        llama3_c4_weight_specs(1), profile.target, profile.fingerprint, 1,
        model_metadata={'model': 'llama3-8b-layer1', 'seed': seed},
    )
    del parameters
    archive = C4ParameterArchive(archive_path, profile.fingerprint, 1)
    physical = {n: torch.from_numpy(np.array(archive.tensor(n))) for n in order}
    model = Llama3StackPrefill(cfg, 1, prepacked_weights=True)
    sample = (*[torch.from_numpy(x) for x in inputs()], physical)
    print('COMPILE prefill B1 S1024 H4096 FFN14336 Q32 KV8 D128', flush=True)
    descriptors = []
    exe, seconds = _build(model, sample, profile.target, 'fused', 'bytecode', True, descriptors)
    exe.export_library(str(a.output / 'prefill.so'))
    (a.output / 'compile.json').write_text(json.dumps({
        'seconds': seconds, 'profile_fingerprint': profile.fingerprint,
        'manifest': str(manifest), 'xclbin': os.environ['XRT_XCLBIN_PATH'],
        'parameter_order': order, 'shape': vars(cfg), 'layers': 1,
        'layout_policy': 'fused', 'dynamic_kv_length': True, 'packed_kv_cache': True,
        'packed_kv': descriptors,
    }, indent=2))
    print('COMPILE PASS', seconds, flush=True)
elif a.stage == 'reference':
    model = Llama3StackPrefill(cfg, 1)
    start = time.perf_counter()
    with torch.inference_mode():
        result = model(*[torch.from_numpy(x) for x in inputs()], canonical())
    np.savez(a.output / 'reference.npz', **{f'o{i}': x.numpy() for i, x in enumerate(result)})
    print('REFERENCE PASS', time.perf_counter() - start, flush=True)
else:
    compiled = json.loads((a.output / 'compile.json').read_text())
    assert compiled['profile_fingerprint'] == profile.fingerprint
    device = tvm.vortex(0)
    archive = C4ParameterArchive(a.output / 'parameters/manifest.json', profile.fingerprint, 1)
    resident = archive.upload(device, order)
    device_inputs = [_runtime_tensor(x, device) for x in inputs()] + [resident[n] for n in order]
    device_inputs += [
        _runtime_tensor(np.zeros(buf['shape'], dtype=buf['dtype']), device)
        for desc in compiled['packed_kv'] for buf in desc['buffers']
    ]
    module = tvm.runtime.load_module(str(a.output / 'prefill.so'))
    vm = relax.VirtualMachine(module, device=device, memory_cfg='naive')
    probe = ctypes.CDLL(None)
    probe.bench_profile_enable.argtypes = [ctypes.c_int]
    probe.bench_cycles.restype = ctypes.c_uint64
    probe.bench_launches.restype = ctypes.c_uint64
    samples = []
    result = None
    for i in range(a.repetitions + 1):
        result = None
        gc.collect()
        device.sync()
        print('BEGIN', 'warmup' if i == 0 else f'measurement {i}', flush=True)
        start = time.perf_counter()
        result = vm['main'](*device_inputs)
        device.sync()
        seconds = time.perf_counter() - start
        samples.append(seconds)
        (a.output / 'timings.json').write_text(json.dumps({'warmup_seconds': samples[0], 'seconds': samples[1:]}, indent=2))
        print('DONE', i, seconds, flush=True)

    # Profiling is a separate invocation so PCIe counter readback and Python
    # instrumentation do not contaminate the timed repetitions above.
    records = []
    pending = []
    def instrument(func, name, before, ret, *args):
        if before:
            pending.append((name, time.perf_counter(), probe.bench_cycles(), probe.bench_launches()))
        else:
            old_name, start, cycles, launches = pending.pop()
            assert old_name == name
            count = probe.bench_launches() - launches
            if name != 'main':
                record = dict(name=name, seconds=time.perf_counter()-start,
                              cycles=probe.bench_cycles()-cycles, launches=count)
                records.append(record)
                with (a.output / 'profile.jsonl').open('a') as f:
                    f.write(json.dumps(record) + '\n')
                if count: print('KERNEL', name, record['cycles'], flush=True)
        return relax.VMInstrumentReturnKind.NO_OP
    vm.set_instrument(instrument)
    probe.bench_profile_enable(1)
    result = vm['main'](*device_inputs)
    device.sync()
    total_cycles, launches = probe.bench_cycles(), probe.bench_launches()
    probe.bench_profile_enable(0)
    assert launches > 0 and total_cycles > 0
    arrays = [x.numpy() for x in result]
    assert all(np.isfinite(x).all() for x in arrays)
    reference = np.load(a.output / 'reference.npz')
    expected = [reference[f'o{i}'] for i in range(len(arrays))]
    local = hybrid_metrics(arrays[0], expected[0], LOCAL_THRESHOLDS, name='hidden', enforce=False)
    try:
        correctness = {'pass': True, 'metrics': compare_layer_state(arrays, expected, 1024)}
    except AssertionError as exc:
        correctness = {'pass': False, 'error': str(exc)}
    summary = dict(warmup_seconds=samples[0], seconds=samples[1:],
                   median_seconds=float(np.median(samples[1:])),
                   fpga_cycles=total_cycles, fpga_seconds=total_cycles/1e8,
                   launches=launches, profile=records, correctness=correctness,
                   hidden_local=local, bdf=os.environ.get('XRT_DEVICE_BDF'))
    (a.output / 'results.json').write_text(json.dumps(summary, indent=2))
    np.savez(a.output / 'outputs.npz', **{f'o{i}': x for i, x in enumerate(arrays)})
    print('RESULT', json.dumps({k:v for k,v in summary.items() if k!='profile'}), flush=True)
