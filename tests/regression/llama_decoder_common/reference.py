"""Backend-aware row-major C1/C2/C3 fixtures, using the existing SpinQuant CPU model."""
import argparse
from dataclasses import asdict
import hashlib
import importlib.util
import json
from pathlib import Path
import numpy as np
import torch
spec = importlib.util.spec_from_file_location('c4_reference', Path(__file__).resolve().parents[1] / 'llama_decoder_C4/reference.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
from spinquant_inference.llama3_c4_export import PROJECTION_DIMS

def model_for(cfg, candidate, decode=False):
    cls = base.Llama3LayerDecodeCheckpoints if decode else base.Llama3LayerPrefillCheckpoints
    return cls(cfg, linear_compute='fp16' if candidate == 'C1' else 'w4', attention_compute='w4' if candidate == 'C3' else 'fp16')

def parameters_for(cfg, canonical, candidate):
    params = {k.removeprefix('layers.0.'): torch.from_numpy(np.array(v, copy=True)) for k, v in canonical.items()}
    if candidate == 'C1':
        for name, (ki, ni) in PROJECTION_DIMS.items():
            params[name + '.weight'] = torch.ops.vortex.dequantize_int4(params[name + '.qweight'], params[name + '.scales'], params[name + '.zeros'], [getattr(cfg, ki), getattr(cfg, ni)], 0, cfg.weight_group_size, 1, 'signed_asymmetric_int4')
    return params

def generate(a):
    root = a.fixture
    root.mkdir(parents=True, exist_ok=True)
    decode = a.decoder_stage == 'decode'
    if decode and (a.batch != 1 or a.seq_len != 1 or (not a.past_fixture) or (not 0 < a.past_kv_len < a.cache_capacity) or a.cache_capacity % 32):
        raise ValueError('decode requires B1/S1, matching past fixture and aligned capacity')
    cfg = base.config(a.model, a.batch, a.seq_len, a.threads, a.cache_capacity if decode else None)
    params = base._deterministic_parameters(cfg, lambda c, _: base.stack_parameter_shapes(c, 1), a.seed)
    canonical = {k: v.numpy() for k, v in params.items()}
    np.savez(root / 'canonical.npz', **canonical)
    local = parameters_for(cfg, canonical, a.candidate)
    model = model_for(cfg, a.candidate, decode)
    (root / 'tensors').mkdir(exist_ok=True)
    records = []
    hashes = {}

    def write(name, value):
        value = np.ascontiguousarray(value)
        path = root / 'tensors' / (name + '.bin')
        value.tofile(path)
        records.append(f'{name}\t{value.nbytes}\t{path.relative_to(root)}\n')
        hashes[name] = hashlib.sha256(memoryview(value)).hexdigest()
    for key, value in canonical.items():
        name = key.removeprefix('layers.0.')
        for before, after in (('.qweight', '.weight'), ('.scales', '.scale'), ('.zeros', '.zero')):
            if name.endswith(before):
                name = name.removesuffix(before) + after
        write(name, value)
    if a.candidate == 'C1':
        for name in PROJECTION_DIMS:
            write(name + '.fp16', local[name + '.weight'].numpy().T)
    rng = np.random.default_rng(a.seed + (2 if decode else 1))
    hidden = torch.from_numpy(rng.uniform(-1, 1, (a.batch, a.seq_len, cfg.hidden_size)).astype('float16'))
    positions = (torch.arange(a.seq_len) + (a.past_kv_len if decode else 0)).expand(a.batch, -1)
    freq = positions[0].float()[:, None] * model.rope_inv_freq[None, :]
    for name, value in (('hidden', hidden), ('rope.cos', freq.cos().half()), ('rope.sin', freq.sin().half()), ('hadamard.r3', model.r3_base.half()), ('hadamard.r4', model.r4_base.half())):
        write(name, value.numpy())
    initial = []
    if decode:
        meta = json.loads((a.past_fixture / 'fixture.json').read_text())
        if meta['model'] != a.model or meta['seed'] != a.seed or meta.get('candidate') != a.candidate or (meta['config']['query_length'] != a.past_kv_len):
            raise ValueError('past fixture model/candidate/seed/length mismatch')
        past = np.load(a.past_fixture / 'reference.npz')
        for i in range(6):
            v = past[f'cache_{i}']
            full = np.zeros((*v.shape[:2], cfg.cache_capacity, v.shape[-1]), dtype=v.dtype)
            full[:, :, :a.past_kv_len] = v
            initial.append(torch.from_numpy(full))
        for kind, offset in (('key', 0), ('value', 3)):
            for b in range(a.batch):
                for h in range(cfg.num_key_value_heads):
                    for j, suffix in enumerate(('weight', 'scale', 'zero')):
                        write(f'{kind}.{b}.{h}.{suffix}', initial[offset + j][b, h].numpy())
        np.savez(root / 'initial_cache.npz', **{f'cache_{i}': v.numpy() for i, v in enumerate(initial)})
    (root / 'tensors.tsv').write_text(''.join(records))
    fields = dict(candidate=a.candidate, model=a.model, batch=a.batch, seq=a.seq_len, hidden=cfg.hidden_size, ffn=cfg.intermediate_size, q_heads=cfg.num_attention_heads, kv_heads=cfg.num_key_value_heads, head_dim=cfg.head_dim)
    if decode:
        fields.update(stage='decode', past_kv=a.past_kv_len, cache_capacity=cfg.cache_capacity)
    (root / 'config.txt').write_text(''.join((f'{k} {v}\n' for k, v in fields.items())))
    print('CPU reference', a.candidate, a.model, a.decoder_stage, flush=True)
    with torch.inference_mode():
        values = model(hidden, positions, local, *initial, torch.tensor(a.past_kv_len)) if decode else model(hidden, positions, local)
        refs = dict(zip(base.layer_checkpoint_names(cfg), values[:15], strict=True))
        norm = base._rms_norm(hidden, local['input_norm.weight'], cfg.rms_norm_eps, cfg.rms_reduction_width)
        refs['attention_norm'] = norm
        for prefix, heads in (('q', cfg.num_attention_heads), ('k', cfg.num_key_value_heads), ('v', cfg.num_key_value_heads)):
            projection = model._linear(prefix + '_proj', norm, local)
            refs[prefix + '_proj'] = projection
            if prefix != 'v':
                rotated = model._rope(model._split_heads(projection, heads), positions)
                refs[prefix + '_rope'] = rotated
                refs[prefix + '_hadamard'] = base._hadamard(rotated, model.r3_base, 1)
        refs['silu'] = torch.nn.functional.silu(refs['gate_projection'].float()).half()
        refs['concat'] = refs['attention_context'].reshape(a.batch, cfg.num_attention_heads, a.seq_len, cfg.head_dim).transpose(1, 2).reshape(hidden.shape)
    aliases = dict(query_after_rope='q_hadamard', attention_scores='scores', attention_probabilities='probabilities', attention_context='context', o_projection='o_proj', post_attention_normalized='ffn_norm', gate_projection='gate_proj', up_projection='up_proj', activated_mlp='mlp_product', transformed_mlp='ffn_hadamard', down_projection='down_proj', q_projection='q_proj')
    refs = {aliases.get(k, k): v.numpy() for k, v in refs.items()}
    np.savez(root / 'reference.npz', **refs, **{f'cache_{i}': v.numpy() for i, v in enumerate(values[15:])})
    (root / 'reference').mkdir(exist_ok=True)
    refs['output'].tofile(root / 'reference/output.bin')
    meta = dict(config=asdict(cfg), model=a.model, candidate=a.candidate, seed=a.seed, decoder_stage=a.decoder_stage, past_kv_len=a.past_kv_len if decode else 0, tensors_sha256=hashes, linear_compute=model.linear_compute, attention_compute=model.attention_compute, numerical_policy='signed asymmetric WKV4; FP16 KV quant; separate SiLU; lane-strided RMS', weight_dequantization='C1 preloaded FP16 weights; excluded from decoder timing')
    (root / 'fixture.json').write_text(json.dumps(meta, indent=2))
    print('FIXTURE COMPLETE', root, flush=True)

def compare(a):
    meta = json.loads((a.fixture / 'fixture.json').read_text())
    cfg = base.Llama3ExportConfig(**meta['config'])
    refs = np.load(a.fixture / 'reference.npz')
    model = model_for(cfg, meta['candidate'])
    params = parameters_for(cfg, np.load(a.fixture / 'canonical.npz'), meta['candidate'])
    past = meta.get('past_kv_len', 0)
    valid = past + cfg.query_length
    catalog = {}
    for line in (a.output / 'buffers.tsv').read_text().splitlines():
        name, layout, mat, rows, cols, _ = line.split()
        catalog[name] = (layout, int(mat), int(rows), int(cols))

    def t(name):
        layout, mat, rows, cols = catalog[name]
        if layout != 'row':
            raise ValueError(f'non-row-major logical tensor: {name}')
        return torch.from_numpy(np.fromfile(a.output / f'{name}.bin', dtype='float16')[:mat * rows * cols].reshape(mat, rows, cols))

    def seq(name):
        return t(name).reshape(cfg.batch_size, cfg.query_length, -1)

    def metric(name, wanted, thresholds=base.LOCAL_THRESHOLDS):
        actual = t(name).numpy()
        wanted = np.asarray(wanted).reshape(actual.shape)
        if name == 'scores':
            actual, wanted = (actual[..., :valid], wanted[..., :valid])
        result = base.hybrid_metrics(actual, wanted, thresholds, name=name, enforce=False)
        print(name, 'PASS' if result['pass'] else 'FAIL', flush=True)
        return result
    chain = {name: metric(name, refs[name], base.OUTPUT_THRESHOLDS if name == 'output' else base.LOCAL_THRESHOLDS) for name in catalog if name in refs and catalog[name][0] == 'row' and (a.output / f'{name}.bin').exists()}
    if not chain:
        raise ValueError('no comparable tensors')
    local = {}
    quant = {}
    if 'output' in chain:
        caches = []
        saved = np.load(a.fixture / 'initial_cache.npz') if past else None
        for kind, source, offset in (('key', t('k_hadamard').reshape(cfg.batch_size, cfg.num_key_value_heads, cfg.query_length, cfg.head_dim), 0), ('value', seq('v_proj').reshape(cfg.batch_size, cfg.query_length, cfg.num_key_value_heads, cfg.head_dim).transpose(1, 2), 3)):
            cache = torch.ops.vortex.quantize_int4(source.reshape(-1, cfg.head_dim), 1, cfg.kv_group_size, 1, 'signed_asymmetric_int4_fp16')
            cache = [v.reshape(cfg.batch_size, cfg.num_key_value_heads, cfg.query_length, -1) for v in cache]
            if past:
                full = [torch.from_numpy(saved[f'cache_{offset + j}'].copy()) for j in range(3)]
                for dest, update in zip(full, cache):
                    dest[:, :, past:valid] = update
                cache = full
            caches.append(cache)
            for b in range(cfg.batch_size):
                for h in range(cfg.num_key_value_heads):
                    name = f'{kind}.{b}.{h}'
                    quant[name] = {}
                    for j, suffix in enumerate(('weight', 'scale', 'zero')):
                        wanted = cache[j][b, h].numpy().ravel()
                        actual = np.fromfile(a.output / f'{name}.{suffix}.bin', dtype=wanted.dtype)
                        if actual.size != wanted.size:
                            raise ValueError('cache length mismatch')
                        quant[name][suffix] = dict(mismatches=int(np.count_nonzero(actual != wanted)), elements=int(wanted.size))
        with torch.inference_mode():
            shape = [cfg.batch_size, cfg.num_key_value_heads, cfg.cache_capacity, cfg.head_dim]
            query = t('q_hadamard').reshape(cfg.batch_size, cfg.num_key_value_heads, cfg.query_heads_per_kv_head, cfg.query_length, cfg.head_dim)
            key, ks, kz = caches[0]
            value, vs, vz = caches[1]
            kw = (base._unpack_signed_int4(key, shape, 3).float() - kz.float()) * ks.float()
            vw = base._unpack_signed_int4(value, shape, 3).float() - vz.float()
            probs = t('probabilities').reshape(cfg.batch_size, cfg.num_key_value_heads, cfg.query_heads_per_kv_head, cfg.query_length, cfg.cache_capacity)
            if meta['candidate'] == 'C3':
                scores = (query.float() @ kw.unsqueeze(2).transpose(-1, -2)).half()
                context = ((probs.float() * vs.squeeze(-1).unsqueeze(2).unsqueeze(2).float()).half().float() @ vw.unsqueeze(2)).half()
            else:
                scores = (query.float() @ kw.half().float().unsqueeze(2).transpose(-1, -2)).half()
                context = (probs.float() @ (vw * vs.float()).half().float().unsqueeze(2)).half()
            hidden = torch.from_numpy(np.fromfile(a.fixture / 'tensors/hidden.bin', dtype='float16').reshape(cfg.batch_size, cfg.query_length, cfg.hidden_size))
            positions = (torch.arange(cfg.query_length) + past).expand(cfg.batch_size, -1)
            expected = dict(scores=scores, context=context, attention_norm=base._rms_norm(hidden, params['input_norm.weight'], cfg.rms_norm_eps, cfg.rms_reduction_width))
            for prefix, heads in (('q', cfg.num_attention_heads), ('k', cfg.num_key_value_heads), ('v', cfg.num_key_value_heads)):
                expected[prefix + '_proj'] = model._linear(prefix + '_proj', seq('attention_norm'), params)
                if prefix != 'v':
                    expected[prefix + '_rope'] = model._rope(model._split_heads(seq(prefix + '_proj'), heads), positions)
                    expected[prefix + '_hadamard'] = base._hadamard(t(prefix + '_rope').reshape(cfg.batch_size, heads, cfg.query_length, cfg.head_dim), model.r3_base, 1)
            expected['probabilities'] = torch.ops.vortex.causal_softmax(t('scores').reshape(scores.shape), positions, torch.tensor(valid), cfg.head_dim)[1]
            expected['concat'] = t('context').reshape(cfg.batch_size, cfg.num_attention_heads, cfg.query_length, cfg.head_dim).transpose(1, 2).reshape(hidden.shape)
            expected['o_proj'] = model._linear('o_proj', seq('concat'), params)
            expected['attention_residual'] = (seq('o_proj').float() + hidden.float()).half()
            expected['ffn_norm'] = base._rms_norm(seq('attention_residual'), params['post_attention_norm.weight'], cfg.rms_norm_eps, cfg.rms_reduction_width)
            for name in ('gate_proj', 'up_proj'):
                expected[name] = model._linear(name, seq('ffn_norm'), params)
            expected['silu'] = torch.nn.functional.silu(seq('gate_proj').float()).half()
            expected['mlp_product'] = (seq('silu').float() * seq('up_proj').float()).half()
            expected['ffn_hadamard'] = base._hadamard(seq('mlp_product'), model.r4_base, model.r4_base_size)
            expected['down_proj'] = model._linear('down_proj', seq('ffn_hadamard'), params)
            expected['output'] = (seq('down_proj').float() + seq('attention_residual').float()).half()
        for name, wanted in expected.items():
            print('SAME INPUT', end=' ', flush=True)
            local[name] = metric(name, wanted.numpy())
    passed = all((v['mismatches'] == 0 for checks in quant.values() for v in checks.values()))
    passed = passed and all((v['pass'] or (name != 'output' and local.get(name, {}).get('pass', False)) for name, v in chain.items())) and all((v['pass'] for v in local.values()))
    report = dict(candidate=meta['candidate'], chain=chain, same_input=local, quantization=quant, pass_all=bool(passed), complete_decoder='output' in chain, thresholds=dict(local=base.LOCAL_THRESHOLDS, output=base.OUTPUT_THRESHOLDS))
    (a.output / 'intermediate_comparison.json').write_text(json.dumps(report, indent=2))
    if not passed:
        raise SystemExit(1)
    print('INTERMEDIATE CHECKS PASS', len(chain), flush=True)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('stage', choices=('generate', 'compare'))
    p.add_argument('--fixture', type=Path, required=True)
    p.add_argument('--output', type=Path)
    p.add_argument('--candidate', choices=('C1', 'C2', 'C3'), default='C3')
    p.add_argument('--model', choices=('llama3-8b', 'llama2-7b'), default='llama3-8b')
    p.add_argument('--batch', type=int, default=1)
    p.add_argument('--seq-len', type=int, default=32)
    p.add_argument('--decoder-stage', choices=('prefill', 'decode'), default='prefill')
    p.add_argument('--past-kv-len', type=int, default=0)
    p.add_argument('--cache-capacity', type=int, default=0)
    p.add_argument('--past-fixture', type=Path)
    p.add_argument('--seed', type=int, default=20260831)
    p.add_argument('--threads', type=int, default=16)
    a = p.parse_args()
    torch.set_num_threads(4)
    if a.stage == 'generate':
        generate(a)
    else:
        if a.output is None:
            p.error('compare requires --output')
        compare(a)
if __name__ == '__main__':
    main()
