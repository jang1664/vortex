"""Shared C++/TVM fixture and independent logical reference for the C4 decoder.

Run with the existing TVM Python environment (PYTHONPATH includes TVM/apps).
No FPGA is required for `generate` or `compare`.
"""
import argparse
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import numpy as np
import torch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'pytorch/spinquant'))
from spinquant_inference.llama3_c4_export import (
    Llama3ExportConfig, Llama3LayerPrefillCheckpoints, Llama3StackPrefill,
    Llama3StackPrefillCheckpoints,
    stack_parameter_shapes, layer_checkpoint_names, _rms_norm, _hadamard,
)
from spinquant_inference.vortex_export_ops import _unpack_signed_int4
from vortex_llama3.run_synthetic_inference import _deterministic_parameters, _build
from vortex_llama3.run_backend_validation import hybrid_metrics, LOCAL_THRESHOLDS
from tvm.support.vortex import load_vortex_accelerator_profile
from tvm.relax.backend.vortex.parameter_archive import (
    C4ParameterArchive, llama3_c4_weight_specs, prepare_c4_parameter_archive,
)
from tvm.relax.backend.vortex.layout import (
    ImproveProfile, plan_improve_layout, prepack_improve_weight, prepack_improve_qparam,
)

DEFAULT_MANIFEST = '/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_96c0f69b12/manifest.json'
# User-selected decoder-output tolerance; all local operation checks retain
# LOCAL_THRESHOLDS (0.002). Keep fraction/L2/cosine/nonfinite guards unchanged.
OUTPUT_THRESHOLDS = {**LOCAL_THRESHOLDS, 'atol': 0.005, 'rtol': 0.005}


def config(model, batch, seq, reduction_width):
    return Llama3ExportConfig(
        batch, seq, seq, intermediate_size=11008 if model == 'llama2-7b' else 14336,
        num_key_value_heads=32 if model == 'llama2-7b' else 8,
        rope_theta=10000.0 if model == 'llama2-7b' else 500000.0,
        round_silu_before_multiply=True,
        kv_quantize_fp16_arithmetic=True,
        rms_reduction_width=reduction_width,
    )


def generate(args):
    root = args.fixture
    root.mkdir(parents=True, exist_ok=True)
    profile = load_vortex_accelerator_profile(args.manifest)
    # This app's existing compile-time contract requires thread width == MXU.
    cfg = config(args.model, args.batch, args.seq_len, ImproveProfile.from_target(profile.target).mxu_kt)
    params = _deterministic_parameters(cfg, lambda c, _: stack_parameter_shapes(c, 1), args.seed)
    # One canonical archive supports both C++ physical tensors and TVM inputs.
    np.savez(root / 'canonical.npz', **{k: v.numpy() for k, v in params.items()})
    archive_path = prepare_c4_parameter_archive(
        root / 'parameters', {k: v.numpy() for k, v in params.items()},
        llama3_c4_weight_specs(1, cfg.hidden_size, cfg.intermediate_size, cfg.num_key_value_heads, cfg.head_dim),
        profile.target, profile.fingerprint, 1,
        model_metadata={'model': args.model, 'seed': args.seed},
    )
    archive = C4ParameterArchive(archive_path, profile.fingerprint, 1)
    tensors = root / 'tensors'
    tensors.mkdir(exist_ok=True)
    records, hashes = [], {}

    def write_tensor(name, value):
        data = np.ascontiguousarray(value)
        path = tensors / f'{name}.bin'
        data.tofile(path)
        records.append(f'{name}\t{data.nbytes}\t{path.relative_to(root)}\n')
        hashes[name] = hashlib.sha256(memoryview(data)).hexdigest()

    for key in params:
        name = key.removeprefix('layers.0.')
        name = name.removesuffix('.qweight') + '.weight' if name.endswith('.qweight') else name
        name = name.removesuffix('.scales') + '.scale' if name.endswith('.scales') else name
        name = name.removesuffix('.zeros') + '.zero' if name.endswith('.zeros') else name
        write_tensor(name, archive.tensor(key))

    rng = np.random.default_rng(args.seed + 1)
    hidden = torch.from_numpy(rng.uniform(-1, 1, (args.batch, args.seq_len, cfg.hidden_size)).astype('float16'))
    positions = torch.arange(args.seq_len, dtype=torch.int64).expand(args.batch, -1)
    model = Llama3LayerPrefillCheckpoints(cfg)
    local_params = {k.removeprefix('layers.0.'): v for k, v in params.items()}
    frequencies = torch.arange(args.seq_len).float()[:, None] * model.rope_inv_freq[None, :]
    write_tensor('hidden', hidden.numpy())
    write_tensor('rope.cos', frequencies.cos().half().numpy())
    write_tensor('rope.sin', frequencies.sin().half().numpy())
    write_tensor('hadamard.r3', model.r3_base.half().numpy())
    write_tensor('hadamard.r4', model.r4_base.half().numpy())
    (root / 'tensors.tsv').write_text(''.join(records))
    fields = dict(model=args.model, batch=args.batch, seq=args.seq_len, hidden=cfg.hidden_size,
                  ffn=cfg.intermediate_size, q_heads=cfg.num_attention_heads,
                  kv_heads=cfg.num_key_value_heads, head_dim=cfg.head_dim)
    (root / 'config.txt').write_text(''.join(f'{k} {v}\n' for k, v in fields.items()))

    print('CPU reference', args.model, args.batch, args.seq_len, flush=True)
    with torch.inference_mode():
        values = model(hidden, positions, local_params)
        refs = dict(zip(layer_checkpoint_names(cfg), values[:15], strict=True))
        norm = _rms_norm(hidden, local_params['input_norm.weight'], cfg.rms_norm_eps, cfg.rms_reduction_width)
        refs['attention_norm'] = norm
        for prefix, heads in [('q', cfg.num_attention_heads), ('k', cfg.num_key_value_heads), ('v', cfg.num_key_value_heads)]:
            projection = model._linear(prefix + '_proj', norm, local_params)
            refs[prefix + '_proj'] = projection
            if prefix != 'v':
                rotated = model._rope(model._split_heads(projection, heads), positions)
                refs[prefix + '_rope'] = rotated
                refs[prefix + '_hadamard'] = _hadamard(rotated, model.r3_base, 1)
        refs['silu'] = torch.nn.functional.silu(refs['gate_projection'].float()).half()
        refs['concat'] = refs['attention_context'].reshape(args.batch, cfg.num_attention_heads, args.seq_len, cfg.head_dim).transpose(1, 2).reshape(args.batch, args.seq_len, cfg.hidden_size)
    aliases = {'query_after_rope': 'q_hadamard', 'attention_scores': 'scores',
               'attention_probabilities': 'probabilities', 'attention_context': 'context',
               'o_projection': 'o_proj', 'post_attention_normalized': 'ffn_norm',
               'gate_projection': 'gate_proj', 'up_projection': 'up_proj',
               'activated_mlp': 'mlp_product', 'transformed_mlp': 'ffn_hadamard',
               'down_projection': 'down_proj', 'q_projection': 'q_proj'}
    references = {aliases.get(k, k): v.numpy() for k, v in refs.items()}
    np.savez(root / 'reference.npz', **references,
             **{f'cache_{i}': v.numpy() for i, v in enumerate(values[15:])})
    refdir = root / 'reference'
    refdir.mkdir(exist_ok=True)
    references['output'].tofile(refdir / 'output.bin')
    provenance = dict(config=asdict(cfg), model=args.model, seed=args.seed, profile_fingerprint=profile.fingerprint,
                      manifest=str(Path(args.manifest).resolve()), tensors_sha256=hashes,
                      vortex_head=subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
                      numerical_policy='signed_all_asymmetric_wkv4_v1; FP16 KV quantization arithmetic; separate FP16 SiLU output; lane-strided RMS reduction')
    (root / 'fixture.json').write_text(json.dumps(provenance, indent=2))
    print('FIXTURE COMPLETE', root, flush=True)


def logical(data, layout, matrices, rows, cols, mxu):
    if layout == 'row':
        return data[:matrices * rows * cols].reshape(matrices, rows, cols)
    if layout in ('a', 'c'):
        result = np.empty((matrices, rows, cols), dtype=data.dtype)
        padded = (rows + 7) // 8 * 8
        for mat in range(matrices):
            for m in range(rows):
                mt, m0 = divmod(m, 128)
                height = min(128, padded - mt * 128)
                ns = np.arange(cols)
                offsets = mat*padded*cols + mt*128*cols + (ns//mxu)*height*mxu + m0*mxu + ns%mxu
                result[mat, m] = data[offsets]
        return result
    raise ValueError(layout)


def compare(args):
    refs = np.load(args.fixture / 'reference.npz')
    metadata = json.loads((args.fixture / 'fixture.json').read_text())
    cfg = Llama3ExportConfig(**metadata['config'])
    catalog = {}
    for line in (args.output / 'buffers.tsv').read_text().splitlines():
        name, layout, matrices, rows, cols, _ = line.split()
        catalog[name] = (layout, int(matrices), int(rows), int(cols))

    def tensor(name):
        return logical(np.fromfile(args.output / f'{name}.bin', dtype='float16'), *catalog[name], args.mxu)

    report = {}
    for name, shape in catalog.items():
        if name not in refs or not (args.output / f'{name}.bin').exists() or shape[0] not in ('row', 'a', 'c'):
            continue
        actual = tensor(name)
        expected = refs[name].reshape(actual.shape)
        thresholds = OUTPUT_THRESHOLDS if name == 'output' else LOCAL_THRESHOLDS
        metrics = hybrid_metrics(actual, expected, thresholds, name=name, enforce=False)
        diff = np.abs(actual.astype('float32') - expected.astype('float32'))
        metrics['max_error_index'] = [int(x) for x in np.unravel_index(np.argmax(diff), diff.shape)]
        report[name] = metrics
        print(name, 'PASS' if metrics['pass'] else 'FAIL', 'max_abs', float(np.max(diff)), flush=True)
    if not report:
        raise RuntimeError('no comparable tensors')
    local_checks, quant_checks = {}, {}
    # Diagnose accumulation against the actual upstream tensors, while keeping
    # the end-to-end report and its failures intact. No tolerance is relaxed.
    if 'output' in report:
        profile = ImproveProfile.from_target(load_vortex_accelerator_profile(metadata['manifest']).target)
        caches = []
        k_source = tensor('k_hadamard').reshape(cfg.batch_size, cfg.num_key_value_heads, cfg.query_length, cfg.head_dim)
        v_source = tensor('v_proj').reshape(cfg.batch_size, cfg.query_length, cfg.num_key_value_heads, cfg.head_dim).transpose(0, 2, 1, 3)
        scheme = 'signed_asymmetric_int4_fp16' if cfg.kv_quantize_fp16_arithmetic else 'signed_asymmetric_int4'
        for is_key, source in [(True, k_source), (False, v_source)]:
            flat = torch.from_numpy(np.ascontiguousarray(source.reshape(-1, cfg.head_dim)))
            cache = torch.ops.vortex.quantize_int4(flat, 1, cfg.kv_group_size, 1, scheme)
            cache = tuple(x.reshape(cfg.batch_size, cfg.num_key_value_heads, cfg.query_length, -1) for x in cache)
            caches.append(cache)
            plan = plan_improve_layout(cfg.query_length,
                cfg.query_length if is_key else cfg.head_dim,
                cfg.head_dim if is_key else cfg.query_length,
                cfg.kv_group_size, is_key, 0 if is_key else 1, profile)
            for b in range(cfg.batch_size):
                for h in range(cfg.num_key_value_heads):
                    name = f'{"key" if is_key else "value"}.{b}.{h}'
                    expected = [prepack_improve_weight(cache[0][b,h].numpy(), plan),
                                prepack_improve_qparam(cache[1][b,h].numpy(), plan, 'float16'),
                                prepack_improve_qparam(cache[2][b,h].numpy(), plan, 'int16')]
                    checks = {}
                    for suffix, wanted in zip(('weight','scale','zero'), expected):
                        actual = np.fromfile(args.output / f'{name}.{suffix}.bin', dtype=wanted.dtype)
                        checks[suffix] = dict(mismatches=int(np.count_nonzero(actual != wanted)), elements=int(wanted.size))
                    quant_checks[name] = checks
            print('SAME INPUT quantization', 'key' if is_key else 'value', flush=True)
        model = Llama3LayerPrefillCheckpoints(cfg)
        with torch.inference_mode():
            query = torch.from_numpy(tensor('q_hadamard').reshape(cfg.batch_size, cfg.num_attention_heads, cfg.query_length, cfg.head_dim))
            positions = torch.arange(cfg.query_length).expand(cfg.batch_size, -1)
            # QDIR=0 follows fpint_gemm_ffn_hw/test_vectors.h: scale the
            # integer weight in FP32, with no intermediate FP16 weight.
            # The generic TVM CPU model dequantizes to FP16 first. Preserve
            # that end-to-end comparison above, but isolate the actual MXU
            # arithmetic here using the verified quantized input bytes.
            packed, scale, zero = caches[0]
            weight = _unpack_signed_int4(packed, list(k_source.shape), 3).float()
            weight = (weight - zero.float()) * scale.float()
            grouped_query = query.reshape(cfg.batch_size, cfg.num_key_value_heads,
                cfg.query_heads_per_kv_head, cfg.query_length, cfg.head_dim)
            scores = (grouped_query.float() @ weight.unsqueeze(2).transpose(-1, -2)).half()
            product = torch.from_numpy(tensor('mlp_product').reshape(cfg.batch_size, cfg.query_length, cfg.intermediate_size))
            transformed = _hadamard(product, model.r4_base, model.r4_base_size)
        isolated_expected = {'scores': scores, 'ffn_hadamard': transformed}
        # For a failing chain boundary, replay only the reference operation on
        # its actual device input. This locates propagation versus local faults;
        # it never replaces the independent final-output gate.
        if any(not value['pass'] for name, value in report.items()
               if name not in ('scores', 'ffn_hadamard')):
            def actual_tensor(name):
                return torch.from_numpy(tensor(name)).reshape(cfg.batch_size, cfg.query_length, -1)
            canonical = np.load(args.fixture / 'canonical.npz')
            parameters = {key.removeprefix('layers.0.'): torch.from_numpy(canonical[key]) for key in canonical.files}
            hidden = torch.from_numpy(np.fromfile(args.fixture / 'tensors/hidden.bin', dtype='float16').reshape(
                cfg.batch_size, cfg.query_length, cfg.hidden_size))
            with torch.inference_mode():
                raw_scores = torch.from_numpy(tensor('scores')).reshape(
                    cfg.batch_size, cfg.num_key_value_heads, cfg.query_heads_per_kv_head,
                    cfg.query_length, cfg.query_length)
                isolated_expected['probabilities'] = torch.ops.vortex.causal_softmax(
                    raw_scores, positions, torch.tensor(cfg.query_length), cfg.head_dim)[1]
                # QDIR=1 rounds activation*scale to FP16 before the INT4 dot.
                packed, scale, zero = caches[1]
                weight = _unpack_signed_int4(packed, list(v_source.shape), 3).float() - zero.float()
                probs = torch.from_numpy(tensor('probabilities')).reshape(
                    cfg.batch_size, cfg.num_key_value_heads, cfg.query_heads_per_kv_head,
                    cfg.query_length, cfg.query_length)
                scaled = (probs.float() * scale.squeeze(-1).unsqueeze(2).unsqueeze(2).float()).half().float()
                isolated_expected['context'] = (scaled @ weight.unsqueeze(2)).half()
                context = torch.from_numpy(tensor('context')).reshape(
                    cfg.batch_size, cfg.num_attention_heads, cfg.query_length, cfg.head_dim)
                isolated_expected['concat'] = context.transpose(1, 2).reshape(hidden.shape)
                isolated_expected['o_proj'] = model._linear('o_proj', actual_tensor('concat'), parameters)
                isolated_expected['attention_residual'] = (actual_tensor('o_proj').float() + hidden.float()).half()
                isolated_expected['ffn_norm'] = _rms_norm(actual_tensor('attention_residual'),
                    parameters['post_attention_norm.weight'], cfg.rms_norm_eps, cfg.rms_reduction_width)
                for name in ('gate_proj', 'up_proj'):
                    isolated_expected[name] = model._linear(name, actual_tensor('ffn_norm'), parameters)
                isolated_expected['silu'] = torch.nn.functional.silu(actual_tensor('gate_proj').float()).half()
                isolated_expected['mlp_product'] = (actual_tensor('silu').float() * actual_tensor('up_proj').float()).half()
                isolated_expected['down_proj'] = model._linear('down_proj', actual_tensor('ffn_hadamard'), parameters)
                isolated_expected['output'] = (actual_tensor('down_proj').float() + actual_tensor('attention_residual').float()).half()
        for name, expected in isolated_expected.items():
            actual = tensor(name)
            local_checks[name] = hybrid_metrics(actual, expected.numpy().reshape(actual.shape), LOCAL_THRESHOLDS, name=name, enforce=False)
            print('SAME INPUT', name, 'PASS' if local_checks[name]['pass'] else 'FAIL', flush=True)
    quant_pass = all(v['mismatches'] == 0 for checks in quant_checks.values() for v in checks.values())
    overall = quant_pass and all(v['pass'] or (k != 'output' and local_checks.get(k, {}).get('pass', False))
                               for k, v in report.items())
    result = dict(fixture=str(args.fixture.resolve()), chain=report, same_input=local_checks,
                  quantization=quant_checks, pass_all=bool(overall), complete_decoder='output' in report,
                  thresholds=dict(local=LOCAL_THRESHOLDS, output=OUTPUT_THRESHOLDS))
    (args.output / 'intermediate_comparison.json').write_text(json.dumps(result, indent=2))
    if not overall:
        raise SystemExit(1)
    print('INTERMEDIATE CHECKS PASS', len(report), 'complete decoder', 'output' in report, flush=True)


def tvm_stage(args):
    """Use TVM's existing prepacked graph and the exact C++ fixture archive."""
    import tvm
    from tvm import relax

    metadata = json.loads((args.fixture / 'fixture.json').read_text())
    cfg = Llama3ExportConfig(**metadata['config'])
    profile = load_vortex_accelerator_profile(metadata['manifest'])
    if profile.fingerprint != metadata['profile_fingerprint']:
        raise ValueError('fixture/profile mismatch')
    archive = C4ParameterArchive(args.fixture / 'parameters/manifest.json', profile.fingerprint, 1)
    names = tuple(stack_parameter_shapes(cfg, 1))
    hidden = np.fromfile(args.fixture / 'tensors/hidden.bin', dtype='float16').reshape(
        cfg.batch_size, cfg.query_length, cfg.hidden_size)
    positions = np.broadcast_to(np.arange(cfg.query_length, dtype='int64'), hidden.shape[:2]).copy()
    artifact = args.fixture / ('tvm_checkpoints' if args.checkpoints else 'tvm')
    artifact.mkdir(exist_ok=True)
    if args.stage == 'compile-tvm':
        params = {name: torch.from_numpy(np.array(archive.tensor(name), copy=True)) for name in names}
        descriptors = []
        model_type = Llama3StackPrefillCheckpoints if args.checkpoints else Llama3StackPrefill
        executable, seconds = _build(model_type(cfg, 1, prepacked_weights=True),
            (torch.from_numpy(hidden), torch.from_numpy(positions), params),
            profile.target, 'fused', 'bytecode', True, descriptors)
        executable.export_library(str(artifact / 'prefill.so'))
        record = dict(profile_fingerprint=profile.fingerprint, config=asdict(cfg),
                      parameter_order=names, packed_kv=descriptors, build_seconds=seconds,
                      fixture_sha256=hashlib.sha256((args.fixture / 'fixture.json').read_bytes()).hexdigest())
        (artifact / 'build.json').write_text(json.dumps(record, indent=2))
        print('TVM COMPILE COMPLETE', seconds, flush=True)
        return
    record = json.loads((artifact / 'build.json').read_text())
    if record['fixture_sha256'] != hashlib.sha256((args.fixture / 'fixture.json').read_bytes()).hexdigest():
        raise ValueError('TVM artifact fixture mismatch; compile again')
    if not os.environ.get('SLURM_JOB_ID'):
        raise RuntimeError('run-tvm requires an FPGA Slurm allocation')
    device = tvm.vortex(0)
    resident = archive.upload(device, names)
    packed = tuple(tvm.runtime.tensor(np.zeros(buf['shape'], dtype=buf['dtype']), device=device)
                   for desc in record['packed_kv'] for buf in desc['buffers'])
    vm = relax.VirtualMachine(tvm.runtime.load_module(str(artifact / 'prefill.so')), device)
    print('TVM PREFILL START', flush=True)
    values = vm['main'](tvm.runtime.tensor(hidden, device=device),
        tvm.runtime.tensor(positions, device=device), *(resident[name] for name in names), *packed)
    if args.checkpoints:
        checkpoint_values = {name: values[i].numpy() for i, name in enumerate(layer_checkpoint_names(cfg))}
        args.output.mkdir(parents=True, exist_ok=True)
        np.savez(args.output / 'tvm_checkpoints.npz', **checkpoint_values)
        output = checkpoint_values['output']
        cache_start = len(layer_checkpoint_names(cfg))
    else:
        output = values[0].numpy()
        cache_start = 1
    args.output.mkdir(parents=True, exist_ok=True)
    np.savez(args.output / 'tvm_cache.npz',
             **{f'cache_{i}': values[cache_start+i].numpy() for i in range(6)})
    np.save(args.output / 'tvm_output.npy', output)
    cpu = np.load(args.fixture / 'reference.npz')['output']
    cpp = np.fromfile(args.output / 'output.bin', dtype='float16').reshape(output.shape)
    reports = {name: hybrid_metrics(output, expected, OUTPUT_THRESHOLDS, name=name, enforce=False)
               for name, expected in [('tvm_vs_cpu', cpu), ('tvm_vs_cpp', cpp)]}
    (args.output / 'tvm_comparison.json').write_text(json.dumps(reports, indent=2))
    print(json.dumps(reports, indent=2), flush=True)
    if not all(v['pass'] for v in reports.values()):
        raise SystemExit(1)
    print('TVM OUTPUT COMPARISON PASS', flush=True)


def quant_check_tvm(args):
    """Exercise exact halfway values on the actual C backend, not just LLVM."""
    import tvm
    from tvm.relax.backend.vortex.pipeline import _make_quantize_int4_row_major

    if not os.environ.get('SLURM_JOB_ID'):
        raise RuntimeError('quant-check-tvm requires an FPGA Slurm allocation')
    profile = load_vortex_accelerator_profile(args.manifest)
    source = np.tile(np.arange(-7.5, 8, 1, dtype='float16'), (4, 8))
    source[1] += np.float16(1)
    source[2] -= np.float16(1)
    source[3] = 0
    expected = torch.ops.vortex.quantize_int4(torch.from_numpy(source), 1, 128, 1,
                                             'signed_asymmetric_int4_fp16')
    function = _make_quantize_int4_row_major(source.shape, 128,
                                            'signed_asymmetric_int4_fp16')
    compiled = tvm.compile(function.with_attr('global_symbol', 'main'), target=profile.target)
    device = tvm.vortex(0)
    actual = [tvm.runtime.empty(x.shape, str(x.numpy().dtype), device=device) for x in expected]
    compiled(tvm.runtime.tensor(source, device=device), *actual)
    for name, result, wanted in zip(('weight', 'scale', 'zero'), actual, expected):
        np.testing.assert_array_equal(result.numpy(), wanted.numpy(), err_msg=name)
    print('TVM FPGA HALFWAY QUANTIZATION PASS (positive/negative ties, zero-point ties, all-zero row)', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['generate', 'compare', 'compile-tvm', 'run-tvm', 'quant-check-tvm'])
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--model', choices=['llama3-8b', 'llama2-7b'], default='llama3-8b')
    parser.add_argument('--batch', type=int, default=1)
    parser.add_argument('--seq-len', type=int, default=32)
    parser.add_argument('--seed', type=int, default=20260831)
    parser.add_argument('--manifest', default=DEFAULT_MANIFEST)
    parser.add_argument('--mxu', type=int, default=16)
    parser.add_argument('--checkpoints', action='store_true', help='TVM diagnostic intermediate outputs')
    args = parser.parse_args()
    if args.stage == 'generate': generate(args)
    elif args.stage == 'compile-tvm': tvm_stage(args)
    elif args.stage == 'quant-check-tvm': quant_check_tvm(args)
    else:
        if args.output is None: parser.error('compare/run-tvm requires --output')
        if args.stage == 'run-tvm': tvm_stage(args)
        else: compare(args)


if __name__ == '__main__':
    main()
